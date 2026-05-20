const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zio = @import("zio");
const troupe = @import("troupe");
const Data = troupe.Data;
const acl = @import("acl.zig");

const s3 = @import("s3.zig");
const ClientContext = s3.ClientContext;
const Context = s3.Context;
const Msg = s3.Msg;
const MsgChannel = s3.MsgChannel;
const MsgUnion = s3.MsgUnion;
const MsgWrapper = s3.MsgWrapper;
const Role = s3.Role;
const Runner = s3.Runner;
const S3Context = s3.S3Context;
const ServerContext = s3.ServerContext;
const Stage1 = s3.Stage1;
const WaitMsg = s3.WaitMsg;

pub fn TagPayloadByName(comptime U: type, comptime tag_name: []const u8) type {
    const info = @typeInfo(U).@"union";

    inline for (info.fields) |field_info| {
        if (comptime std.mem.eql(u8, field_info.name, tag_name))
            return field_info.type;
    }

    @compileError("no field '" ++ tag_name ++ "' in union '" ++ @typeName(U) ++ "'");
}

pub fn server(
    gpa: Allocator,
    access_control_map: std.StringHashMap(acl.Credential),
    msg_channel: *MsgChannel,
) void {
    var curr_client: usize = undefined;
    var mmsg: ?Msg = undefined;
    var ctx: ServerContext = .{
        .allocator = gpa,
        .access_control_map = access_control_map,
    };

    while (true) {
        const msg_wrapper = msg_channel.receive() catch |err| switch (err) {
            error.Canceled => return,
            else => unreachable,
        };
        curr_client = msg_wrapper.id;
        mmsg = msg_wrapper.msg;
        runServer(&curr_client, &mmsg, &ctx);
    }
}

/// The current design requires the first message of the protocol to be sent from the client to the server, making the server completely passive.
pub fn runServer(
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
                // server send msg
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

pub const CleanChannel = zio.Channel(*s3.ClientContext);

pub fn client(
    curr_id: Runner.StateId,
    msg_channel: *MsgChannel,
    ctx: *ClientContext,
    clean_channel: *CleanChannel,
) void {
    runClient(curr_id, msg_channel, ctx);
    if (ctx.is_res) {
        ctx.res.write(ctx.stream, &ctx.stream_writer.interface) catch |err| {
            std.log.err("Http response write failed: {t}", .{err});
        };
    }
    ctx.arena_allocaotr.deinit();
    ctx.stream.close(ctx.io);
    clean_channel.send(ctx) catch unreachable;
}

pub fn runClient(
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
