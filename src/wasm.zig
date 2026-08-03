const std = @import("std");
const emulator = @import("emulator.zig");
const bridge = @import("bridge.zig");

var emu: emulator.Emulator = undefined;
var result: std.ArrayList(u8) = undefined;
var ready = false;

/// Allocates the machine and result buffer once, before any other export is called.
export fn emuInit() void {
    if (ready) return;
    emu = emulator.Emulator.init(std.heap.page_allocator) catch return;
    result = std.ArrayList(u8).init(std.heap.page_allocator);
    ready = true;
}

/// Reserves `len` bytes of linear memory for the host to write call inputs into.
export fn wasmAlloc(len: usize) [*]u8 {
    const buf = std.heap.page_allocator.alloc(u8, len) catch @panic("oom");
    return buf.ptr;
}

/// Releases a block previously returned by `wasmAlloc`.
export fn wasmFree(ptr: [*]u8, len: usize) void {
    std.heap.page_allocator.free(ptr[0..len]);
}

/// Runs the named bridge function over the JSON argument array and returns a pointer to a
/// length-prefixed (`[u32 len][bytes]`, little-endian) UTF-8 JSON result in linear memory.
export fn emuCall(name_ptr: [*]const u8, name_len: usize, args_ptr: [*]const u8, args_len: usize) [*]const u8 {
    const name = name_ptr[0..name_len];
    const args = args_ptr[0..args_len];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return pack(dispatch(arena.allocator(), name, args));
}

fn dispatch(a: std.mem.Allocator, name: []const u8, args: []const u8) [:0]const u8 {
    const table = .{
        .{ "assemble", bridge.assemble },
        .{ "run", bridge.run },
        .{ "emuTick", bridge.tick },
        .{ "dbgStep", bridge.stepLine },
        .{ "dbgBreak", bridge.setBreak },
        .{ "dbgSnapshot", bridge.snapshot },
        .{ "dbgLines", bridge.lines },
        .{ "setTermSize", bridge.setTermSize },
        .{ "emuStop", bridge.stop },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1](a, &emu, args);
    }
    return "{\"error\":\"unknown call\"}";
}

fn pack(out: []const u8) [*]const u8 {
    result.clearRetainingCapacity();
    const len: u32 = @intCast(out.len);
    result.appendSlice(&std.mem.toBytes(len)) catch {};
    result.appendSlice(out) catch {};
    return result.items.ptr;
}
