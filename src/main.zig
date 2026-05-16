const std = @import("std");
const Io = std.Io;
const tracy = @import("tracy.zig");
const trace = tracy.trace;

const s3 = @import("s3");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    tracy.frameMark();
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    for (0..100) |_| {
        try io.sleep(.fromSeconds(1), .awake);
        foo();
    }
}

fn foo() void {
    const tracy_fun = trace(@src());
    defer tracy_fun.end();

    std.debug.print("some thing", .{});
}
