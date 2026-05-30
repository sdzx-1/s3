const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zio = @import("zio");
const polyrole = @import("polyrole");
const Data = polyrole.Data;
const acl = @import("acl.zig");
const zs3 = @import("zs3.zig");
const http = std.http;

pub const MsgWrapper = struct {
    id: *ClientContext, // cast form client's WaitMsg address
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
    const_u8: []const u8,
    client_context: *ClientContext,
    metrics: *Metrics,

    pub fn to(self: @This(), T: type) T {
        return switch (T) {
            void => {},
            i32 => self.i32,
            []const u8 => self.const_u8,
            *ClientContext => self.client_context,
            *Metrics => self.metrics,
            else => @compileError("Not support type: " ++ std.fmt.comptimePrint("{any}", .{T})),
        };
    }

    pub fn from(T: type, val: T) @This() {
        return switch (T) {
            void => .{ .void = {} },
            i32 => .{ .i32 = val },
            []const u8 => .{ .const_u8 = val },
            *ClientContext => .{ .client_context = val },
            *Metrics => .{ .metrics = val },
            else => @compileError("Not support type: " ++ std.fmt.comptimePrint("{any}", .{T})),
        };
    }
};

pub const MsgChannel = zio.Channel(MsgWrapper);

pub const Runner = polyrole.Runner(Start);

pub const WaitMsg = struct {
    msg: Msg,
    re: zio.ResetEvent,
};

pub const Metrics = struct {
    start: u32 = 0,
    server_lookup_credential: u32 = 0,
    sig_v4: u32 = 0,
    route: u32 = 0,
    success: u32 = 0,
    errors: u32 = 0,
    get_metrics: u32 = 0,
};

//
pub const ServerContext = struct {
    allocator: Allocator,
    access_control_map: std.StringHashMap(acl.Credential),
    global_counter: usize = 0,

    current_client: *ClientContext,
    log_writer: *Io.Writer,
    metrics: Metrics = .{},
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

    header_buf: ?[]const u8 = null,
    req: zs3.Request,
    res: zs3.Response,

    parsed_auth_header: zs3.SigV4.ParsedAuth,
    credential: acl.Credential,
    id: usize,

    metrics: Metrics,

    s3_error: ?S3Error = null,
    s3_send_error: ?SendError = null,

    pub fn init(
        ctx: *@This(),
        data_dir: []const u8,
        tmp_dir: []const u8,
        io: Io,
        stream: Io.net.Stream,
        gpa: std.mem.Allocator,
    ) !void {
        ctx.wait_msg.re = .init;
        ctx.data_dir = data_dir;
        ctx.tmp_dir = tmp_dir;
        ctx.io = io;
        ctx.stream = stream;
        ctx.socket_fd = stream.socket.handle;
        ctx.arena_allocaotr = .init(gpa);
        ctx.net_stream_reader = stream.reader(io, &ctx.read_buf);
        ctx.net_stream_writer = stream.writer(io, &ctx.write_buf);

        ctx.content_length = null;

        ctx.reader = .{
            .in = &ctx.net_stream_reader.interface,
            .max_head_len = zs3.MAX_HEADER_SIZE,
            .state = .ready,
            .interface = undefined,
        };

        ctx.writer = &ctx.net_stream_writer.interface;
        ctx.future = undefined;
        ctx.header_buf = null;
        ctx.req = undefined;
        ctx.res = undefined;

        ctx.parsed_auth_header = undefined;
        ctx.credential = undefined;
        ctx.id = undefined;

        ctx.s3_error = null;
        ctx.s3_send_error = null;
    }
};

pub const SendError = Io.net.Stream.Writer.Error;

pub const S3Error = union(enum) {
    start: StartStageError,
    server_lookup_credential: void,
    sigv4: SigV4StageError,
    route: RouteStageError,
};

pub const StartStageError = union(enum) {
    read_header_failed: std.http.Reader.HeadError,
    header_too_short: void,
    header_too_long: void,
    header_no_auth: void,
    parse_requeset_failed: void,
    stream_write_failed: void,
    invalid_authorization: void,
    invalid_request_less_line_end: void,
    invalid_request_less_method: void,
    invalid_request_less_full_path: void,
    payload_too_large: void,
};

pub const SigV4StageError = enum {
    auth_failed,
    not_allow_method,
};

pub const RouteStageError = union(enum) {
    invalid_bucket_name: void,
    invalid_key: void,
    use_reserved_suffix: void,
    unknow_post_operation: void,
    method_not_allowd: void,
    handleListBuckets: SumError,
    handleListObjects: SumError,
    handleGetObject: SumError,
    handleCreateBucket: SumError,
    handleUploadPart: SumError,
    handlePutObject: SumError,
    handleDeleteBucket: SumError,
    handleAbortMultipart: SumError,
    handleDeleteObject: SumError,
    handleHeadBucket: SumError,
    handleHeadObject: SumError,
    handleDeleteObjects: SumError,
    handleInitiateMultipart: SumError,
    handleCompleteMultipart: SumError,
};

pub const SumError = error{
    BodyTooShort,
} ||
    Io.File.OpenError ||
    Io.Dir.OpenError ||
    Io.Dir.CreateDirError ||
    Io.Dir.RenameError ||
    Io.Writer.Error ||
    Io.File.StatError ||
    Io.Reader.StreamError ||
    std.mem.Allocator.Error;

//TODO: use IoError to replace SumError;
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
) polyrole.ProtocolInfo("s3", Role, Context{}, &.{ .client, .server }, &.{polyrole.Exit}) {
    return .{
        .name = StateName,
        .sender = sender,
        .receiver = receiver,
    };
}

pub const Error = union(enum) {
    exit: Data(void, polyrole.Exit),

    pub const info = s3_info("Error", .server, &.{.client});

    pub fn process(ctx: *ServerContext) @This() {
        ctx.metrics.errors += 1;

        const writer = ctx.log_writer;
        const current_client = ctx.current_client;

        if (current_client.s3_send_error) |se| {
            switch (se) {
                error.SocketUnconnected => {
                    return .exit;
                },
                else => {},
            }
        }

        writer.print("s3_error: {any}, s3_send_error: {any}, header: {s}\n", .{
            current_client.s3_error,
            current_client.s3_send_error,
            current_client.header_buf orelse "",
        }) catch @panic("server log error!");

        writer.flush() catch @panic("server log flush error!");
        return .exit;
    }

    pub fn preprocess_0(ctx: *ClientContext, msg: @This()) void {
        _ = ctx;
        _ = msg;
    }
};

pub const Success = union(enum) {
    exit: Data(void, polyrole.Exit),

    pub const info = s3_info("Success", .server, &.{.client});

    pub fn process(ctx: *ServerContext) @This() {
        ctx.metrics.success += 1;
        return .exit;
    }

    pub fn preprocess_0(ctx: *ClientContext, msg: @This()) void {
        _ = ctx;
        _ = msg;
    }
};

pub fn Send(Next: type) type {
    return union(enum) {
        finish: Data(void, Next),
        failed: Data(void, Error),

        pub const info = s3_info("Send", .client, &.{.server});

        pub fn process(ctx: *ClientContext) @This() {
            ctx.res.write(ctx.io, ctx.writer, ctx.socket_fd) catch {
                ctx.s3_send_error = ctx.net_stream_writer.err orelse ctx.net_stream_writer.write_file_err;
                return .failed;
            };
            ctx.writer.flush() catch {
                ctx.s3_send_error = ctx.net_stream_writer.err orelse ctx.net_stream_writer.write_file_err;
                return .failed;
            };
            return .finish;
        }

        pub fn preprocess_0(ctx: *ServerContext, msg: @This()) void {
            _ = ctx;
            switch (msg) {
                .failed => {},
                .finish => {},
            }
        }
    };
}

pub fn WaitServer(Next: type, fun: ?fn (*ClientContext) anyerror!void) type {
    return union(enum) {
        notify: Data(void, Next),

        pub const info = s3_info("WaitServer", .server, &.{.client});

        pub fn process(ctx: *ServerContext) @This() {
            _ = ctx;
            return .notify;
        }

        pub fn preprocess_0(ctx: *ClientContext, _: @This()) void {
            if (fun) |f| f(ctx) catch {};
        }
    };
}

pub fn resp_metrics(ctx: *ClientContext) !void {
    const arena = ctx.arena_allocaotr.allocator();
    const res = &ctx.res;
    var allocating = Io.Writer.Allocating.init(arena);
    const writer = &allocating.writer;
    const m = ctx.metrics;
    try writer.print(
        \\start: {d},
        \\get_metrics: {d},
        \\server_lookup_credential: {d},
        \\sig_v4: {d},
        \\route: {d},
        \\success: {d},
        \\errors: {d},
        \\
    ,
        .{
            m.start,
            m.get_metrics,
            m.server_lookup_credential,
            m.sig_v4,
            m.route,
            m.success,
            m.errors,
        },
    );
    res.body = writer.buffered();
}

pub const Start = union(enum) {
    req_credential_and_id: Data(void, ServerLookupCredential),
    failed: Data(void, Send(Error)),
    get_metrics: Data(*Metrics, WaitServer(Send(Success), resp_metrics)),

    pub const info = s3_info("Start", .client, &.{.server});

    pub fn process(ctx: *ClientContext) @This() {
        const arena = ctx.arena_allocaotr.allocator();
        ctx.res = zs3.Response.init(arena);

        const data = ctx.reader.receiveHead() catch |err| {
            zs3.sendError(&ctx.res, 400, "InvalidHeader", "Read Header Failed");
            ctx.s3_error = .{ .start = .{ .read_header_failed = err } };
            return .failed;
        };
        ctx.header_buf = arena.dupe(u8, data) catch unreachable;

        if (!zs3.hasAuth(data)) {
            _ = ctx.writer.writeAll(zs3.ERROR_403) catch {
                ctx.s3_error = .{ .start = .stream_write_failed };
                return .failed;
            };
            ctx.s3_error = .{ .start = .header_no_auth };
            return .failed;
        }

        const line_end = std.mem.indexOf(u8, data, "\r\n") orelse {
            zs3.sendError(&ctx.res, 400, "InvalidRequest", "");
            ctx.s3_error = .{ .start = .invalid_request_less_line_end };
            return .failed;
        };

        const request_line = data[0..line_end];

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse {
            zs3.sendError(&ctx.res, 400, "InvalidRequest", "");
            ctx.s3_error = .{ .start = .invalid_request_less_method };
            return .failed;
        };
        const full_path = parts.next() orelse {
            zs3.sendError(&ctx.res, 400, "InvalidRequest", "");
            ctx.s3_error = .{ .start = .invalid_request_less_full_path };
            return .failed;
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

        if (std.mem.eql(u8, ctx.req.method, "GET") and
            std.mem.eql(u8, ctx.req.path, "/_s3_getmetrics") and
            std.mem.eql(u8, ctx.req.headers.get("authorization") orelse "", "metrics"))
        {
            return .{ .get_metrics = .{ .data = &ctx.metrics } };
        }

        if (headers.get("content-length")) |cl_str| {
            ctx.content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
            if (ctx.content_length.? > zs3.MAX_BODY_SIZE) {
                zs3.sendError(&ctx.res, 400, "PayloadTooLarge", "");
                ctx.s3_error = .{ .start = .payload_too_large };
                return .failed;
            }
            if (ctx.content_length.? > 0) {
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

        ctx.req.body = ctx.reader.bodyReader(&ctx.read_buf, .none, ctx.content_length);

        const auth_header = ctx.req.header("authorization") orelse "";
        ctx.parsed_auth_header = zs3.SigV4.parseAuthHeader(auth_header) orelse {
            zs3.sendError(&ctx.res, 403, "AccessDenied", "Invalid authorization");
            ctx.s3_error = .{ .start = .invalid_authorization };
            return .failed;
        };

        return .req_credential_and_id;
    }

    pub fn preprocess_0(ctx: *ServerContext, msg: @This()) void {
        ctx.metrics.start += 1;
        switch (msg) {
            .req_credential_and_id => {},
            .failed => {},
            .get_metrics => |req_c| {
                ctx.metrics.get_metrics += 1;
                req_c.data.* = ctx.metrics;
            },
        }
    }
};
pub const ServerLookupCredential = union(enum) {
    ok: Data(void, SigV4),
    no_access_key: Data(void, Send(Error)),

    pub const info = s3_info("ServerLookupCredential", .server, &.{.client});

    pub fn process(ctx: *ServerContext) @This() {
        ctx.metrics.server_lookup_credential += 1;

        ctx.global_counter += 1;
        const current_client = ctx.current_client;
        if (ctx.access_control_map.get(current_client.parsed_auth_header.access_key)) |credential| {
            current_client.credential = credential;
            current_client.id = ctx.global_counter;
            return .ok;
        }
        current_client.s3_error = .server_lookup_credential;
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
    failed: Data(void, Send(Error)),

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
            ctx.s3_error = .{ .sigv4 = .auth_failed };
            return .failed;
        }
        if (!acl_ctx.granted(ctx.req.method)) {
            zs3.sendError(&ctx.res, 403, "AccessDenied", "Insufficient permissions");
            ctx.s3_error = .{ .sigv4 = .not_allow_method };
            return .failed;
        }

        return .ok;
    }

    pub fn preprocess_0(ctx: *ServerContext, msg: @This()) void {
        ctx.metrics.sig_v4 += 1;

        switch (msg) {
            .failed => {},
            else => {},
        }
    }
};

pub const Route = union(enum) {
    ok: Data(void, Send(Success)),
    failed: Data(void, Send(Error)),

    pub const info = s3_info("Route", .client, &.{.server});

    pub fn process(ctx: *ClientContext) @This() {
        var path = ctx.req.path;
        if (path.len > 0 and path[0] == '/') path = path[1..];

        var path_parts = std.mem.splitScalar(u8, path, '/');
        const bucket = path_parts.next() orelse "";
        const key = path_parts.rest();

        if (bucket.len > 0 and !zs3.isValidBucketName(bucket)) {
            zs3.sendError(&ctx.res, 400, "InvalidBucketName", "Bucket name is invalid");
            ctx.s3_error = .{ .route = .invalid_bucket_name };
            return .failed;
        }
        if (key.len > 0 and !zs3.isValidKey(key)) {
            zs3.sendError(&ctx.res, 400, "InvalidKey", "Object key is invalid");
            ctx.s3_error = .{ .route = .invalid_key };
            return .failed;
        }
        if (key.len > 0 and zs3.isReservedKey(key)) {
            zs3.sendError(&ctx.res, 400, "InvalidArgument", "Key uses reserved suffix");
            ctx.s3_error = .{ .route = .use_reserved_suffix };
            return .failed;
        }
        const arena = ctx.arena_allocaotr.allocator();

        // Standard S3 routing (standalone mode or bucket operations)
        if (std.mem.eql(u8, ctx.req.method, "GET")) {
            if (bucket.len == 0) {
                zs3.handleListBuckets(ctx.io, ctx.data_dir, arena, &ctx.res) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleListBuckets");
                    ctx.s3_error = .{ .route = .{ .handleListBuckets = err } };
                    return .failed;
                };
            } else if (key.len == 0) {
                zs3.handleListObjects(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleListObjects");
                    ctx.s3_error = .{ .route = .{ .handleListObjects = err } };
                    return .failed;
                };
            } else {
                zs3.handleGetObject(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket, key) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleGetObject");
                    ctx.s3_error = .{ .route = .{ .handleGetObject = err } };
                    return .failed;
                };
            }
        } else if (std.mem.eql(u8, ctx.req.method, "PUT")) {
            if (key.len == 0) {
                zs3.handleCreateBucket(ctx.io, ctx.data_dir, arena, &ctx.res, bucket) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleCreateBucket");
                    ctx.s3_error = .{ .route = .{ .handleCreateBucket = err } };
                    return .failed;
                };
            } else if (zs3.hasQuery(ctx.req.query, "uploadId")) {
                zs3.handleUploadPart(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket, key, ctx.content_length.?) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleUploadPart");
                    ctx.s3_error = .{ .route = .{ .handleUploadPart = err } };
                    return .failed;
                };
            } else {
                zs3.handlePutObject(ctx.io, ctx.data_dir, ctx.id, ctx.tmp_dir, arena, &ctx.req, &ctx.res, bucket, key, ctx.content_length.?) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handlePutObject");
                    ctx.s3_error = .{ .route = .{ .handlePutObject = err } };
                    return .failed;
                };
            }
        } else if (std.mem.eql(u8, ctx.req.method, "DELETE")) {
            if (key.len == 0) {
                zs3.handleDeleteBucket(ctx.io, ctx.data_dir, arena, &ctx.res, bucket) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleDeleteBucket");
                    ctx.s3_error = .{ .route = .{ .handleDeleteBucket = err } };
                    return .failed;
                };
            } else if (zs3.hasQuery(ctx.req.query, "uploadId")) {
                zs3.handleAbortMultipart(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleAbortMultipart");
                    ctx.s3_error = .{ .route = .{ .handleAbortMultipart = err } };
                    return .failed;
                };
            } else {
                zs3.handleDeleteObject(ctx.io, ctx.data_dir, arena, &ctx.res, bucket, key) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleDeleteObject");
                    ctx.s3_error = .{ .route = .{ .handleDeleteObject = err } };
                    return .failed;
                };
            }
        } else if (std.mem.eql(u8, ctx.req.method, "HEAD")) {
            if (key.len == 0) {
                zs3.handleHeadBucket(ctx.io, ctx.data_dir, arena, &ctx.res, bucket) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleHeadBucket");
                    ctx.s3_error = .{ .route = .{ .handleHeadBucket = err } };
                    return .failed;
                };
            } else {
                zs3.handleHeadObject(ctx.io, ctx.data_dir, arena, &ctx.res, bucket, key) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleHeadObject");
                    ctx.s3_error = .{ .route = .{ .handleHeadObject = err } };
                    return .failed;
                };
            }
        } else if (std.mem.eql(u8, ctx.req.method, "POST")) {
            if (zs3.hasQuery(ctx.req.query, "delete")) {
                zs3.handleDeleteObjects(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleDeleteObjects");
                    ctx.s3_error = .{ .route = .{ .handleDeleteObjects = err } };
                    return .failed;
                };
            } else if (zs3.hasQuery(ctx.req.query, "uploads")) {
                zs3.handleInitiateMultipart(ctx.io, ctx.data_dir, arena, &ctx.res, bucket, key) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleInitiateMultipart");
                    ctx.s3_error = .{ .route = .{ .handleInitiateMultipart = err } };
                    return .failed;
                };
            } else if (zs3.hasQuery(ctx.req.query, "uploadId")) {
                zs3.handleCompleteMultipart(ctx.io, ctx.data_dir, arena, &ctx.req, &ctx.res, bucket, key) catch |err| {
                    zs3.sendError(&ctx.res, 500, "InternalError", "handleCompleteMultipart");
                    ctx.s3_error = .{ .route = .{ .handleCompleteMultipart = err } };
                    return .failed;
                };
            } else {
                zs3.sendError(&ctx.res, 400, "InvalidRequest", "Unknown POST operation");
                ctx.s3_error = .{ .route = .unknow_post_operation };
                return .failed;
            }
        } else {
            zs3.sendError(&ctx.res, 405, "MethodNotAllowed", "Method not allowed");
            ctx.s3_error = .{ .route = .method_not_allowd };
            return .failed;
        }

        return .ok;
    }

    pub fn preprocess_0(ctx: *ServerContext, msg: @This()) void {
        ctx.metrics.route += 1;
        switch (msg) {
            .failed => {},
            else => {},
        }
    }
};
