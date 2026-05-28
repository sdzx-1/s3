const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zio = @import("zio");
const troupe = @import("troupe");
const Data = troupe.Data;
const acl = @import("acl.zig");
const zs3 = @import("zs3.zig");
const http = std.http;

pub const MsgWrapper = struct {
    id: usize, // cast form client's WaitMsg address
    msg: Msg,
};

pub const Msg = struct {
    state_id: u16,
    tag_id: u16,
    msg_union: MsgUnion,
};

pub const MsgUnion = union {
    void: void,
    i32: i32,
    errors: Errors,
    const_u8: []const u8,
    req_credential_and_id: ReqCredentialAndId,
    client_context: *ClientContext,

    pub fn to(self: @This(), T: type) T {
        return switch (T) {
            void => {},
            i32 => self.i32,
            Errors => self.errors,
            []const u8 => self.const_u8,
            ReqCredentialAndId => self.req_credential_and_id,
            *ClientContext => self.client_context,
            else => @compileError("Not support type: " ++ std.fmt.comptimePrint("{any}", .{T})),
        };
    }

    pub fn from(T: type, val: T) @This() {
        return switch (T) {
            void => .{ .void = {} },
            i32 => .{ .i32 = val },
            Errors => .{ .errors = val },
            []const u8 => .{ .const_u8 = val },
            ReqCredentialAndId => .{ .req_credential_and_id = val },
            *ClientContext => .{ .client_context = val },
            else => @compileError("Not support type: " ++ std.fmt.comptimePrint("{any}", .{T})),
        };
    }
};

pub const MsgChannel = zio.Channel(MsgWrapper);

pub const Runner = troupe.Runner(Start);

pub const WaitMsg = struct {
    msg: Msg,
    re: zio.ResetEvent,
};

//
pub const ServerContext = struct {
    allocator: Allocator,
    access_control_map: std.StringHashMap(acl.Credential),
    global_counter: usize = 0,

    req_credential_and_id: ReqCredentialAndId = undefined,
};

pub const ClientContext = struct {
    future: Io.Future(void),
    wait_msg: WaitMsg,
    data_dir: []const u8,
    tmp_dir: []const u8,
    io: Io,

    stream: Io.net.Stream,
    socket_fd: std.posix.fd_t = 0,

    read_buf: [zs3.MAX_HEADER_SIZE]u8,
    write_buf: [1024 * 4]u8,

    net_stream_writer: Io.net.Stream.Writer,
    net_stream_reader: Io.net.Stream.Reader,
    arena_allocaotr: std.heap.ArenaAllocator,

    reader: http.Reader,
    writer: *Io.Writer,

    req: zs3.Request,
    res: zs3.Response,

    parsed_auth_header: zs3.SigV4.ParsedAuth,
    credential: acl.Credential,
    id: usize,

    s3_error: ?S3Error = null,
};

pub const S3Error = union(enum) {
    start: StartStageError,
    route: RouteStageError,
};

pub const StartStageError = enum {
    read_header_failed,
    header_too_short,
    header_too_long,
    header_no_auth,
    parse_requeset_failed,
    stream_write_failed,
    invalid_authorization,
    invalid_request_less_line_end,
    invalid_request_less_method,
    invalid_request_less_full_path,
    payload_too_large,
};

pub const RouteStageError = union(enum) {
    invalid_bucket_name: IoError,
    invalid_key: IoError,
    handleListBuckets: IoError,
    handleListObjects: IoError,
    handleGetObject: IoError,
    handleCreateBucket: IoError,
    handleUploadPart: IoError,
    handlePutObject: IoError,
    handleDeleteBucket: IoError,
    handleAbortMultipart: IoError,
    handleDeleteObject: IoError,
    handleHeadBucket: IoError,
    handleHeadObject: IoError,
    handleDeleteObjects: IoError,
    handleInitiateMultipart: IoError,
    handleCompleteMultipart: IoError,
};

pub const IoError = union(enum) {
    stream_reader_err: Io.net.Stream.Reader.Error,
    stream_writer_err: Io.net.Stream.Writer.Error,

    file_reader_err: Io.File.Reader.Error,
    file_reader_size_err: Io.File.Reader.SizeError,
    file_reader_seek_err: Io.File.Reader.SeekError,

    file_writer_err: Io.File.Writer.Error,
    file_writer_file_err: Io.File.Writer.WriteFileError,
    file_writer_seek_err: Io.File.Writer.SeekError,

    dir_open_err: Io.Dir.OpenError,
    file_open_err: Io.File.OpenError,
    create_dir_error: Io.Dir.CreateDirError,
    create_dir_path_error: Io.Dir.CreateDirPathError,
};

pub const Role = enum { client, server };

pub const Context = struct {
    client: type = ClientContext,
    server: type = ServerContext,
};

fn s3_info(
    StateName: []const u8,
    sender: Role,
    receiver: []const Role,
) troupe.ProtocolInfo("s3", Role, Context{}, &.{ .client, .server }, &.{troupe.Exit}) {
    return .{
        .name = StateName,
        .sender = sender,
        .receiver = receiver,
    };
}

const ReqCredentialAndId = struct {
    client_context: *ClientContext,
    access_key: []const u8,
    credential: *acl.Credential,
    id: *usize,
};

pub const Errors = enum {
    //Start
    read_header_failed,
    header_too_short,
    header_too_long,
    header_no_auth,
    parse_requeset_failed,
    stream_write_failed,
    invalid_authorization,
    invalid_request,
    payload_too_large,
    //Route
    invalid_bucket_name,
    invalid_key,
    handleListBuckets,
    handleListObjects,
    handleGetObject,
    handleCreateBucket,
    handleUploadPart,
    handlePutObject,
    handleDeleteBucket,
    handleAbortMultipart,
    handleDeleteObject,
    handleHeadBucket,
    handleHeadObject,
    handleDeleteObjects,
    handleInitiateMultipart,
    handleCompleteMultipart,
};

pub const Error = union(enum) {
    exit: Data(void, troupe.Exit),

    pub const info = s3_info("Route", .server, &.{.client});

    pub fn process(ctx: *ServerContext) @This() {
        _ = ctx;
        return .exit;
    }

    pub fn preprocess_0(ctx: *ClientContext, msg: @This()) void {
        _ = ctx;
        _ = msg;
    }
};

pub const Start = union(enum) {
    req_credential_and_id: Data(ReqCredentialAndId, ServerLookupCredential),
    failed: Data(*ClientContext, Error),

    pub const info = s3_info("Start", .client, &.{.server});

    pub fn process(ctx: *ClientContext) @This() {
        const data = ctx.reader.receiveHead() catch {
            zs3.sendError(&ctx.res, 400, "InvalidHeader", "Read Header Failed");
            ctx.s3_error = .{ .start = .read_header_failed };
            return .{ .failed = .{ .data = ctx } };
        };

        if (!zs3.hasAuth(data)) {
            _ = ctx.writer.writeAll(zs3.ERROR_403) catch {
                ctx.s3_error = .{ .start = .stream_write_failed };
                return .{ .failed = .{ .data = ctx } };
            };
            ctx.s3_error = .{ .start = .header_no_auth };
            return .{ .failed = .{ .data = ctx } };
        }

        const arena = ctx.arena_allocaotr.allocator();

        const line_end = std.mem.indexOf(u8, data, "\r\n") orelse {
            zs3.sendError(&ctx.res, 400, "InvalidRequest", "");
            ctx.s3_error = .{ .start = .invalid_request_less_line_end };
            return .{ .failed = .{ .data = ctx } };
        };

        const request_line = data[0..line_end];

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse {
            zs3.sendError(&ctx.res, 400, "InvalidRequest", "");
            ctx.s3_error = .{ .start = .invalid_request_less_method };
            return .{ .failed = .{ .data = ctx } };
        };
        const full_path = parts.next() orelse {
            zs3.sendError(&ctx.res, 400, "InvalidRequest", "");
            ctx.s3_error = .{ .start = .invalid_request_less_full_path };
            return .{ .failed = .{ .data = ctx } };
        };
        var path: []const u8 = full_path;
        var query: []const u8 = "";
        if (std.mem.indexOf(u8, full_path, "?")) |q_idx| {
            path = full_path[0..q_idx];
            query = full_path[q_idx + 1 ..];
        }

        var headers = std.StringHashMap([]const u8).init(arena);
        const header_section = data[line_end + 2 ..];

        var header_lines = std.mem.splitSequence(u8, header_section, "\r\n");
        while (header_lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOf(u8, line, ":") orelse continue;
            var name_buf: [128]u8 = undefined;
            const name = std.ascii.lowerString(&name_buf, std.mem.trim(u8, line[0..colon], " "));
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            headers.put(
                arena.dupe(u8, name) catch unreachable,
                arena.dupe(u8, value) catch unreachable,
            ) catch unreachable;
        }

        ctx.req.method = arena.dupe(u8, method) catch unreachable;
        ctx.req.path = arena.dupe(u8, path) catch unreachable;
        ctx.req.query = arena.dupe(u8, query) catch unreachable;
        ctx.req.headers = headers;

        var content_length: ?u64 = null;
        if (headers.get("content-length")) |cl_str| {
            content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
            if (content_length.? > zs3.MAX_BODY_SIZE) {
                zs3.sendError(&ctx.res, 400, "PayloadTooLarge", "");
                ctx.s3_error = .{ .start = .payload_too_large };
                return .{ .failed = .{ .data = ctx } };
            }
            if (content_length.? > 0) {
                // Handle Expect: 100-continue - send 100 Continue before reading body
                if (headers.get("expect")) |expect| {
                    if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                        ctx.writer.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch {
                            std.log.err("100-continue send error", .{});
                        };
                        ctx.writer.flush() catch {
                            std.log.err("100-continue send error", .{});
                        };
                    }
                }
            }
        }

        ctx.req.body = ctx.reader.bodyReader(&ctx.read_buf, .none, content_length);

        ctx.res = zs3.Response.init(arena);

        const auth_header = ctx.req.header("authorization") orelse "";
        ctx.parsed_auth_header = zs3.SigV4.parseAuthHeader(auth_header) orelse {
            zs3.sendError(&ctx.res, 403, "AccessDenied", "Invalid authorization");

            ctx.s3_error = .{ .start = .invalid_authorization };
            return .{ .failed = .{ .data = ctx } };
        };

        return .{ .req_credential_and_id = .{ .data = .{
            .client_context = ctx,
            .access_key = ctx.parsed_auth_header.access_key,
            .credential = &ctx.credential,
            .id = &ctx.id,
        } } };
    }

    pub fn preprocess_0(ctx: *ServerContext, msg: @This()) void {
        switch (msg) {
            .req_credential_and_id => |req_c| {
                ctx.req_credential_and_id = req_c.data;
            },
            else => {},
        }
    }
};
pub const ServerLookupCredential = union(enum) {
    ok: Data(void, SigV4),
    no_access_key: Data(void, troupe.Exit),

    pub const info = s3_info("ServerLookupCredential", .server, &.{.client});

    pub fn process(ctx: *ServerContext) @This() {
        ctx.global_counter += 1;
        if (ctx.access_control_map.get(ctx.req_credential_and_id.access_key)) |credential| {
            ctx.req_credential_and_id.credential.* = credential;
            ctx.req_credential_and_id.id.* = ctx.global_counter;
            return .ok;
        }
        return .no_access_key;
    }

    pub fn preprocess_0(ctx: *ClientContext, msg: @This()) void {
        switch (msg) {
            .no_access_key => {
                zs3.sendError(&ctx.res, 403, "AccessDenied", "InvalidAccessKeyId");
            },
            else => {},
        }
    }
};

pub const SigV4 = union(enum) {
    ok: Data(void, Route),
    auth_failed: Data(void, troupe.Exit),
    not_allow_method: Data(void, troupe.Exit),

    pub const info = s3_info("SigV4", .client, &.{.server});

    pub fn process(ctx: *ClientContext) @This() {
        const acl_ctx = zs3.SigV4.verify(
            ctx.credential,
            ctx.parsed_auth_header,
            &ctx.req,
            ctx.arena_allocaotr.allocator(),
        );

        // S3 API requires authentication
        if (!acl_ctx.authenticated) {
            zs3.sendError(&ctx.res, 403, "AccessDenied", "Invalid credentials");
            return .auth_failed;
        }
        if (!acl_ctx.granted(ctx.req.method)) {
            zs3.sendError(&ctx.res, 403, "AccessDenied", "Insufficient permissions");
            return .not_allow_method;
        }

        return .ok;
    }

    pub fn preprocess_0(ctx: *ServerContext, msg: @This()) void {
        _ = ctx;
        switch (msg) {
            else => {},
        }
    }
};

pub const Route = union(enum) {
    ok: Data(void, troupe.Exit),
    failed: Data(Errors, troupe.Exit),

    pub const info = s3_info("Route", .client, &.{.server});

    pub fn process(ctx: *ClientContext) @This() {
        var path = ctx.req.path;
        if (path.len > 0 and path[0] == '/') path = path[1..];

        var path_parts = std.mem.splitScalar(u8, path, '/');
        const bucket = path_parts.next() orelse "";
        const key = path_parts.rest();

        if (bucket.len > 0 and !zs3.isValidBucketName(bucket)) {
            zs3.sendError(&ctx.res, 400, "InvalidBucketName", "Bucket name is invalid");
            return .{ .failed = .{ .data = .invalid_bucket_name } };
        }
        if (key.len > 0 and !zs3.isValidKey(key)) {
            zs3.sendError(&ctx.res, 400, "InvalidKey", "Object key is invalid");
            return .{ .failed = .{ .data = .invalid_key } };
        }
        if (key.len > 0 and zs3.isReservedKey(key)) {
            zs3.sendError(&ctx.res, 400, "InvalidArgument", "Key uses reserved suffix");
            return .{ .failed = .{ .data = .invalid_key } };
        }
        const arena = ctx.arena_allocaotr.allocator();

        // Standard S3 routing (standalone mode or bucket operations)
        if (std.mem.eql(u8, ctx.req.method, "GET")) {
            if (bucket.len == 0) {
                zs3.handleListBuckets(ctx.io, ctx.data_dir, arena, &ctx.res) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleListBuckets");
                    return .{ .failed = .{ .data = .handleListBuckets } };
                };
            } else if (key.len == 0) {
                zs3.handleListObjects(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleListObjects");
                    return .{ .failed = .{ .data = .handleListObjects } };
                };
            } else {
                zs3.handleGetObject(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket, key) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleGetObject");
                    return .{ .failed = .{ .data = .handleGetObject } };
                };
            }
        } else if (std.mem.eql(u8, ctx.req.method, "PUT")) {
            if (key.len == 0) {
                zs3.handleCreateBucket(ctx.io, ctx.data_dir, arena, &ctx.res, bucket) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleCreateBucket");
                    return .{ .failed = .{ .data = .handleCreateBucket } };
                };
            } else if (zs3.hasQuery(ctx.req.query, "uploadId")) {
                zs3.handleUploadPart(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket, key) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleUploadPart");
                    return .{ .failed = .{ .data = .handleUploadPart } };
                };
            } else {
                zs3.handlePutObject(ctx.io, ctx.data_dir, ctx.id, ctx.tmp_dir, arena, &ctx.req, &ctx.res, bucket, key) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handlePutObject");
                    return .{ .failed = .{ .data = .handlePutObject } };
                };
            }
        } else if (std.mem.eql(u8, ctx.req.method, "DELETE")) {
            if (key.len == 0) {
                zs3.handleDeleteBucket(ctx.io, ctx.data_dir, arena, &ctx.res, bucket) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleDeleteBucket");
                    return .{ .failed = .{ .data = .handleDeleteBucket } };
                };
            } else if (zs3.hasQuery(ctx.req.query, "uploadId")) {
                zs3.handleAbortMultipart(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleAbortMultipart");
                    return .{ .failed = .{ .data = .handleAbortMultipart } };
                };
            } else {
                zs3.handleDeleteObject(ctx.io, ctx.data_dir, arena, &ctx.res, bucket, key) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleDeleteObject");
                    return .{ .failed = .{ .data = .handleDeleteObject } };
                };
            }
        } else if (std.mem.eql(u8, ctx.req.method, "HEAD")) {
            if (key.len == 0) {
                zs3.handleHeadBucket(ctx.io, ctx.data_dir, arena, &ctx.res, bucket) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleHeadBucket");
                    return .{ .failed = .{ .data = .handleHeadBucket } };
                };
            } else {
                zs3.handleHeadObject(ctx.io, ctx.data_dir, arena, &ctx.res, bucket, key) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleHeadObject");
                    return .{ .failed = .{ .data = .handleHeadObject } };
                };
            }
        } else if (std.mem.eql(u8, ctx.req.method, "POST")) {
            if (zs3.hasQuery(ctx.req.query, "delete")) {
                zs3.handleDeleteObjects(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleDeleteObjects");
                    return .{ .failed = .{ .data = .handleDeleteObjects } };
                };
            } else if (zs3.hasQuery(ctx.req.query, "uploads")) {
                zs3.handleInitiateMultipart(ctx.io, ctx.data_dir, arena, &ctx.res, bucket, key) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleInitiateMultipart");
                    return .{ .failed = .{ .data = .handleInitiateMultipart } };
                };
            } else if (zs3.hasQuery(ctx.req.query, "uploadId")) {
                zs3.handleCompleteMultipart(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket, key) catch {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleCompleteMultipart");
                    return .{ .failed = .{ .data = .handleCompleteMultipart } };
                };
            } else {
                zs3.sendError(&ctx.res, 400, "InvalidRequest", "Unknown POST operation");
            }
        } else {
            zs3.sendError(&ctx.res, 405, "MethodNotAllowed", "Method not allowed");
        }

        return .ok;
    }

    pub fn preprocess_0(ctx: *ServerContext, msg: @This()) void {
        _ = ctx;
        switch (msg) {
            else => {},
        }
    }
};
