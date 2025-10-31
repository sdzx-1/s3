const std = @import("std");
const s3 = @import("s3");

pub fn main() !void {
    try s3.main();
}
