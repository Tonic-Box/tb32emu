const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

const native = struct {
    fn unixSeconds() i64 {
        return std.time.timestamp();
    }
    fn nowMs() i64 {
        return std.time.milliTimestamp();
    }
    fn fillRandom(buf: []u8) void {
        std.crypto.random.bytes(buf);
    }
};

const wasm = struct {
    extern "env" fn host_unix_seconds() i64;
    extern "env" fn host_now_ms() i64;
    extern "env" fn host_random(ptr: [*]u8, len: usize) void;

    fn unixSeconds() i64 {
        return host_unix_seconds();
    }
    fn nowMs() i64 {
        return host_now_ms();
    }
    fn fillRandom(buf: []u8) void {
        host_random(buf.ptr, buf.len);
    }
};

const impl = if (is_wasm) wasm else native;

/// Wall-clock time in whole seconds since the Unix epoch.
pub fn unixSeconds() i64 {
    return impl.unixSeconds();
}

/// A monotonic-enough millisecond counter for measuring elapsed time.
pub fn nowMs() i64 {
    return impl.nowMs();
}

/// Fills `buf` with unpredictable bytes from the host.
pub fn fillRandom(buf: []u8) void {
    impl.fillRandom(buf);
}
