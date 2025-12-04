/// AWS Signature V4 implementation.
/// Handles request signing according to AWS specifications:
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html
///
/// This module implements the complete AWS Signature Version 4 signing process.
/// The signing process involves several steps:
///
/// 1. Create a canonical request by combining:
///    - HTTP method
///    - URI path (normalized)
///    - Query string (sorted)
///    - Headers (canonicalized and sorted)
///    - Signed headers list
///    - Payload hash
///
/// 2. Create a string to sign using:
///    - Algorithm identifier
///    - Request timestamp
///    - Credential scope
///    - Hash of canonical request
///
/// 3. Calculate the signature using:
///    - Derived signing key (through multiple HMAC operations)
///    - String to sign
///
/// 4. Create the final Authorization header
///
/// Example usage:
/// ```zig
/// const credentials = Credentials{
///     .access_key = "AKIAIOSFODNN7EXAMPLE",
///     .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
/// };
///
/// const params = SigningParams{
///     .method = "GET",
///     .path = "/test.txt",
///     .headers = headers,
///     .timestamp = timestamp,
/// };
///
/// const auth_header = try signRequest(allocator, credentials, params);
/// defer allocator.free(auth_header);
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const fmt = std.fmt;
const mem = std.mem;
const time = std.time;
const log = std.log;

const UtcDateTime = @import("time.zig").UtcDateTime;

/// AWS region for signing
const Region = []const u8;
/// AWS service name (e.g., "s3")
const Service = []const u8;

/// Credentials used for signing
pub const Credentials = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: Region = "us-east-1",
    service: Service = "s3",
};

/// Request parameters needed for signing
pub const SigningParams = struct {
    /// HTTP method (GET, PUT, etc.)
    method: []const u8,
    /// Full request path including query string
    path: []const u8,
    /// Request headers
    headers: std.StringHashMap([]const u8),
    /// Request body (or null)
    body: ?[]const u8 = null,
    /// Request timestamp (or null for current time)
    /// When null, the current time will be used
    timestamp: ?i64 = null,
};

/// Sign an S3 request using AWS Signature Version 4
pub fn signRequest(allocator: Allocator, credentials: Credentials, params: SigningParams) ![]const u8 {
    // Use current time if no timestamp provided
    const timestamp = params.timestamp orelse blk: {
        const now = std.time.timestamp();
        break :blk @as(i64, @intCast(now));
    };
    const dt = UtcDateTime.init(timestamp);

    // Get the date string in the correct format (YYYYMMDD)
    const date_str = try dt.formatAmzDate(allocator);
    defer allocator.free(date_str);

    // Get the full datetime string for x-amz-date header
    const datetime_str = try dt.formatAmz(allocator);
    defer allocator.free(datetime_str);

    log.debug("Signing request with date: {s}, datetime: {s}", .{ date_str, datetime_str });

    // Create credential scope
    const credential_scope = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/s3/aws4_request",
        .{ date_str, credentials.region },
    );
    defer allocator.free(credential_scope);

    // Ensure x-amz-date header is set with current time
    var headers_copy = try params.headers.clone();
    defer headers_copy.deinit();
    try headers_copy.put("x-amz-date", datetime_str);

    // Create canonical request with updated headers
    const canonical_request = try createCanonicalRequest(allocator, .{
        .method = params.method,
        .path = params.path,
        .headers = headers_copy,
        .body = params.body,
        .timestamp = timestamp,
    });
    defer allocator.free(canonical_request);

    log.debug("Canonical request:\n{s}", .{canonical_request});

    // Create string to sign
    const string_to_sign = try createStringToSign(
        allocator,
        "",
        credential_scope,
        canonical_request,
        timestamp,
    );
    defer allocator.free(string_to_sign);

    log.debug("String to sign:\n{s}", .{string_to_sign});

    // Calculate signing key
    const signing_key = try deriveSigningKey(
        allocator,
        credentials.secret_key,
        date_str,
        credentials.region,
        "s3",
    );
    defer allocator.free(signing_key);

    // Calculate final signature
    const signature = try calculateSignature(allocator, signing_key, string_to_sign);
    std.debug.print("[signature]: {s}\n", .{signature});
    defer allocator.free(signature);

    // Get signed headers string
    var header_names: std.ArrayList([]const u8) = .empty;
    defer header_names.deinit(allocator);
    defer {
        for (header_names.items) |name| {
            allocator.free(name);
        }
    }

    var header_it = params.headers.iterator();
    while (header_it.next()) |entry| {
        const lower_name = try std.ascii.allocLowerString(allocator, entry.key_ptr.*);
        try header_names.append(allocator, lower_name);
    }

    std.mem.sortUnstable([]const u8, header_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const signed_headers = try std.mem.join(allocator, ";", header_names.items);
    defer allocator.free(signed_headers);

    // Create final authorization header
    return std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{
            credentials.access_key,
            credential_scope,
            signed_headers,
            signature,
        },
    );
}

/// Create canonical request string for signing
fn createCanonicalRequest(allocator: Allocator, params: SigningParams) ![]const u8 {
    var canonical: std.ArrayList(u8) = .empty;
    errdefer canonical.deinit(allocator);

    // Add HTTP method (uppercase)
    try canonical.appendSlice(allocator, params.method);
    try canonical.append(allocator, '\n');

    // Add canonical URI (must be normalized)
    try canonical.appendSlice(allocator, params.path);
    try canonical.append(allocator, '\n');

    // Add canonical query string (empty for now)
    try canonical.append(allocator, '\n');

    // Create sorted list of header names for consistent ordering
    var header_names: std.ArrayList([]const u8) = .empty;
    defer header_names.deinit(allocator);

    var header_it = params.headers.iterator();
    while (header_it.next()) |entry| {
        // Convert header names to lowercase
        const lower_name = try std.ascii.allocLowerString(allocator, entry.key_ptr.*);
        errdefer allocator.free(lower_name);
        try header_names.append(allocator, lower_name);
    }
    defer {
        for (header_names.items) |name| {
            allocator.free(name);
        }
    }

    // Sort header names alphabetically
    std.mem.sortUnstable([]const u8, header_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Add canonical headers in sorted order
    for (header_names.items) |name| {
        const value = params.headers.get(name) orelse continue;
        // Trim and normalize value
        const trimmed_value = std.mem.trim(u8, value, " \t\r\n");
        try canonical.appendSlice(allocator, name);
        try canonical.append(allocator, ':');
        try canonical.appendSlice(allocator, trimmed_value);
        try canonical.append(allocator, '\n');
    }
    try canonical.append(allocator, '\n');

    // Add signed headers
    const signed_headers = try std.mem.join(allocator, ";", header_names.items);
    defer allocator.free(signed_headers);
    try canonical.appendSlice(allocator, signed_headers);
    try canonical.append(allocator, '\n');

    // Add payload hash
    const payload_hash = if (params.body) |body|
        try hashPayload(allocator, body)
    else
        // SHA256 hash of empty string, pretty funny
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    defer if (params.body != null) allocator.free(payload_hash);
    try canonical.appendSlice(allocator, payload_hash);

    return canonical.toOwnedSlice(allocator);
}

/// Get credential scope string
fn getCredentialScope(allocator: Allocator, credentials: Credentials, timestamp: i64) ![]const u8 {
    const dt = UtcDateTime.init(timestamp);
    const date = try dt.formatAmzDate(allocator);
    defer allocator.free(date);

    return fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/aws4_request",
        .{
            date,
            credentials.region,
            credentials.service,
        },
    );
}

/// Get signed headers string
fn getSignedHeaders(allocator: Allocator, headers: std.StringHashMap([]const u8)) ![]const u8 {
    var header_names = std.ArrayList([]const u8).init(allocator);
    defer header_names.deinit();

    var it = headers.iterator();
    while (it.next()) |entry| {
        try header_names.append(entry.key_ptr.*);
    }

    // Sort header names
    std.mem.sortUnstable([]const u8, header_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return std.mem.join(allocator, ";", header_names.items);
}

/// Create string to sign.
/// Format: AWS4-HMAC-SHA256\n
///         TIMESTAMP\n
///         SCOPE\n
///         HEX(HASH(CANONICAL_REQUEST))
fn createStringToSign(
    allocator: Allocator,
    _: []const u8, // Mark unused date_str parameter with _
    credential_scope: []const u8,
    canonical_request: []const u8,
    timestamp: i64,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Algorithm
    try result.appendSlice(allocator, "AWS4-HMAC-SHA256\n");

    // Get the full datetime string for the second line
    const datetime_str = try UtcDateTime.init(timestamp).formatAmz(allocator);
    defer allocator.free(datetime_str);
    try result.appendSlice(allocator, datetime_str);
    try result.append(allocator, '\n');

    // Credential scope
    try result.appendSlice(allocator, credential_scope);
    try result.append(allocator, '\n');

    // Hashed canonical request
    var hash: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(canonical_request, &hash, .{});
    const hash_hex = try std.fmt.allocPrint(allocator, "{x}", .{hash});
    defer allocator.free(hash_hex);
    try result.appendSlice(allocator, hash_hex);

    return result.toOwnedSlice(allocator);
}

/// Calculate request signature using derived signing key
pub fn calculateSignature(
    allocator: Allocator,
    signing_key: []const u8,
    string_to_sign: []const u8,
) ![]const u8 {
    // Calculate HMAC-SHA256
    var hmac: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&hmac, string_to_sign, signing_key);

    // Convert to hex
    return std.fmt.allocPrint(allocator, "{x}", .{hmac});
}

/// Create final authorization header value
fn createAuthorizationHeader(
    allocator: Allocator,
    credentials: Credentials,
    signature: []const u8,
    timestamp: i64,
) ![]const u8 {
    const dt = UtcDateTime.init(timestamp);
    const date = try dt.formatAmzDate(allocator);
    defer allocator.free(date);

    return fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={s}",
        .{
            credentials.access_key,
            date,
            credentials.region,
            credentials.service,
            signature,
        },
    );
}

// Helper functions

fn normalizePath(allocator: Allocator, path: []const u8) ![]const u8 {
    // TODO: Implement proper URI normalization
    return allocator.dupe(u8, path);
}

fn createCanonicalQueryString(allocator: Allocator, path: []const u8) ![]const u8 {
    // TODO: Implement query string sorting and encoding
    _ = path;
    return allocator.dupe(u8, "");
}

/// Calculate SHA256 hash of payload
pub fn hashPayload(allocator: Allocator, payload: []const u8) ![]const u8 {
    var hash: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    return std.fmt.allocPrint(allocator, "{x}", .{hash});
}

pub fn deriveSigningKey(
    allocator: Allocator,
    secret_key: []const u8,
    date_str: []const u8,
    region: Region,
    service: Service,
) ![]const u8 {
    // kSecret = "AWS4" + secret access key
    const k_secret = try fmt.allocPrint(allocator, "AWS4{s}", .{secret_key});
    defer allocator.free(k_secret);

    // kDate = HMAC-SHA256(kSecret, date)
    var k_date: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_date, date_str, k_secret);

    // kRegion = HMAC-SHA256(kDate, region)
    var k_region: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_region, region, &k_date);

    // kService = HMAC-SHA256(kRegion, service)
    var k_service: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_service, service, &k_region);

    // kSigning = HMAC-SHA256(kService, "aws4_request")
    var k_signing: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&k_signing, "aws4_request", &k_service);

    return allocator.dupe(u8, &k_signing);
}

/// Calculate HMAC-SHA256 of a message using a key
fn hmacSha256(allocator: Allocator, key: []const u8, message: []const u8) ![]const u8 {
    var hmac: [crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    crypto.auth.hmac.sha2.HmacSha256.create(&hmac, message, key);

    // Convert to hex string
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hmac)});
}

test "AWS Signature V4" {
    const allocator = std.testing.allocator;

    const credentials = Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("host", "examplebucket.s3.amazonaws.com");
    try headers.put("x-amz-content-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    try headers.put("x-amz-date", "20130524T000000Z");

    const params = SigningParams{
        .method = "GET",
        .path = "/test.txt",
        .headers = headers,
        .timestamp = 1369353600, // 2013-05-24T00:00:00Z
    };

    const auth_header = try signRequest(allocator, credentials, params);
    defer allocator.free(auth_header);

    // TODO: Add proper test assertions once timestamp formatting is implemented
    try std.testing.expect(auth_header.len > 0);
}

test "hashPayload empty" {
    const allocator = std.testing.allocator;
    const hash = try hashPayload(allocator, "");
    defer allocator.free(hash);
    // SHA256 of empty string
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hash,
    );
}

test "hashPayload with content" {
    const allocator = std.testing.allocator;
    const content = "Hello, AWS!";
    const hash = try hashPayload(allocator, content);
    defer allocator.free(hash);
    try std.testing.expect(hash.len == 64); // SHA256 hex is 64 chars
}

test "createCanonicalRequest" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("host", "example.s3.amazonaws.com");
    try headers.put("x-amz-date", "20240101T000000Z");
    try headers.put("x-amz-content-sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    const params = SigningParams{
        .method = "GET",
        .path = "/test.txt",
        .headers = headers,
        .body = null,
        .timestamp = 1704067200, // 2024-01-01 00:00:00 UTC
    };

    const canonical_request = try createCanonicalRequest(allocator, params);
    defer allocator.free(canonical_request);

    try std.testing.expect(canonical_request.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, canonical_request, "GET\n"));
}

test "deriveSigningKey" {
    const allocator = std.testing.allocator;

    const credentials = Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    };

    const timestamp = 1704067200; // 2024-01-01 00:00:00 UTC
    const dt = UtcDateTime.init(timestamp);
    const date_str = try dt.formatAmzDate(allocator);
    defer allocator.free(date_str);

    const key = try deriveSigningKey(allocator, credentials.secret_key, date_str, credentials.region, credentials.service);
    defer allocator.free(key);

    try std.testing.expect(key.len > 0);
}

test "signRequest full flow" {
    const allocator = std.testing.allocator;

    const credentials = Credentials{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("host", "example.s3.amazonaws.com");
    try headers.put("x-amz-date", "20240101T000000Z");

    const params = SigningParams{
        .method = "GET",
        .path = "/test.txt",
        .headers = headers,
        .body = null,
        .timestamp = 1704067200, // 2024-01-01 00:00:00 UTC
    };

    const auth_header = try signRequest(allocator, credentials, params);
    defer allocator.free(auth_header);

    try std.testing.expect(std.mem.startsWith(u8, auth_header, "AWS4-HMAC-SHA256"));
    try std.testing.expect(std.mem.indexOf(u8, auth_header, credentials.access_key) != null);
}

test "createStringToSign" {
    const allocator = std.testing.allocator;
    const date_str = "20250120";
    const scope = "20250120/us-west-1/s3/aws4_request";
    const request = "GET\n/\n\nhost:example.com\n\nhost\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const timestamp: i64 = 1705790067; // 20250120T231427Z

    const string_to_sign = try createStringToSign(
        allocator,
        date_str,
        scope,
        request,
        timestamp,
    );
    defer allocator.free(string_to_sign);

    try std.testing.expect(string_to_sign.len > 0);
}
