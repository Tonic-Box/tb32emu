const std = @import("std");
const tb32 = @import("tb32");
const loader = @import("loader.zig");

const MEM_SIZE: u32 = 16 * 1024 * 1024;
const STACK_RESERVE: u32 = 64 * 1024;

const SYS_read = 0;
const SYS_write = 1;
const SYS_exit = 11;
const SYS_set_raw = 26;
const SYS_time = 27;
const SYS_getrandom = 28;
const SYS_msleep = 73;
const SYS_sleep = 76;
const SYS_read_nb = 78;
const SYS_ioctl = 72;
const SYS_clock_gettime = 80;
const SYS_gettimeofday = 81;
const SYS_nanosleep = 82;
const SYS_brk = 83;
const SYS_sbrk = 84;

const TIOCGWINSZ = 0x5413;
const ENOSYS: u32 = @bitCast(@as(i32, -38));
const EBADF: u32 = @bitCast(@as(i32, -9));
const NEG1: u32 = @bitCast(@as(i32, -1));

const TERM_COLS: u16 = 80;
const TERM_ROWS: u16 = 24;

/// Why a `tick` returned control to the caller.
pub const Status = union(enum) {
    running,
    halted,
    exited: i32,
    waiting_input,
    sleep_ms: u32,
    fault: struct { code: u32, pc: u32 },
};

const SysAction = union(enum) { cont, exit: i32, waiting, sleep: u32 };

/// A single TB32 program running against an in-memory bus and a clean-room host for the
/// public syscall ABI. Driven in bounded bursts by `tick`.
pub const Emulator = struct {
    gpa: std.mem.Allocator,
    ram: []u8,
    bus: tb32.FlatBus,
    cpu: tb32.Cpu,
    brk: u32,
    raw: bool,
    started: bool,
    stdin: std.ArrayList(u8),
    stdin_pos: usize,
    out: std.ArrayList(u8),
    start_ms: i64,

    pub fn init(gpa: std.mem.Allocator) !Emulator {
        const ram = try gpa.alloc(u8, MEM_SIZE);
        return .{
            .gpa = gpa,
            .ram = ram,
            .bus = .{ .ram = ram },
            .cpu = .{},
            .brk = 0,
            .raw = false,
            .started = false,
            .stdin = std.ArrayList(u8).init(gpa),
            .stdin_pos = 0,
            .out = std.ArrayList(u8).init(gpa),
            .start_ms = 0,
        };
    }

    /// Assembles `src`, loads it, and resets the machine ready to run. On assembly
    /// failure `diag` is filled and the error is returned.
    pub fn start(self: *Emulator, src: []const u8, diag: *tb32.Diagnostic) tb32.assembler.Error!void {
        const tbx = try tb32.assembleDiag(self.gpa, src, diag);
        defer self.gpa.free(tbx);
        @memset(self.ram, 0);
        const info = loader.load(self.ram, tbx) catch {
            diag.* = .{ .line = 0, .message = "image does not fit in memory" };
            return error.CannotEvaluate;
        };
        self.cpu = .{};
        self.cpu.pc = info.entry;
        self.cpu.r[13] = MEM_SIZE;
        self.brk = info.brk;
        self.raw = false;
        self.started = true;
        self.stdin.clearRetainingCapacity();
        self.stdin_pos = 0;
        self.out.clearRetainingCapacity();
        self.start_ms = std.time.milliTimestamp();
    }

    pub fn deinit(self: *Emulator) void {
        self.gpa.free(self.ram);
        self.stdin.deinit();
        self.out.deinit();
    }

    pub fn feedInput(self: *Emulator, bytes: []const u8) !void {
        try self.stdin.appendSlice(bytes);
    }

    pub fn takeOutput(self: *Emulator) []const u8 {
        return self.out.items;
    }

    pub fn clearOutput(self: *Emulator) void {
        self.out.clearRetainingCapacity();
    }

    pub fn isRaw(self: *Emulator) bool {
        return self.raw;
    }

    /// Executes up to `max_steps` instructions, stopping early on halt, exit, a blocking
    /// read with no input, a sleep request, or a fault.
    pub fn tick(self: *Emulator, max_steps: u32) Status {
        if (!self.started) return .{ .exited = 0 };
        var i: u32 = 0;
        while (i < max_steps) : (i += 1) {
            switch (tb32.step(&self.cpu, &self.bus)) {
                .ok, .breakpoint => {},
                .halt => return .halted,
                .fault => return .{ .fault = .{ .code = self.cpu.trap, .pc = self.cpu.insn_pc } },
                .syscall => switch (self.service()) {
                    .cont => {},
                    .exit => |code| return .{ .exited = code },
                    .waiting => {
                        self.cpu.pc = self.cpu.insn_pc;
                        return .waiting_input;
                    },
                    .sleep => |ms| return .{ .sleep_ms = ms },
                },
            }
        }
        return .running;
    }

    fn setR1(self: *Emulator, v: u32) void {
        self.cpu.r[1] = v;
    }

    fn inBounds(self: *Emulator, addr: u32, len: u32) bool {
        return @as(u64, addr) + len <= self.ram.len;
    }

    fn putU32(self: *Emulator, addr: u32, v: u32) void {
        if (!self.inBounds(addr, 4)) return;
        self.ram[addr] = @truncate(v);
        self.ram[addr + 1] = @truncate(v >> 8);
        self.ram[addr + 2] = @truncate(v >> 16);
        self.ram[addr + 3] = @truncate(v >> 24);
    }

    fn service(self: *Emulator) SysAction {
        const r = &self.cpu.r;
        const num = r[7];
        const a1 = r[1];
        const a2 = r[2];
        const a3 = r[3];
        switch (num) {
            SYS_write => {
                const n = a3;
                if ((a1 == 1 or a1 == 2) and self.inBounds(a2, n)) {
                    self.out.appendSlice(self.ram[a2 .. a2 + n]) catch {};
                    self.setR1(n);
                } else {
                    self.setR1(EBADF);
                }
                return .cont;
            },
            SYS_read => {
                const avail = self.stdin.items.len - self.stdin_pos;
                if (avail == 0) return .waiting;
                self.setR1(self.drainStdin(a2, a3));
                return .cont;
            },
            SYS_read_nb => {
                self.setR1(self.drainStdin(a2, a3));
                return .cont;
            },
            SYS_exit => return .{ .exit = @bitCast(a1) },
            SYS_set_raw => {
                self.raw = a1 != 0;
                self.setR1(0);
                return .cont;
            },
            SYS_ioctl => {
                if (a2 == TIOCGWINSZ) {
                    self.putU32(a3, (@as(u32, TERM_COLS) << 16) | TERM_ROWS);
                    self.setR1(0);
                } else {
                    self.setR1(EBADF);
                }
                return .cont;
            },
            SYS_time => {
                self.setR1(@truncate(@as(u64, @bitCast(std.time.timestamp()))));
                return .cont;
            },
            SYS_clock_gettime => {
                if (a1 == 1) {
                    const ms: u64 = @intCast(std.time.milliTimestamp() - self.start_ms);
                    self.putU32(a2, @truncate(ms / 1000));
                    self.putU32(a2 + 4, @truncate((ms % 1000) * 1_000_000));
                } else {
                    self.putU32(a2, @truncate(@as(u64, @bitCast(std.time.timestamp()))));
                    self.putU32(a2 + 4, 0);
                }
                self.setR1(0);
                return .cont;
            },
            SYS_gettimeofday => {
                self.putU32(a1, @truncate(@as(u64, @bitCast(std.time.timestamp()))));
                self.putU32(a1 + 4, 0);
                self.setR1(0);
                return .cont;
            },
            SYS_msleep => {
                self.setR1(0);
                return .{ .sleep = a1 };
            },
            SYS_sleep => {
                self.setR1(0);
                return .{ .sleep = a1 *% 1000 };
            },
            SYS_nanosleep => {
                var ms: u32 = 0;
                if (self.inBounds(a1, 8)) {
                    const sec = self.getU32(a1);
                    const nsec = self.getU32(a1 + 4);
                    ms = sec *% 1000 +% nsec / 1_000_000;
                }
                self.setR1(0);
                return .{ .sleep = ms };
            },
            SYS_getrandom => {
                if (self.inBounds(a1, a2)) {
                    std.crypto.random.bytes(self.ram[a1 .. a1 + a2]);
                    self.setR1(a2);
                } else {
                    self.setR1(NEG1);
                }
                return .cont;
            },
            SYS_brk => {
                if (a1 == 0) {
                    self.setR1(self.brk);
                } else if (a1 <= MEM_SIZE - STACK_RESERVE) {
                    self.brk = a1;
                    self.setR1(0);
                } else {
                    self.setR1(NEG1);
                }
                return .cont;
            },
            SYS_sbrk => {
                const old = self.brk;
                const new = old +% a1;
                if (new <= MEM_SIZE - STACK_RESERVE) {
                    self.brk = new;
                    self.setR1(old);
                } else {
                    self.setR1(NEG1);
                }
                return .cont;
            },
            else => {
                self.setR1(ENOSYS);
                return .cont;
            },
        }
    }

    fn getU32(self: *Emulator, addr: u32) u32 {
        if (!self.inBounds(addr, 4)) return 0;
        return @as(u32, self.ram[addr]) | (@as(u32, self.ram[addr + 1]) << 8) | (@as(u32, self.ram[addr + 2]) << 16) | (@as(u32, self.ram[addr + 3]) << 24);
    }

    fn drainStdin(self: *Emulator, buf: u32, cap: u32) u32 {
        const avail = self.stdin.items.len - self.stdin_pos;
        var n: u32 = @intCast(@min(avail, cap));
        if (!self.inBounds(buf, n)) n = 0;
        if (n > 0) {
            @memcpy(self.ram[buf .. buf + n], self.stdin.items[self.stdin_pos .. self.stdin_pos + n]);
            self.stdin_pos += n;
            if (self.stdin_pos == self.stdin.items.len) {
                self.stdin.clearRetainingCapacity();
                self.stdin_pos = 0;
            }
        }
        return n;
    }
};

test "runs a write and exit program" {
    const a = std.testing.allocator;
    var emu = try Emulator.init(a);
    defer emu.deinit();
    var diag: tb32.Diagnostic = .{};
    const src =
        \\.text
        \\.entry _start
        \\_start:
        \\    li r7, 1
        \\    li r1, 1
        \\    li r2, msg
        \\    li r3, 3
        \\    sys
        \\    li r7, 11
        \\    li r1, 0
        \\    sys
        \\.rodata
        \\msg: .asciz "hi\n"
    ;
    try emu.start(src, &diag);
    const st = emu.tick(100000);
    try std.testing.expect(st == .exited);
    try std.testing.expectEqualStrings("hi\n", emu.takeOutput());
}

test "getrandom is reproducible under no seed only across calls" {
    const a = std.testing.allocator;
    var emu = try Emulator.init(a);
    defer emu.deinit();
    var diag: tb32.Diagnostic = .{};
    const src =
        \\.text
        \\.entry _start
        \\_start:
        \\    li r7, 28
        \\    li r1, 0x2000
        \\    li r2, 8
        \\    sys
        \\    hlt
    ;
    try emu.start(src, &diag);
    const st = emu.tick(100000);
    try std.testing.expect(st == .halted);
}
