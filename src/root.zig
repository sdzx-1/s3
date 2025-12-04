const std = @import("std");
const zap = @import("zap");
const sqlite = @import("sqlite");
const signer = @import("auth/signer.zig");
const time = @import("auth//time.zig");

fn on_request(r: zap.Request) !void {

    // host: localhost:4567
    // accept-encoding: identity
    // user-agent: aws-cli/2.31.35 md/awscrt#0.28.4 ua/2.1 os/linux#6.1.21.2-microsoft-standard-WSL2+ md/arch#x86_64 lang/python#3.13.9 md/pyimpl#CPython m/Z,b,E,C,N,n cfg/retry-mode#standard md/installer#exe md/distrib#debian.12 md/prompt#off md/command#s3.ls
    // x-amz-date: 20251201T044132Z
    // x-amz-content-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    // authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20251201/us-west-2/s3/aws4_request,
    // SignedHeaders=host;x-amz-content-sha256;x-amz-date,
    // Signature=c688f7406d53f77d7459a4bb86077ed96f515052669888d5443d7f09986d225b
    //

    // host: localhost:4567
    // accept-encoding: identity
    // user-agent: aws-cli/2.31.35 md/awscrt#0.28.4 ua/2.1 os/linux#6.1.21.2-microsoft-standard-WSL2+ md/arch#x86_64 lang/python#3.13.9 md/pyimpl#CPython m/b,W,N,Z,n,E cfg/retry-mode#standard md/installer#exe md/distrib#debian.12 md/prompt#off md/command#s3api.put-object
    // content-encoding: aws-chunked
    // x-amz-trailer: x-amz-checksum-crc64nvme
    // x-amz-decoded-content-length: 0
    // x-amz-sdk-checksum-algorithm: CRC64NVME
    // x-amz-date: 20251204T021525Z
    // x-amz-content-sha256: STREAMING-UNSIGNED-PAYLOAD-TRAILER
    // authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20251204/us-west-2/s3/aws4_request,
    // SignedHeaders=content-encoding;host;x-amz-content-sha256;x-amz-date;x-amz-decoded-content-length;x-amz-sdk-checksum-algorithm;x-amz-trailer,
    // Signature=200f21074c04e9ea984c3d9ba6ef90b7d5f38cbd2b86153c6bcac352efe0869b
    // content-length: 44
    // body: 0
    // x-amz-checksum-crc64nvme:AAAAAAAAAAA=

    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_instance.allocator();
    //auth
    const credentials: signer.Credentials = .{
        .access_key = "AKIAIOSFODNN7EXAMPLE",
        .secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    };

    var headers = std.StringHashMap([]const u8).init(gpa);
    defer headers.deinit();
    // SignedHeaders=host;x-amz-content-sha256;x-amz-date,

    try headers.put("host", r.getHeader("host").?);
    try headers.put("x-amz-content-sha256", r.getHeader("x-amz-content-sha256").?);
    try headers.put("x-amz-date", r.getHeader("x-amz-date").?);

    // const req_time = r.getHeader("x-amz-date").?;
    // const t = time.UtcDateTime.init(timestamp_secs: i64)
    const params = signer.SigningParams{
        .method = r.method.?,
        .path = r.path.?,
        .headers = headers,
        .body = r.body,
        .timestamp = std.time.timestamp(),
    };

    _ = try signer.signRequest(gpa, credentials, params);

    //
    const header_list = try r.headersToOwnedList(gpa);

    for (header_list.items) |kv| {
        std.debug.print("{s}: {s}\n", .{ kv.key, kv.value });
    }

    if (r.body) |body| {
        std.debug.print("body: {s}\n", .{body});
    }
    try r.setHeader("Location", "/amzn-s3-demo-bucket-1");
    r.sendBody("") catch return;
}

const UserData = struct {
    gpa: std.mem.Allocator,
};

pub fn main() !void {
    const CERT_FILE = "data/mycert.pem";
    const KEY_FILE = "data/mykey.pem";

    const tls = try zap.Tls.init(.{
        .server_name = "localhost:4567",
        .public_certificate_file = CERT_FILE,
        .private_key_file = KEY_FILE,
    });
    defer tls.deinit();

    var listener = zap.HttpListener.init(.{
        .port = 4567,
        .on_request = on_request,
        .log = true,
        .tls = tls,
    });
    try listener.listen();

    std.debug.print("Listening on 0.0.0.0:4567\n", .{});

    // start worker threads
    zap.start(.{
        .threads = 2,
        .workers = 2,
    });
}
