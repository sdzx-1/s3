const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tracy = @import("tracy.zig");
const trace = tracy.trace;
const zio = @import("zio");
const acl = @import("acl.zig");

const s3 = @import("s3");

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const gpa = init.gpa;
    // const arena = init.arena.allocator();

    // Parse CLI arguments
    var port: u16 = 9000;
    var data_dir: []const u8 = "data";
    var raw_acl_list: []const u8 = "admin:minioadmin:minioadmin";
    var show_help: bool = false;

    var args = init.minimal.args.iterate();
    _ = args.skip(); // Skip program name
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            data_dir = arg[11..];
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

    var ctx = S3Context{
        .allocator = gpa,
        .data_dir = data_dir,
        .access_control_map = access_control_map,
    };
    defer ctx.deinit();

    const address = Io.net.IpAddress.parseIp4("0.0.0.0", port) catch |err| {
        return err;
    };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("S3 server listening on http://0.0.0.0:{d}", .{port});

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);
        try group.concurrent(io, handleClient, .{ io, stream });
    }
}

fn handleClient(io: Io, stream: Io.net.Stream) !void {
    _ = io;
    _ = stream;
}

const S3Context = struct {
    allocator: Allocator,
    data_dir: []const u8,
    access_control_map: std.StringHashMap(acl.Credential),

    fn bucketPath(self: *const S3Context, allocator: Allocator, bucket: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &[_][]const u8{ self.data_dir, bucket });
    }

    fn objectPath(self: *const S3Context, allocator: Allocator, bucket: []const u8, key: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &[_][]const u8{ self.data_dir, bucket, key });
    }

    pub fn deinit(self: *S3Context) void {
        self.access_control_map.deinit();
    }
};
