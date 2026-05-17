const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tracy = @import("tracy.zig");
const trace = tracy.trace;
const zio = @import("zio");
const acl = @import("acl.zig");
const ConcurrentStack = @import("ConcurrentStack.zig");
const troupe = @import("troupe");
const Data = troupe.Data;

const s3 = @import("s3");

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const gpa = init.gpa;
    _ = gpa;
    _ = io;
}

const Msg = struct {
    _next: ?*Msg = null,
    fibe_id: usize,
    val: *anyopaque,
};

const MsgConcStack = ConcurrentStack(Msg);

// ResetEvent

pub const ServerContext = struct {
    server_counter: i32,
};

pub const ClientContext = struct {
    client_counter: i32,
};

const Role = enum {
    client,
    server,
};

const context = struct {
    client: type = ClientContext,
    server: type = ServerContext,
};

fn pingpogn_info(
    StateName: []const u8,
    sender: Role,
    receiver: []const Role,
) troupe.ProtocolInfo("pingpong", Role, context, &.{ .client, .server }, &.{troupe.Exit}) {
    return .{ .name = StateName, .sender = sender, .receiver = receiver };
}

pub const Ping = union(enum) {
    ping: Data(i32, Pong),
    next: Data(void, troupe.Exit),

    pub const info = pingpogn_info("Ping", .client, &.{.server});

    pub fn process(ctx: *info.Ctx(.client)) !@This() {
        if (ctx.client_counter == 2) {
            ctx.client_counter = 0;
            return .{ .next = .{ .data = {} } };
        }
        return .{ .ping = .{ .data = ctx.client_counter } };
    }

    pub fn preprocess_0(ctx: *info.Ctx(.server), msg: @This()) !void {
        switch (msg) {
            .ping => |val| ctx.server_counter = val.data,
            .next => {
                ctx.server_counter = 0;
            },
        }
    }
};

pub const Pong = union(enum) {
    pong: Data(i32, Ping),

    pub const info = pingpogn_info("Ping", .server, &.{.client});

    pub fn process(ctx: *ServerContext) !@This() {
        ctx.server_counter += 1;
        return .{ .ping = .{ .data = ctx.server_counter } };
    }

    pub fn preprocess_0(ctx: *ClientContext, msg: @This()) !void {
        switch (msg) {
            .pong => |val| ctx.client_counter = val.data,
        }
    }
};
