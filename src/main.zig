const std = @import("std");
const builtin = @import("builtin");
const WebView = @import("webview").WebView;
const server = @import("server.zig");
const assemble = @import("assemble.zig");
const emulator = @import("emulator.zig");

var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
var emu: emulator.Emulator = undefined;

pub fn main() !void {
    const gpa = gpa_state.allocator();
    emu = try emulator.Emulator.init(gpa);

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
    var run_ctx = WebView.CallbackContext(&onRun).init(w.webview);
    w.bind("run", &run_ctx);
    var tick_ctx = WebView.CallbackContext(&onTick).init(w.webview);
    w.bind("emuTick", &tick_ctx);
    var stop_ctx = WebView.CallbackContext(&onStop).init(w.webview);
    w.bind("emuStop", &stop_ctx);

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

fn onRun(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = firstStringArg(a, req) orelse {
        view.ret(seq, 1, "\"bad request\"");
        return;
    };
    var diag: @import("tb32").Diagnostic = .{};
    emu.start(src, &diag) catch {
        var buf: [256]u8 = undefined;
        const j = std.fmt.bufPrintZ(&buf, "{{\"ok\":false,\"line\":{d},\"message\":\"{s}\"}}", .{ diag.line, diag.message }) catch "{\"ok\":false,\"line\":0,\"message\":\"error\"}";
        view.ret(seq, 0, j);
        return;
    };
    view.ret(seq, 0, "{\"ok\":true}");
}

fn onTick(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var max: u32 = 200_000;
    if (jsonArray(a, req)) |args| {
        if (args.len >= 1 and args[0] == .string) {
            if (decodeB64(a, args[0].string)) |bytes| {
                emu.feedInput(bytes) catch {};
            } else |_| {}
        }
        if (args.len >= 2) {
            if (jsonU32(args[1])) |m| max = m;
        }
    }

    const status = emu.tick(max);
    const out_b64 = encodeB64(a, emu.takeOutput()) catch "";
    emu.clearOutput();

    const tail: []const u8 = switch (status) {
        .running => "running\"",
        .halted => "halted\"",
        .waiting_input => "waiting\"",
        .exited => |c| std.fmt.allocPrint(a, "exited\",\"code\":{d}", .{c}) catch "exited\"",
        .sleep_ms => |ms| std.fmt.allocPrint(a, "sleep\",\"ms\":{d}", .{ms}) catch "sleep\"",
        .fault => |f| std.fmt.allocPrint(a, "fault\",\"code\":{d},\"pc\":{d}", .{ f.code, f.pc }) catch "fault\"",
    };
    const json = std.fmt.allocPrintZ(a, "{{\"out\":\"{s}\",\"raw\":{},\"state\":\"{s}}}", .{ out_b64, emu.isRaw(), tail }) catch {
        view.ret(seq, 0, "{\"state\":\"error\"}");
        return;
    };
    view.ret(seq, 0, json);
}

fn onStop(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    _ = req;
    emu.started = false;
    const view = WebView{ .webview = data };
    view.ret(seq, 0, "{\"ok\":true}");
}

fn firstStringArg(a: std.mem.Allocator, req: []const u8) ?[]const u8 {
    const args = jsonArray(a, req) orelse return null;
    if (args.len < 1) return null;
    return switch (args[0]) {
        .string => |s| s,
        else => null,
    };
}

fn jsonArray(a: std.mem.Allocator, req: []const u8) ?[]std.json.Value {
    const val = std.json.parseFromSliceLeaky(std.json.Value, a, req, .{}) catch return null;
    return switch (val) {
        .array => |arr| arr.items,
        else => null,
    };
}

fn jsonU32(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        else => null,
    };
}

fn encodeB64(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const dst = try a.alloc(u8, enc.calcSize(src.len));
    return enc.encode(dst, src);
}

fn decodeB64(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(s);
    const dst = try a.alloc(u8, n);
    try dec.decode(dst, s);
    return dst;
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
    _ = emulator;
    _ = @import("loader.zig");
}
