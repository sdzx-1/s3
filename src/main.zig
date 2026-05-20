const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tracy = @import("tracy.zig");
const trace = tracy.trace;
const zio = @import("zio");
const acl = @import("acl.zig");
const troupe = @import("troupe");
const s3 = @import("s3.zig");
const run = @import("run.zig");
const Runner = s3.Runner;
const EnterState = s3.Start;

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    const gpa = init.gpa;

    // Parse CLI arguments
    var port: u16 = 9000;
    var data_dir: []const u8 = "data";
    var tmp_dir: []const u8 = "tmp";
    var raw_acl_list: []const u8 = "admin:minioadmin:minioadmin";
    var show_help: bool = false;

    var args = init.minimal.args.iterate();
    _ = args.skip(); // Skip program name
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            data_dir = arg[11..];
        } else if (std.mem.startsWith(u8, arg, "--tmp-dir=")) {
            tmp_dir = arg[10..];
        } else if (std.mem.startsWith(u8, arg, "--acl=")) {
            raw_acl_list = arg[6..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg[7..], 10) catch 9000;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        }
    }

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
            \\  --data-dir={s}
            \\      The directory to store bucket data under
            \\
            \\  --acl={s}
            \\      The credentials for access
            \\
            \\  --help, -h
            \\      Show this help
            \\
        , .{ port, data_dir, raw_acl_list });
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

    //
    const buffer = try gpa.alloc(s3.MsgWrapper, 1000);
    var msg_channel: s3.MsgChannel = .init(buffer);

    const buffer1 = try gpa.alloc(*s3.ClientContext, 1000);
    var clean_channel: run.CleanChannel = .init(buffer1);

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
    });
    defer s3server_thid.join();

    //free ClientContext memory
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
        ctx.wait_msg.re = .init;
        ctx.data_dir = data_dir;
        ctx.tmp_dir = tmp_dir;
        ctx.io = io;
        ctx.stream = stream;
        ctx.stream_reader = stream.reader(io, &.{});
        ctx.stream_writer = stream.writer(io, &.{});
        ctx.arena_allocaotr = .init(gpa);
        //TODO: free ctx
        const client_future = try io.concurrent(run.client, .{
            Runner.idFromState(EnterState),
            msg_channel,
            ctx,
            clean_channel,
        });
        ctx.future = client_future;
    }
}
