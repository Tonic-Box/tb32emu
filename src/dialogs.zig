const std = @import("std");
const windows = std.os.windows;
const WINAPI = windows.WINAPI;

const OFN_NOCHANGEDIR = 0x8;
const OFN_OVERWRITEPROMPT = 0x2;
const OFN_HIDEREADONLY = 0x4;
const OFN_PATHMUSTEXIST = 0x800;
const OFN_FILEMUSTEXIST = 0x1000;
const OFN_EXPLORER = 0x80000;

const OPENFILENAMEW = extern struct {
    lStructSize: u32,
    hwndOwner: ?*anyopaque,
    hInstance: ?*anyopaque,
    lpstrFilter: ?[*:0]const u16,
    lpstrCustomFilter: ?[*:0]u16,
    nMaxCustFilter: u32,
    nFilterIndex: u32,
    lpstrFile: ?[*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*:0]u16,
    nMaxFileTitle: u32,
    lpstrInitialDir: ?[*:0]const u16,
    lpstrTitle: ?[*:0]const u16,
    Flags: u32,
    nFileOffset: u16,
    nFileExtension: u16,
    lpstrDefExt: ?[*:0]const u16,
    lCustData: usize,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?[*:0]const u16,
    pvReserved: ?*anyopaque,
    dwReserved: u32,
    FlagsEx: u32,
};

extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(WINAPI) c_int;
extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(WINAPI) c_int;

const filter = std.unicode.utf8ToUtf16LeStringLiteral("TB32 assembly (*.s)\x00*.s\x00All files (*.*)\x00*.*\x00");
const def_ext = std.unicode.utf8ToUtf16LeStringLiteral("s");

fn readPath(gpa: std.mem.Allocator, buf: []const u16) ![]u8 {
    const len = std.mem.indexOfScalar(u16, buf, 0) orelse buf.len;
    return std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..len]);
}

/// Shows the native open dialog and returns the chosen path (owned by `gpa`), or null
/// if the user cancelled.
pub fn openDialog(gpa: std.mem.Allocator) !?[]u8 {
    var file_buf = std.mem.zeroes([1024]u16);
    var ofn = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = &file_buf;
    ofn.nMaxFile = file_buf.len;
    ofn.lpstrDefExt = def_ext;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_EXPLORER | OFN_NOCHANGEDIR;
    if (GetOpenFileNameW(&ofn) == 0) return null;
    return try readPath(gpa, &file_buf);
}

/// Shows the native save dialog (prefilled with `suggested`) and returns the chosen path
/// (owned by `gpa`), or null if the user cancelled.
pub fn saveDialog(gpa: std.mem.Allocator, suggested: []const u8) !?[]u8 {
    var file_buf = std.mem.zeroes([1024]u16);
    const w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, suggested);
    defer gpa.free(w);
    const n = @min(w.len, file_buf.len - 1);
    @memcpy(file_buf[0..n], w[0..n]);

    var ofn = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.lpstrFilter = filter;
    ofn.lpstrFile = &file_buf;
    ofn.nMaxFile = file_buf.len;
    ofn.lpstrDefExt = def_ext;
    ofn.Flags = OFN_OVERWRITEPROMPT | OFN_HIDEREADONLY | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR;
    if (GetSaveFileNameW(&ofn) == 0) return null;
    return try readPath(gpa, &file_buf);
}
