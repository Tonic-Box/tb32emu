const std = @import("std");
const builtin = @import("builtin");
const WebView = @import("webview").WebView;
const server = @import("server.zig");
const assemble = @import("assemble.zig");

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var net_server = try address.listen(.{ .reuse_address = true });
    const port = net_server.listen_address.getPort();

    const thread = try std.Thread.spawn(.{}, server.serve, .{&net_server});
    thread.detach();

    std.debug.print("tb32emu: serving http://127.0.0.1:{d}/\n", .{port});

    const w = WebView.create(false, null);
    defer w.destroy();
    w.setTitle("TB32 Emulator");
    w.setSize(1100, 720, .None);
    if (builtin.os.tag == .windows) setWindowIcon(w);

    var assemble_ctx = WebView.CallbackContext(&onAssemble).init(w.webview);
    w.bind("assemble", &assemble_ctx);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/", .{port});
    w.navigate(url);
    w.run();
}

fn onAssemble(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = firstStringArg(a, req) orelse {
        view.ret(seq, 1, "\"bad request\"");
        return;
    };
    var out: [256]u8 = undefined;
    view.ret(seq, 0, assemble.assembleToJson(a, src, &out));
}

fn firstStringArg(a: std.mem.Allocator, req: []const u8) ?[]const u8 {
    const val = std.json.parseFromSliceLeaky(std.json.Value, a, req, .{}) catch return null;
    const arr = switch (val) {
        .array => |arr| arr,
        else => return null,
    };
    if (arr.items.len < 1) return null;
    return switch (arr.items[0]) {
        .string => |s| s,
        else => null,
    };
}

const windows = std.os.windows;
const IMAGE_ICON: c_uint = 1;
const LR_DEFAULTSIZE: c_uint = 0x40;
const WM_SETICON: c_uint = 0x0080;
const ICON_SMALL: usize = 0;
const ICON_BIG: usize = 1;

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(windows.WINAPI) ?windows.HINSTANCE;
extern "user32" fn LoadImageW(hinst: ?windows.HINSTANCE, name: ?*const anyopaque, kind: c_uint, cx: c_int, cy: c_int, load: c_uint) callconv(windows.WINAPI) ?*anyopaque;
extern "user32" fn SendMessageW(hwnd: ?*anyopaque, msg: c_uint, wparam: usize, lparam: isize) callconv(windows.WINAPI) isize;

fn setWindowIcon(w: WebView) void {
    const hwnd = w.getWindow() orelse return;
    const hinst = GetModuleHandleW(null);
    const name: *const anyopaque = @ptrFromInt(1);
    if (LoadImageW(hinst, name, IMAGE_ICON, 0, 0, LR_DEFAULTSIZE)) |ic| {
        _ = SendMessageW(hwnd, WM_SETICON, ICON_BIG, @bitCast(@intFromPtr(ic)));
    }
    if (LoadImageW(hinst, name, IMAGE_ICON, 16, 16, 0)) |ic| {
        _ = SendMessageW(hwnd, WM_SETICON, ICON_SMALL, @bitCast(@intFromPtr(ic)));
    }
}

test {
    _ = assemble;
}
