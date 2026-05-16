const std = @import("std");
const Io = std.Io;

const s3 = @import("s3");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
