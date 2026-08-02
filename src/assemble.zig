const std = @import("std");
const tb32 = @import("tb32");

const internal_error = "{\"ok\":false,\"line\":0,\"message\":\"internal error\"}";

/// Assembles `src` and writes a JSON result into `out`, returning the used slice.
/// Success is `{"ok":true,"bytes":N}`; failure is `{"ok":false,"line":N,"message":"..."}`.
pub fn assembleToJson(gpa: std.mem.Allocator, src: []const u8, out: []u8) [:0]const u8 {
    var diag: tb32.Diagnostic = .{};
    const tbx = tb32.assembleDiag(gpa, src, &diag) catch {
        return std.fmt.bufPrintZ(out, "{{\"ok\":false,\"line\":{d},\"message\":\"{s}\"}}", .{ diag.line, diag.message }) catch internal_error;
    };
    defer gpa.free(tbx);
    return std.fmt.bufPrintZ(out, "{{\"ok\":true,\"bytes\":{d}}}", .{tbx.len}) catch internal_error;
}

test "json for a valid program" {
    var out: [128]u8 = undefined;
    const r = assembleToJson(std.testing.allocator, ".text\nhlt\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":true") != null);
}

test "json for a bad program carries the line" {
    var out: [128]u8 = undefined;
    const r = assembleToJson(std.testing.allocator, ".text\nbogus r1\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"line\":2") != null);
}
