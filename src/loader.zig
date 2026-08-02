const std = @import("std");

pub const Error = error{BadImage};

/// The entry point and initial program break of a loaded image.
pub const Loaded = struct { entry: u32, brk: u32 };

fn u16le(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}
fn u32le(b: []const u8, off: usize) u32 {
    return @as(u32, b[off]) | (@as(u32, b[off + 1]) << 8) | (@as(u32, b[off + 2]) << 16) | (@as(u32, b[off + 3]) << 24);
}

/// Copies a TBX object's loadable sections into `ram` at their virtual addresses and
/// returns the entry point and program break. `ram` must already be zeroed so that
/// NOBITS (.bss) regions read as zero. Sections are loaded at their link addresses,
/// so relocations are not applied.
pub fn load(ram: []u8, tbx: []const u8) Error!Loaded {
    if (tbx.len < 32 or !std.mem.eql(u8, tbx[0..4], "TBX\x7f")) return error.BadImage;
    const entry = u32le(tbx, 8);
    const sh_off = u32le(tbx, 16);
    const n_sh = u16le(tbx, 20);
    const entsize = u16le(tbx, 22);

    var end: u32 = 0;
    var i: usize = 0;
    while (i < n_sh) : (i += 1) {
        const h = sh_off + i * entsize;
        if (h + 20 > tbx.len) return error.BadImage;
        const typ = u16le(tbx, h + 4);
        const vaddr = u32le(tbx, h + 8);
        const off = u32le(tbx, h + 12);
        const size = u32le(tbx, h + 16);
        if (typ == 1) {
            if (off + size > tbx.len or vaddr + size > ram.len) return error.BadImage;
            @memcpy(ram[vaddr .. vaddr + size], tbx[off .. off + size]);
            if (vaddr + size > end) end = vaddr + size;
        } else if (typ == 2) {
            if (vaddr + size > ram.len) return error.BadImage;
            if (vaddr + size > end) end = vaddr + size;
        }
    }
    return .{ .entry = entry, .brk = (end + 15) & ~@as(u32, 15) };
}
