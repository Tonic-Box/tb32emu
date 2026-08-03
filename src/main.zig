const std = @import("std");
const builtin = @import("builtin");
const WebView = @import("webview").WebView;
const server = @import("server.zig");
const bridge = @import("bridge.zig");
const emulator = @import("emulator.zig");
const dialogs = @import("dialogs.zig");

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
    var dbgstep_ctx = WebView.CallbackContext(&onDbgStep).init(w.webview);
    w.bind("dbgStep", &dbgstep_ctx);
    var dbgbreak_ctx = WebView.CallbackContext(&onDbgBreak).init(w.webview);
    w.bind("dbgBreak", &dbgbreak_ctx);
    var dbgsnap_ctx = WebView.CallbackContext(&onDbgSnapshot).init(w.webview);
    w.bind("dbgSnapshot", &dbgsnap_ctx);
    var dbglines_ctx = WebView.CallbackContext(&onDbgLines).init(w.webview);
    w.bind("dbgLines", &dbglines_ctx);
    var termsize_ctx = WebView.CallbackContext(&onSetTermSize).init(w.webview);
    w.bind("setTermSize", &termsize_ctx);
    var fopen_ctx = WebView.CallbackContext(&onFileOpen).init(w.webview);
    w.bind("fileOpen", &fopen_ctx);
    var fsave_ctx = WebView.CallbackContext(&onFileSave).init(w.webview);
    w.bind("fileSave", &fsave_ctx);
    var fsaveas_ctx = WebView.CallbackContext(&onFileSaveAs).init(w.webview);
    w.bind("fileSaveAs", &fsaveas_ctx);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}/", .{port});
    w.navigate(url);
    w.run();
}

const BridgeFn = fn (std.mem.Allocator, *emulator.Emulator, []const u8) [:0]const u8;

fn dispatch(comptime f: BridgeFn, seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    view.ret(seq, 0, f(arena.allocator(), &emu, req));
}

fn onAssemble(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.assemble, seq, req, data);
}
fn onRun(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.run, seq, req, data);
}
fn onTick(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.tick, seq, req, data);
}
fn onDbgStep(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.stepLine, seq, req, data);
}
fn onDbgBreak(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.setBreak, seq, req, data);
}
fn onDbgSnapshot(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.snapshot, seq, req, data);
}
fn onDbgLines(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.lines, seq, req, data);
}
fn onStop(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.stop, seq, req, data);
}
fn onSetTermSize(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    dispatch(bridge.setTermSize, seq, req, data);
}

fn onFileOpen(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    _ = req;
    const view = WebView{ .webview = data };
    if (builtin.os.tag == .windows) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = (dialogs.openDialog(a) catch null) orelse return view.ret(seq, 0, "{\"ok\":false}");
        const content = std.fs.cwd().readFileAlloc(a, path, 16 * 1024 * 1024) catch return view.ret(seq, 0, "{\"ok\":false}");
        const pb = bridge.encodeB64(a, path) catch "";
        const nb = bridge.encodeB64(a, std.fs.path.basename(path)) catch "";
        const cb = bridge.encodeB64(a, content) catch "";
        const json = std.fmt.allocPrintZ(a, "{{\"ok\":true,\"path\":\"{s}\",\"name\":\"{s}\",\"content\":\"{s}\"}}", .{ pb, nb, cb }) catch return view.ret(seq, 0, "{\"ok\":false}");
        view.ret(seq, 0, json);
    } else {
        view.ret(seq, 0, "{\"ok\":false}");
    }
}

fn onFileSave(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = bridge.jsonArray(a, req) orelse return view.ret(seq, 0, "{\"ok\":false}");
    if (args.len < 2) return view.ret(seq, 0, "{\"ok\":false}");
    const path = decodeArg(a, args[0]) orelse return view.ret(seq, 0, "{\"ok\":false}");
    const content = decodeArg(a, args[1]) orelse return view.ret(seq, 0, "{\"ok\":false}");
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = content }) catch return view.ret(seq, 0, "{\"ok\":false}");
    view.ret(seq, 0, "{\"ok\":true}");
}

fn onFileSaveAs(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    const view = WebView{ .webview = data };
    if (builtin.os.tag == .windows) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const args = bridge.jsonArray(a, req) orelse return view.ret(seq, 0, "{\"ok\":false}");
        if (args.len < 2) return view.ret(seq, 0, "{\"ok\":false}");
        const name = decodeArg(a, args[0]) orelse return view.ret(seq, 0, "{\"ok\":false}");
        const content = decodeArg(a, args[1]) orelse return view.ret(seq, 0, "{\"ok\":false}");
        const path = (dialogs.saveDialog(a, name) catch null) orelse return view.ret(seq, 0, "{\"ok\":false}");
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = content }) catch return view.ret(seq, 0, "{\"ok\":false}");
        const pb = bridge.encodeB64(a, path) catch "";
        const nb = bridge.encodeB64(a, std.fs.path.basename(path)) catch "";
        const json = std.fmt.allocPrintZ(a, "{{\"ok\":true,\"path\":\"{s}\",\"name\":\"{s}\"}}", .{ pb, nb }) catch return view.ret(seq, 0, "{\"ok\":false}");
        view.ret(seq, 0, json);
    } else {
        view.ret(seq, 0, "{\"ok\":false}");
    }
}

fn decodeArg(a: std.mem.Allocator, v: std.json.Value) ?[]u8 {
    return switch (v) {
        .string => |s| bridge.decodeB64(a, s) catch null,
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
    _ = @import("assemble.zig");
    _ = emulator;
    _ = bridge;
    _ = @import("platform.zig");
    _ = @import("loader.zig");
}
