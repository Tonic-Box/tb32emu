const std = @import("std");
const tb32 = @import("tb32");
const emulator = @import("emulator.zig");
const assemble_mod = @import("assemble.zig");

const Emulator = emulator.Emulator;

/// Assembles the source in `args[0]` and returns `{"ok":true,"bytes":N}` or a
/// `{"ok":false,"line":N,"message":"..."}` diagnostic.
pub fn assemble(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    _ = emu;
    const src = firstStringArg(a, args_json) orelse return "\"bad request\"";
    const out = a.alloc(u8, 256) catch return "\"bad request\"";
    return assemble_mod.assembleToJson(a, src, out);
}

/// Assembles and loads the program described by the config object in `args[0]`
/// (`src`, optional `args`, `env`, `seed`) and returns `{"ok":true}` or a diagnostic.
pub fn run(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    const arr = jsonArray(a, args_json) orelse return "\"bad request\"";
    const obj = if (arr.len >= 1) switch (arr[0]) {
        .object => |o| o,
        else => null,
    } else null;
    if (obj == null) return "\"bad request\"";
    const src = strField(obj.?, "src") orelse return "\"bad request\"";

    var arglist = std.ArrayList([]const u8).init(a);
    if (obj.?.get("args")) |av| switch (av) {
        .array => |list| for (list.items) |it| switch (it) {
            .string => |s| arglist.append(s) catch {},
            else => {},
        },
        else => {},
    };
    var keys = std.ArrayList([]const u8).init(a);
    var vals = std.ArrayList([]const u8).init(a);
    if (obj.?.get("env")) |ev| switch (ev) {
        .array => |list| for (list.items) |pair| switch (pair) {
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
    var diag: tb32.Diagnostic = .{};
    emu.start(src, cfg, &diag) catch {
        return std.fmt.allocPrintZ(a, "{{\"ok\":false,\"line\":{d},\"message\":\"{s}\"}}", .{ diag.line, diag.message }) catch "{\"ok\":false,\"line\":0,\"message\":\"error\"}";
    };
    return "{\"ok\":true}";
}

/// Feeds any base64 stdin in `args[0]`, runs up to `args[1]` instructions, and returns the
/// output, raw-mode flag, and stop reason.
pub fn tick(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    var max: u32 = 200_000;
    if (jsonArray(a, args_json)) |arr| {
        if (arr.len >= 1 and arr[0] == .string) {
            if (decodeB64(a, arr[0].string)) |bytes| {
                emu.feedInput(bytes) catch {};
            } else |_| {}
        }
        if (arr.len >= 2) {
            if (jsonU32(arr[1])) |m| max = m;
        }
    }
    return statusJson(a, emu, emu.tick(max));
}

/// Advances one whole source line and returns the same shape as `tick`.
pub fn stepLine(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    _ = args_json;
    return statusJson(a, emu, emu.stepLine());
}

/// Sets or clears a breakpoint at address `args[0]` per the boolean `args[1]`.
pub fn setBreak(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    if (jsonArray(a, args_json)) |arr| {
        if (arr.len >= 2) {
            const on = switch (arr[1]) {
                .bool => |b| b,
                else => true,
            };
            if (jsonU32(arr[0])) |addr| emu.setBreak(addr, on);
        }
    }
    return "{\"ok\":true}";
}

/// Returns pc, brk, flags, registers, and a short stack window.
pub fn snapshot(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    _ = args_json;
    return buildSnapshot(a, emu) catch "{}";
}

/// Returns the address-to-source-line map as `[{"a":addr,"l":line},...]`.
pub fn lines(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    _ = args_json;
    var buf = std.ArrayList(u8).init(a);
    const w = buf.writer();
    w.writeAll("[") catch return "[]";
    for (emu.line_map.items, 0..) |e, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"a\":{d},\"l\":{d}}}", .{ e.addr, e.line }) catch {};
    }
    w.writeAll("]") catch return "[]";
    buf.append(0) catch return "[]";
    return buf.items[0 .. buf.items.len - 1 :0];
}

/// Updates the reported terminal dimensions to `args[0]` cols by `args[1]` rows.
pub fn setTermSize(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    if (jsonArray(a, args_json)) |arr| {
        if (arr.len >= 2) {
            if (jsonU32(arr[0])) |c| emu.term_cols = c;
            if (jsonU32(arr[1])) |r| emu.term_rows = r;
        }
    }
    return "{\"ok\":true}";
}

/// Halts the running program.
pub fn stop(a: std.mem.Allocator, emu: *Emulator, args_json: []const u8) [:0]const u8 {
    _ = a;
    _ = args_json;
    emu.started = false;
    return "{\"ok\":true}";
}

fn statusJson(a: std.mem.Allocator, emu: *Emulator, status: emulator.Status) [:0]const u8 {
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
    return std.fmt.allocPrintZ(a, "{{\"out\":\"{s}\",\"raw\":{},\"state\":\"{s}}}", .{ out_b64, emu.isRaw(), tail }) catch "{\"state\":\"error\"}";
}

fn rd32(ram: []const u8, addr: u32) u32 {
    return @as(u32, ram[addr]) | (@as(u32, ram[addr + 1]) << 8) | (@as(u32, ram[addr + 2]) << 16) | (@as(u32, ram[addr + 3]) << 24);
}

fn buildSnapshot(a: std.mem.Allocator, emu: *Emulator) ![:0]const u8 {
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

fn strField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn firstStringArg(a: std.mem.Allocator, req: []const u8) ?[]const u8 {
    const arr = jsonArray(a, req) orelse return null;
    if (arr.len < 1) return null;
    return switch (arr[0]) {
        .string => |s| s,
        else => null,
    };
}

pub fn jsonArray(a: std.mem.Allocator, req: []const u8) ?[]std.json.Value {
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

pub fn encodeB64(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const dst = try a.alloc(u8, enc.calcSize(src.len));
    return enc.encode(dst, src);
}

pub fn decodeB64(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(s);
    const dst = try a.alloc(u8, n);
    try dec.decode(dst, s);
    return dst;
}
