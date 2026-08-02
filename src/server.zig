const std = @import("std");

const Asset = struct { path: []const u8, body: []const u8, ctype: []const u8 };

const assets = [_]Asset{
    .{ .path = "/", .body = @embedFile("web/index.html"), .ctype = "text/html; charset=utf-8" },
    .{ .path = "/index.html", .body = @embedFile("web/index.html"), .ctype = "text/html; charset=utf-8" },
    .{ .path = "/style.css", .body = @embedFile("web/style.css"), .ctype = "text/css; charset=utf-8" },
    .{ .path = "/app.js", .body = @embedFile("web/app.js"), .ctype = "text/javascript; charset=utf-8" },
};

fn lookup(target: []const u8) ?Asset {
    var path = target;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    for (assets) |a| {
        if (std.mem.eql(u8, a.path, path)) return a;
    }
    return null;
}

/// Accepts connections on `net_server` forever, serving the embedded frontend assets.
pub fn serve(net_server: *std.net.Server) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const conn = net_server.accept() catch continue;
        defer conn.stream.close();
        var http = std.http.Server.init(conn, &buf);
        var request = http.receiveHead() catch continue;
        respond(&request) catch {};
    }
}

fn respond(request: *std.http.Server.Request) !void {
    if (lookup(request.head.target)) |a| {
        try request.respond(a.body, .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = a.ctype }},
        });
    } else {
        try request.respond("not found", .{ .status = .not_found, .keep_alive = false });
    }
}
