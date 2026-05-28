const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tracy = @import("tracy.zig");
const trace = tracy.trace;
const zio = @import("zio");
const acl = @import("acl.zig");
const troupe = @import("troupe");
const s3 = @import("s3.zig");
const zs3 = @import("zs3.zig");
const run = @import("run.zig");
const Runner = s3.Runner;
const EnterState = s3.Start;

pub fn main(init: std.process.Init) !void {

    // Parse CLI arguments
    var port: u16 = 9000;
    var data_dir: []const u8 = "data";
    var tmp_dir: []const u8 = "tmp";
    var log_file: []const u8 = ".s3.log";
    var raw_acl_list: []const u8 = "admin:minioadmin:minioadmin";
    var show_help: bool = false;
    var executor_threads: u6 = 4;

    var args = init.minimal.args.iterate();
    _ = args.skip(); // Skip program name
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            data_dir = arg[11..];
        } else if (std.mem.startsWith(u8, arg, "--tmp-dir=")) {
            tmp_dir = arg[10..];
        } else if (std.mem.startsWith(u8, arg, "--log-file=")) {
            log_file = arg[11..];
        } else if (std.mem.startsWith(u8, arg, "--zio-threads=")) {
            executor_threads = std.fmt.parseInt(u6, arg[14..], 10) catch |err| {
                std.log.err("Invalid threads: {t}", .{err});
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--acl=")) {
            raw_acl_list = arg[6..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg[7..], 10) catch |err| {
                std.log.err("Invalid port: {t}", .{err});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        }
    }

    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{ .executors = .exact(executor_threads) });
    defer rt.deinit();
    const io = rt.io();
    const gpa = init.gpa;

    if (show_help) {
        std.debug.print(
            \\s3 compatible storage
            \\
            \\Usage: s3 [OPTIONS]
            \\
            \\Options:
            \\  --port={d}
            \\      HTTP port to listen on
            \\
            \\  --zio-threads={d}
            \\      Number of zio executor threads to run (including main)
            \\      0 = auto-detect based on CPU count
            \\      1 = single-threaded, no worker threads
            \\
            \\  --data-dir={s}
            \\      The directory to store bucket data under
            \\
            \\  --tmp-dir={s}
            \\      The directory to store tmp object data
            \\
            \\  --log-file={s}
            \\      The s3 log file
            \\
            \\  --acl={s}
            \\      The credentials for access
            \\
            \\  --help, -h
            \\      Show this help
            \\
        , .{ port, executor_threads, data_dir, tmp_dir, log_file, raw_acl_list });
        return;
    }

    const access_control_list = acl.parseCredentials(gpa, raw_acl_list) catch |err| {
        std.log.err("Invalid --acl / -Dacl-list value: {s}", .{@errorName(err)});
        return err;
    };
    defer gpa.free(access_control_list);

    if (std.mem.eql(u8, raw_acl_list, "admin:minioadmin:minioadmin")) {
        std.log.warn("Using built-in default credentials (admin:minioadmin:minioadmin) — DO NOT USE IN PRODUCTION", .{});
    }

    // var dot_file = try Io.Dir.cwd().createFile(io, "graph.dot", .{});
    // var dot_file_wirter = dot_file.writer(io, &.{});
    // var graph = try troupe.Graph.initWithFsm(gpa, EnterState);
    // try graph.generateDot(&dot_file_wirter.interface);

    Io.Dir.cwd().createDir(io, data_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    Io.Dir.cwd().createDir(io, tmp_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Keys reference slices in raw_acl_list (argv or build_options string), both of
    // which outlive the process — safe to store as map keys without copying.
    var access_control_map = std.StringHashMap(acl.Credential).init(gpa);
    errdefer access_control_map.deinit();

    for (access_control_list) |credential| {
        const gop = try access_control_map.getOrPut(credential.access_key);
        if (gop.found_existing) {
            std.log.err("Duplicate access key '{s}' in ACL list", .{credential.access_key});
            return error.DuplicateAccessKey;
        }
        gop.value_ptr.* = credential;
    }

    const address = Io.net.IpAddress.parseIp4("0.0.0.0", port) catch |err| {
        return err;
    };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("S3 server listening on http://0.0.0.0:{d}", .{port});
    std.log.warn("backend: {any}\n", .{zio.ev.backend});

    //
    const buffer = try gpa.alloc(s3.MsgWrapper, 1000);
    var msg_channel: s3.MsgChannel = .init(buffer);

    const buffer1 = try gpa.alloc(*s3.ClientContext, 1000);
    var clean_channel: run.CleanChannel = .init(buffer1);

    const file_log = Io.Dir.cwd().createFile(io, log_file, .{}) catch |err| {
        std.log.err("Can't create log file: {s}", .{log_file});
        return err;
    };
    var log_buf: [400]u8 = undefined;
    var log_writer = file_log.writer(io, &log_buf);

    var server_thid = try std.Thread.spawn(.{}, accept_loop, .{
        io,
        gpa,
        &server,
        data_dir,
        tmp_dir,
        &msg_channel,
        &clean_channel,
    });
    defer server_thid.join();

    var s3server_thid = try std.Thread.spawn(.{}, run.server, .{
        gpa,
        access_control_map,
        &msg_channel,
        &log_writer.interface,
    });
    defer s3server_thid.join();

    // await client.future, free ClientContext memory
    while (true) {
        const client = clean_channel.receive() catch return;
        client.future.await(io);
        gpa.destroy(client);
    }
}

fn accept_loop(
    io: Io,
    gpa: Allocator,
    server: *Io.net.Server,
    data_dir: []const u8,
    tmp_dir: []const u8,
    msg_channel: *s3.MsgChannel,
    clean_channel: *run.CleanChannel,
) !void {
    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);

        const ctx = try gpa.create(s3.ClientContext);
        try ctx.init(data_dir, tmp_dir, io, stream, gpa);

        const client_future = try io.concurrent(run.client, .{
            Runner.idFromState(EnterState),
            msg_channel,
            ctx,
            clean_channel,
        });
        ctx.future = client_future;
    }
}
