const std = @import("std");
const zap = @import("zap");
const sqlite = @import("sqlite");

fn on_request(r: zap.Request) !void {
    if (r.path) |the_path| {
        std.debug.print("PATH: {s}\n", .{the_path});
    }

    if (r.query) |the_query| {
        std.debug.print("QUERY: {s}\n", .{the_query});
    }
    r.sendBody("<html><body><h1>Hello from ZAP!!!</h1></body></html>") catch return;
}

pub fn main() !void {
    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = "mydata.db" },
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .SingleThread,
    });

    try db.exec("CREATE TABLE IF NOT EXISTS employees(id integer primary key, name text, age integer, salary integer)", .{}, .{});

    const query =
        \\SELECT id, name, age, salary FROM employees WHERE age > ? AND age < ?
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    // var listener = zap.HttpListener.init(.{
    //     .port = 3000,
    //     .on_request = on_request,
    //     .log = true,
    // });
    // try listener.listen();

    // std.debug.print("Listening on 0.0.0.0:3000\n", .{});

    // // start worker threads
    // zap.start(.{
    //     .threads = 2,
    //     .workers = 2,
    // });
}
