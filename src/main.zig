const std = @import("std");
const tb32 = @import("tb32");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const src = ".text\n_start:\nli r1, 5\nli r2, 37\nadd r3, r1, r2\nhlt\n";
    const tbx = try tb32.assemble(a, src);
    defer a.free(tbx);

    var buf: [64]u8 = undefined;
    const word = tb32.isa.encR(tb32.isa.ADD, 3, 1, 2);

    const out = std.io.getStdOut().writer();
    try out.print("tb32emu linked against libtb32 v0.1.0\n", .{});
    try out.print("assembled {d} bytes of TBX\n", .{tbx.len});
    try out.print("disasm sample: {s}\n", .{tb32.disasm(word, tb32.isa.TEXT_BASE, &buf)});
}

test "libtb32 dependency links and assembles" {
    const a = std.testing.allocator;
    const tbx = try tb32.assemble(a, ".text\nhlt\n");
    defer a.free(tbx);
    try std.testing.expectEqualSlices(u8, "TBX\x7f", tbx[0..4]);
}
