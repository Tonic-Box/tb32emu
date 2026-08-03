const std = @import("std");
const builtin = @import("builtin");
const WebView = @import("webview").WebView;
const server = @import("server.zig");
const assemble = @import("assemble.zig");
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

    const args = jsonArray(a, req) orelse {
        view.ret(seq, 1, "\"bad request\"");
        return;
    };
    const obj = if (args.len >= 1) switch (args[0]) {
        .object => |o| o,
        else => null,
    } else null;
    if (obj == null) {
        view.ret(seq, 1, "\"bad request\"");
        return;
    }
    const src = strField(obj.?, "src") orelse {
        view.ret(seq, 1, "\"bad request\"");
        return;
    };

    var arglist = std.ArrayList([]const u8).init(a);
    if (obj.?.get("args")) |av| switch (av) {
        .array => |arr| for (arr.items) |it| switch (it) {
            .string => |s| arglist.append(s) catch {},
            else => {},
        },
        else => {},
    };
    var keys = std.ArrayList([]const u8).init(a);
    var vals = std.ArrayList([]const u8).init(a);
    if (obj.?.get("env")) |ev| switch (ev) {
        .array => |arr| for (arr.items) |pair| switch (pair) {
            .array => |p| if (p.items.len >= 2) {
                const k = switch (p.items[0]) {
                    .string => |s| s,
                    else => continue,
                };
                const v = switch (p.items[1]) {
                    .string => |s| s,
                    else => continue,
                };
                keys.append(k) catch {};
                vals.append(v) catch {};
            },
            else => {},
        },
        else => {},
    };
    var seed: ?u64 = null;
    if (obj.?.get("seed")) |sv| switch (sv) {
        .integer => |n| if (n >= 0) {
            seed = @intCast(n);
        },
        .float => |f| if (f >= 0) {
            seed = @intFromFloat(f);
        },
        else => {},
    };

    const cfg = emulator.RunConfig{
        .args = arglist.items,
        .env_keys = keys.items,
        .env_vals = vals.items,
        .seed = seed,
    };
    var diag: @import("tb32").Diagnostic = .{};
    emu.start(src, cfg, &diag) catch {
        var buf: [256]u8 = undefined;
        const j = std.fmt.bufPrintZ(&buf, "{{\"ok\":false,\"line\":{d},\"message\":\"{s}\"}}", .{ diag.line, diag.message }) catch "{\"ok\":false,\"line\":0,\"message\":\"error\"}";
        view.ret(seq, 0, j);
        return;
    };
    view.ret(seq, 0, "{\"ok\":true}");
}

fn strField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
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

    replyStatus(view, seq, a, emu.tick(max));
}

fn replyStatus(view: WebView, seq: [:0]const u8, a: std.mem.Allocator, status: emulator.Status) void {
    const out_b64 = encodeB64(a, emu.takeOutput()) catch "";
    emu.clearOutput();
    const tail: []const u8 = switch (status) {
        .running => "running\"",
        .halted => "halted\"",
        .waiting_input => "waiting\"",
        .exited => |c| std.fmt.allocPrint(a, "exited\",\"code\":{d}", .{c}) catch "exited\"",
        .sleep_ms => |ms| std.fmt.allocPrint(a, "sleep\",\"ms\":{d}", .{ms}) catch "sleep\"",
        .breakpoint => |pc| std.fmt.allocPrint(a, "breakpoint\",\"pc\":{d}", .{pc}) catch "breakpoint\"",
        .fault => |f| std.fmt.allocPrint(a, "fault\",\"code\":{d},\"pc\":{d}", .{ f.code, f.pc }) catch "fault\"",
    };
    const json = std.fmt.allocPrintZ(a, "{{\"out\":\"{s}\",\"raw\":{},\"state\":\"{s}}}", .{ out_b64, emu.isRaw(), tail }) catch {
        view.ret(seq, 0, "{\"state\":\"error\"}");
        return;
    };
    view.ret(seq, 0, json);
}

fn onDbgStep(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    _ = req;
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    replyStatus(view, seq, arena.allocator(), emu.stepLine());
}

fn onDbgBreak(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (jsonArray(arena.allocator(), req)) |args| {
        if (args.len >= 2) {
            const on = switch (args[1]) {
                .bool => |b| b,
                else => true,
            };
            if (jsonU32(args[0])) |addr| emu.setBreak(addr, on);
        }
    }
    view.ret(seq, 0, "{\"ok\":true}");
}

fn onDbgSnapshot(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    _ = req;
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const json = buildSnapshot(arena.allocator()) catch {
        view.ret(seq, 0, "{}");
        return;
    };
    view.ret(seq, 0, json);
}

fn rd32(ram: []const u8, addr: u32) u32 {
    return @as(u32, ram[addr]) | (@as(u32, ram[addr + 1]) << 8) | (@as(u32, ram[addr + 2]) << 16) | (@as(u32, ram[addr + 3]) << 24);
}

fn buildSnapshot(a: std.mem.Allocator) ![:0]const u8 {
    var buf = std.ArrayList(u8).init(a);
    const w = buf.writer();
    try w.print("{{\"pc\":{d},\"brk\":{d},\"flags\":{{\"z\":{},\"n\":{},\"c\":{},\"v\":{}}},\"regs\":[", .{
        emu.cpu.pc, emu.brk, emu.cpu.f.z, emu.cpu.f.n, emu.cpu.f.c, emu.cpu.f.v,
    });
    for (emu.cpu.r, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{d}", .{v});
    }
    try w.writeAll("],\"stack\":[");
    const sp = emu.cpu.r[13];
    var first = true;
    var k: u32 = 0;
    while (k < 8) : (k += 1) {
        const addr = sp +% k *% 4;
        if (@as(u64, addr) + 4 > emu.ram.len) break;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"a\":{d},\"v\":{d}}}", .{ addr, rd32(emu.ram, addr) });
    }
    try w.writeAll("]}");
    try buf.append(0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn onDbgLines(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    _ = req;
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf = std.ArrayList(u8).init(a);
    const w = buf.writer();
    w.writeAll("[") catch return view.ret(seq, 0, "[]");
    for (emu.line_map.items, 0..) |e, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"a\":{d},\"l\":{d}}}", .{ e.addr, e.line }) catch {};
    }
    w.writeAll("]") catch {};
    buf.append(0) catch return view.ret(seq, 0, "[]");
    view.ret(seq, 0, buf.items[0 .. buf.items.len - 1 :0]);
}

fn onStop(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    _ = req;
    emu.started = false;
    const view = WebView{ .webview = data };
    view.ret(seq, 0, "{\"ok\":true}");
}

fn onSetTermSize(seq: [:0]const u8, req: [:0]const u8, data: ?*anyopaque) void {
    const view = WebView{ .webview = data };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (jsonArray(arena.allocator(), req)) |args| {
        if (args.len >= 2) {
            if (jsonU32(args[0])) |c| emu.term_cols = c;
            if (jsonU32(args[1])) |r| emu.term_rows = r;
        }
    }
    view.ret(seq, 0, "{\"ok\":true}");
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
        const pb = encodeB64(a, path) catch "";
        const nb = encodeB64(a, std.fs.path.basename(path)) catch "";
        const cb = encodeB64(a, content) catch "";
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
    const args = jsonArray(a, req) orelse return view.ret(seq, 0, "{\"ok\":false}");
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
        const args = jsonArray(a, req) orelse return view.ret(seq, 0, "{\"ok\":false}");
        if (args.len < 2) return view.ret(seq, 0, "{\"ok\":false}");
        const name = decodeArg(a, args[0]) orelse return view.ret(seq, 0, "{\"ok\":false}");
        const content = decodeArg(a, args[1]) orelse return view.ret(seq, 0, "{\"ok\":false}");
        const path = (dialogs.saveDialog(a, name) catch null) orelse return view.ret(seq, 0, "{\"ok\":false}");
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = content }) catch return view.ret(seq, 0, "{\"ok\":false}");
        const pb = encodeB64(a, path) catch "";
        const nb = encodeB64(a, std.fs.path.basename(path)) catch "";
        const json = std.fmt.allocPrintZ(a, "{{\"ok\":true,\"path\":\"{s}\",\"name\":\"{s}\"}}", .{ pb, nb }) catch return view.ret(seq, 0, "{\"ok\":false}");
        view.ret(seq, 0, json);
    } else {
        view.ret(seq, 0, "{\"ok\":false}");
    }
}

fn decodeArg(a: std.mem.Allocator, v: std.json.Value) ?[]u8 {
    return switch (v) {
        .string => |s| decodeB64(a, s) catch null,
        else => null,
    };
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
