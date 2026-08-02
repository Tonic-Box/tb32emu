const std = @import("std");
const WebView = @import("webview").WebView;
const server = @import("server.zig");

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var net_server = try address.listen(.{ .reuse_address = true });
    const port = net_server.listen_address.getPort();

    const thread = try std.Thread.spawn(.{}, server.serve, .{&net_server});
    thread.detach();

    std.debug.print("tb32emu: serving http://127.0.0.1:{d}/\n", .{port});

    const w = WebView.create(false, null);
    defer w.destroy();
    w.setTitle("tb32emu");
    w.setSize(1100, 720, .None);

    var ctx = WebView.CallbackContext(&ping).init(w.webview);
    w.bind("ping", &ctx);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/", .{port});
    w.navigate(url);
    w.run();
}

fn ping(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    _ = req;
    const view = WebView{ .webview = data };
    view.ret(seq, 0, "\"pong from zig\"");
}
