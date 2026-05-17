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
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{ .executors = .exact(10) });
    defer rt.deinit();
    const io = rt.io();
    const gpa = init.gpa;

    var graph: troupe.Graph = try .initWithFsm(gpa, Ping);
    const ff: Io.File = try Io.Dir.cwd().createFile(io, "graph.dot", .{});
    var ff_writer = ff.writer(io, &.{});
    const writer = &ff_writer.interface;

    try graph.generateDot(writer);

    const buffer = try gpa.alloc(MsgWrapper, 500);
    var msg_channel: MsgChannel = .init(buffer);

    _ = io.async(server, .{&msg_channel});

    var group: Io.Group = .init;

    const curr_id = Runner.idFromState(Ping);
    for (0..10000) |_| {
        const ctx = try gpa.create(ClientContext);
        ctx.io = io;
        ctx.wait_msg.re = .init;

        try group.concurrent(io, runClient, .{
            curr_id,
            &msg_channel,
            ctx,
        });
    }

    try group.await(io);
    std.debug.print("group: finish\n", .{});
}

const MsgWrapper = struct {
    _next: ?*MsgWrapper = null,
    id: usize, // cast form *WaitMsg
    msg: Msg,
};

const Msg = struct {
    state_id: u16,
    tag_id: u16,
    msg_union: MsgUnion,
};

const MsgUnion = union {
    void: void,
    i32: i32,

    pub fn to(self: @This(), T: type) T {
        if (T == void) {
            return self.void;
        } else if (T == i32) {
            return self.i32;
        } else {
            @panic("No impl!");
        }
    }

    pub fn from(T: type, val: T) @This() {
        if (T == void) {
            return .{ .void = val };
        } else if (T == i32) {
            return .{ .i32 = val };
        } else {
            @panic("No impl!");
        }
    }
};

const MsgChannel = zio.Channel(MsgWrapper);

const Runner = troupe.Runner(Ping);

pub fn TagPayloadByName(comptime U: type, comptime tag_name: []const u8) type {
    const info = @typeInfo(U).@"union";

    inline for (info.fields) |field_info| {
        if (comptime std.mem.eql(u8, field_info.name, tag_name))
            return field_info.type;
    }

    @compileError("no field '" ++ tag_name ++ "' in union '" ++ @typeName(U) ++ "'");
}

fn server(
    msg_channel: *MsgChannel,
) void {
    var curr_client: usize = undefined;
    var mmsg: ?Msg = undefined;
    var ctx: ServerContext = .{ .global_counter = 0 };

    while (true) {
        const msg_wrapper = msg_channel.receive() catch unreachable;
        curr_client = msg_wrapper.id;
        mmsg = msg_wrapper.msg;
        runServer(&curr_client, &mmsg, &ctx);
    }
}

/// The current design requires the first message of the protocol to be sent from the client to the server, making the server completely passive.
fn runServer(
    curr_client: *usize,
    mmsg: *?Msg,
    ctx: *ServerContext,
) void {
    const curr_id: Runner.StateId = @enumFromInt(mmsg.*.?.state_id);
    @setEvalBranchQuota(10_000_000);
    sw: switch (curr_id) {
        inline else => |state_id| {
            const Curr_State = Runner.StateFromId(state_id);
            if (Curr_State == troupe.Exit) return;
            const info = comptime Curr_State.info;
            if (comptime info.sender == .server) {
                //server send msg
                // Since no message queue is designed for client,
                // the protocol should not be designed to continuously send messages to the client.
                const result = Curr_State.process(ctx);
                const wait_msg: *WaitMsg = @ptrFromInt(curr_client.*);
                const msgref = &wait_msg.msg;
                msgref.state_id = @intFromEnum(state_id);
                switch (result) {
                    inline else => |data, tag| {
                        msgref.tag_id = @intFromEnum(tag);
                        msgref.msg_union = MsgUnion.from(@TypeOf(data.data), data.data);
                    },
                }
                wait_msg.re.set();

                switch (result) {
                    inline else => |new_fms_state_wit| {
                        const NewState = @TypeOf(new_fms_state_wit).State;
                        continue :sw comptime Runner.idFromState(NewState);
                    },
                }
            } else {
                // server recv msg
                if (mmsg.*) |msg| {
                    mmsg.* = null;
                    const tag: std.meta.Tag(Curr_State) = @enumFromInt(msg.tag_id);
                    switch (tag) {
                        inline else => |t| {
                            const DataType = @FieldType(TagPayloadByName(Curr_State, @tagName(t)), "data");
                            const recv_msg = @unionInit(
                                Curr_State,
                                @tagName(t),
                                .{ .data = msg.msg_union.to(DataType) },
                            );
                            Curr_State.preprocess_0(ctx, recv_msg);
                            switch (recv_msg) {
                                inline else => |new_fsm_state_wit| {
                                    const NewState = @TypeOf(new_fsm_state_wit).State;
                                    continue :sw comptime Runner.idFromState(NewState);
                                },
                            }
                        },
                    }
                }
            }
        },
    }
}

fn runClient(
    curr_id: Runner.StateId,
    msg_channel: *MsgChannel,
    ctx: *ClientContext,
) void {
    @setEvalBranchQuota(10_000_000);

    sw: switch (curr_id) {
        inline else => |state_id| {
            const Curr_State = Runner.StateFromId(state_id);
            if (Curr_State == troupe.Exit) return;
            const info = comptime Curr_State.info;
            if (comptime info.sender == .client) {
                //client send msg
                const result = Curr_State.process(ctx);

                var msg_wrapper: MsgWrapper = undefined;

                msg_wrapper._next = null;
                msg_wrapper.id = @intFromPtr(&ctx.wait_msg);

                const msgref = &msg_wrapper.msg;
                msgref.state_id = @intFromEnum(state_id);
                switch (result) {
                    inline else => |data, tag| {
                        msgref.tag_id = @intFromEnum(tag);
                        msgref.msg_union = MsgUnion.from(@TypeOf(data.data), data.data);
                    },
                }
                msg_channel.send(msg_wrapper) catch {
                    @panic(std.fmt.comptimePrint("error\n", .{}));
                };

                switch (result) {
                    inline else => |new_fms_state_wit| {
                        const NewState = @TypeOf(new_fms_state_wit).State;
                        continue :sw comptime Runner.idFromState(NewState);
                    },
                }
            } else {
                //client recv msg
                ctx.wait_msg.re.wait() catch unreachable;
                ctx.wait_msg.re.reset();

                const msg = ctx.wait_msg.msg;

                std.debug.assert(msg.state_id == @as(u16, @intFromEnum(state_id)));

                const tag: std.meta.Tag(Curr_State) = @enumFromInt(msg.tag_id);
                switch (tag) {
                    inline else => |t| {
                        const DataType = @FieldType(TagPayloadByName(Curr_State, @tagName(t)), "data");
                        const recv_msg = @unionInit(
                            Curr_State,
                            @tagName(t),
                            .{ .data = msg.msg_union.to(DataType) },
                        );
                        Curr_State.preprocess_0(ctx, recv_msg);
                        switch (recv_msg) {
                            inline else => |new_fsm_state_wit| {
                                const NewState = @TypeOf(new_fsm_state_wit).State;
                                continue :sw comptime Runner.idFromState(NewState);
                            },
                        }
                    },
                }
            }
        },
    }
}

//
pub const ServerContext = struct {
    global_counter: i32,
};

const WaitMsg = struct {
    msg: Msg,
    re: zio.ResetEvent,
};

pub const ClientContext = struct {
    io: Io,
    wait_msg: WaitMsg,
};

const Role = enum {
    client,
    server,
};

const Context = struct {
    client: type = ClientContext,
    server: type = ServerContext,
};

const context = Context{};

fn pingpogn_info(
    StateName: []const u8,
    sender: Role,
    receiver: []const Role,
) troupe.ProtocolInfo("pingpong", Role, context, &.{ .client, .server }, &.{troupe.Exit}) {
    return .{ .name = StateName, .sender = sender, .receiver = receiver };
}

pub const Ping = union(enum) {
    req_add: Data(void, Pong),

    pub const info = pingpogn_info("Ping", .client, &.{.server});

    pub fn process(ctx: *ClientContext) @This() {
        ctx.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        return .req_add;
    }

    pub fn preprocess_0(ctx: *ServerContext, msg: @This()) void {
        _ = ctx;
        _ = msg;
    }
};

pub const Pong = union(enum) {
    ok: Data(void, Ping),
    finish: Data(void, troupe.Exit),

    pub const info = pingpogn_info("Pong", .server, &.{.client});

    pub fn process(ctx: *ServerContext) @This() {
        // std.debug.print("counter: {d}\n", .{ctx.global_counter});
        if (ctx.global_counter > 1_000_000) {
            return .finish;
        } else {
            ctx.global_counter += 1;
            return .ok;
        }
    }

    pub fn preprocess_0(ctx: *ClientContext, msg: @This()) void {
        _ = ctx;
        _ = msg;
    }
};
