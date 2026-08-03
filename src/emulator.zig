const std = @import("std");
const tb32 = @import("tb32");
const loader = @import("loader.zig");
const platform = @import("platform.zig");

const MEM_SIZE: u32 = 16 * 1024 * 1024;
const STACK_RESERVE: u32 = 64 * 1024;

const SYS_read = 0;
const SYS_write = 1;
const SYS_exit = 11;
const SYS_set_raw = 26;
const SYS_time = 27;
const SYS_getrandom = 28;
const SYS_getenv = 41;
const SYS_setenv = 42;
const SYS_unsetenv = 43;
const SYS_getenviron = 44;
const SYS_msleep = 73;
const SYS_sleep = 76;
const SYS_read_nb = 78;
const SYS_ioctl = 72;
const SYS_clock_gettime = 80;
const SYS_gettimeofday = 81;
const SYS_nanosleep = 82;
const SYS_brk = 83;
const SYS_sbrk = 84;
const SYS_mmap = 100;
const SYS_munmap = 101;
const SYS_mprotect = 102;

const TIOCGWINSZ = 0x5413;
const MAP_ANON = 0x20;
const DEFAULT_COLS = 80;
const DEFAULT_ROWS = 24;
const MMAP_BASE: u32 = 8 * 1024 * 1024;
const MMAP_END: u32 = 12 * 1024 * 1024;
const ENOSYS: u32 = @bitCast(@as(i32, -38));
const EBADF: u32 = @bitCast(@as(i32, -9));
const EINVAL: u32 = @bitCast(@as(i32, -22));
const ENOMEM: u32 = @bitCast(@as(i32, -12));
const NEG1: u32 = @bitCast(@as(i32, -1));

/// Initial process state: argv, environment, and RNG seed.
pub const RunConfig = struct {
    args: []const []const u8 = &.{},
    env_keys: []const []const u8 = &.{},
    env_vals: []const []const u8 = &.{},
    seed: ?u64 = null,
};


/// Why a `tick` returned control to the caller.
pub const Status = union(enum) {
    running,
    halted,
    exited: i32,
    waiting_input,
    sleep_ms: u32,
    breakpoint: u32,
    fault: struct { code: u32, pc: u32 },
};

const SysAction = union(enum) { cont, exit: i32, waiting, sleep: u32 };

fn remaining(total: u32, used: u32) u32 {
    return if (total > used) total - used else 0;
}

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
    breakpoints: std.AutoHashMap(u32, void),
    just_hit_bp: bool,
    env_arena: std.heap.ArenaAllocator,
    env: std.StringHashMap([]const u8),
    prng: std.Random.DefaultPrng,
    use_seed: bool,
    mmap_next: u32,
    line_map: std.ArrayList(tb32.LineEntry),
    term_cols: u32,
    term_rows: u32,

    pub fn init(gpa: std.mem.Allocator) !Emulator {
        const ram = try gpa.alloc(u8, MEM_SIZE);
        var env_arena = std.heap.ArenaAllocator.init(gpa);
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
            .breakpoints = std.AutoHashMap(u32, void).init(gpa),
            .just_hit_bp = false,
            .env_arena = env_arena,
            .env = std.StringHashMap([]const u8).init(env_arena.allocator()),
            .prng = std.Random.DefaultPrng.init(0),
            .use_seed = false,
            .mmap_next = MMAP_BASE,
            .line_map = std.ArrayList(tb32.LineEntry).init(gpa),
            .term_cols = DEFAULT_COLS,
            .term_rows = DEFAULT_ROWS,
        };
    }

    /// Assembles `src`, loads it, and resets the machine ready to run. On assembly
    /// failure `diag` is filled and the error is returned.
    pub fn start(self: *Emulator, src: []const u8, cfg: RunConfig, diag: *tb32.Diagnostic) tb32.assembler.Error!void {
        self.line_map.clearRetainingCapacity();
        self.breakpoints.clearRetainingCapacity();
        const tbx = try tb32.assembleDebug(self.gpa, src, diag, &self.line_map);
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
        self.just_hit_bp = false;
        self.mmap_next = MMAP_BASE;
        self.stdin.clearRetainingCapacity();
        self.stdin_pos = 0;
        self.out.clearRetainingCapacity();
        self.start_ms = platform.nowMs();

        if (cfg.seed) |s| {
            self.prng = std.Random.DefaultPrng.init(s);
            self.use_seed = true;
        } else {
            self.use_seed = false;
        }
        self.setupEnv(cfg);
        self.setupArgs(cfg.args);
    }

    fn setupEnv(self: *Emulator, cfg: RunConfig) void {
        self.env.deinit();
        _ = self.env_arena.reset(.free_all);
        self.env = std.StringHashMap([]const u8).init(self.env_arena.allocator());
        const a = self.env_arena.allocator();
        var i: usize = 0;
        while (i < cfg.env_keys.len and i < cfg.env_vals.len) : (i += 1) {
            const k = a.dupe(u8, cfg.env_keys[i]) catch continue;
            const v = a.dupe(u8, cfg.env_vals[i]) catch continue;
            self.env.put(k, v) catch {};
        }
    }

    fn setupArgs(self: *Emulator, args: []const []const u8) void {
        if (args.len == 0) {
            self.cpu.r[1] = 0;
            self.cpu.r[2] = 0;
            return;
        }
        var total: u32 = 0;
        for (args) |arg| total += @as(u32, @intCast(arg.len)) + 1;
        const ptr_bytes: u32 = @as(u32, @intCast(args.len)) * 4;
        var region: u32 = (total + ptr_bytes + 15) & ~@as(u32, 15);
        if (region > MEM_SIZE / 4) region = MEM_SIZE / 4;
        const base = MEM_SIZE - region;
        var str = base + ptr_bytes;
        for (args, 0..) |arg, i| {
            const n: u32 = @intCast(arg.len);
            if (str + n + 1 > MEM_SIZE) break;
            @memcpy(self.ram[str .. str + n], arg);
            self.ram[str + n] = 0;
            self.putU32(base + @as(u32, @intCast(i)) * 4, str);
            str += n + 1;
        }
        self.cpu.r[1] = @intCast(args.len);
        self.cpu.r[2] = base;
        self.cpu.r[13] = base;
    }

    pub fn deinit(self: *Emulator) void {
        self.gpa.free(self.ram);
        self.stdin.deinit();
        self.out.deinit();
        self.breakpoints.deinit();
        self.env.deinit();
        self.env_arena.deinit();
        self.line_map.deinit();
    }

    pub fn hasBreak(self: *Emulator, addr: u32) bool {
        return self.breakpoints.contains(addr);
    }

    pub fn setBreak(self: *Emulator, addr: u32, on: bool) void {
        if (on) {
            self.breakpoints.put(addr, {}) catch {};
        } else {
            _ = self.breakpoints.remove(addr);
        }
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
            if (!self.just_hit_bp and self.breakpoints.contains(self.cpu.pc)) {
                self.just_hit_bp = true;
                return .{ .breakpoint = self.cpu.pc };
            }
            self.just_hit_bp = false;
            switch (self.oneStep()) {
                .cont => {},
                .stop => |s| return s,
            }
        }
        return .running;
    }

    /// Executes exactly one instruction regardless of breakpoints and returns why it
    /// stopped. `.running` means the instruction retired and the machine is still live.
    pub fn stepOne(self: *Emulator) Status {
        if (!self.started) return .{ .exited = 0 };
        self.just_hit_bp = false;
        return switch (self.oneStep()) {
            .cont => .running,
            .stop => |s| s,
        };
    }

    fn lineOf(self: *Emulator, pc: u32) u32 {
        for (self.line_map.items) |e| {
            if (e.addr == pc) return e.line;
        }
        return 0;
    }

    /// Steps until the current source line changes or the program stops, so one call
    /// advances a whole source line even when it assembles to several instructions.
    pub fn stepLine(self: *Emulator) Status {
        if (!self.started) return .{ .exited = 0 };
        const start_line = self.lineOf(self.cpu.pc);
        var guard: u32 = 0;
        while (guard < 1_000_000) : (guard += 1) {
            const st = self.stepOne();
            switch (st) {
                .running => {},
                else => return st,
            }
            if (self.lineOf(self.cpu.pc) != start_line) return .running;
        }
        return .running;
    }

    const StepOutcome = union(enum) { cont, stop: Status };

    fn oneStep(self: *Emulator) StepOutcome {
        switch (tb32.step(&self.cpu, &self.bus)) {
            .ok, .breakpoint => return .cont,
            .halt => return .{ .stop = .halted },
            .fault => return .{ .stop = .{ .fault = .{ .code = self.cpu.trap, .pc = self.cpu.insn_pc } } },
            .syscall => switch (self.service()) {
                .cont => return .cont,
                .exit => |code| return .{ .stop = .{ .exited = code } },
                .waiting => {
                    self.cpu.pc = self.cpu.insn_pc;
                    return .{ .stop = .waiting_input };
                },
                .sleep => |ms| return .{ .stop = .{ .sleep_ms = ms } },
            },
        }
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
                    self.putU32(a3, (self.term_cols << 16) | self.term_rows);
                    self.setR1(0);
                } else {
                    self.setR1(EBADF);
                }
                return .cont;
            },
            SYS_time => {
                self.setR1(@truncate(@as(u64, @bitCast(platform.unixSeconds()))));
                return .cont;
            },
            SYS_clock_gettime => {
                if (a1 == 1) {
                    const ms: u64 = @intCast(platform.nowMs() - self.start_ms);
                    self.putU32(a2, @truncate(ms / 1000));
                    self.putU32(a2 + 4, @truncate((ms % 1000) * 1_000_000));
                } else {
                    self.putU32(a2, @truncate(@as(u64, @bitCast(platform.unixSeconds()))));
                    self.putU32(a2 + 4, 0);
                }
                self.setR1(0);
                return .cont;
            },
            SYS_gettimeofday => {
                self.putU32(a1, @truncate(@as(u64, @bitCast(platform.unixSeconds()))));
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
                    if (self.use_seed) {
                        self.prng.random().bytes(self.ram[a1 .. a1 + a2]);
                    } else {
                        platform.fillRandom(self.ram[a1 .. a1 + a2]);
                    }
                    self.setR1(a2);
                } else {
                    self.setR1(NEG1);
                }
                return .cont;
            },
            SYS_getenv => {
                if (self.env.get(self.guestStr(a1))) |val| {
                    self.setR1(self.copyOut(a2, val, a3));
                } else {
                    self.setR1(NEG1);
                }
                return .cont;
            },
            SYS_setenv => {
                const ea = self.env_arena.allocator();
                const k = ea.dupe(u8, self.guestStr(a1)) catch {
                    self.setR1(NEG1);
                    return .cont;
                };
                const v = ea.dupe(u8, self.guestStr(a2)) catch {
                    self.setR1(NEG1);
                    return .cont;
                };
                self.env.put(k, v) catch {
                    self.setR1(NEG1);
                    return .cont;
                };
                self.setR1(0);
                return .cont;
            },
            SYS_unsetenv => {
                _ = self.env.remove(self.guestStr(a1));
                self.setR1(0);
                return .cont;
            },
            SYS_getenviron => {
                var n: u32 = 0;
                var it = self.env.iterator();
                while (it.next()) |e| {
                    n += self.copyOut(a1 + n, e.key_ptr.*, remaining(a2, n));
                    n += self.copyOut(a1 + n, "=", remaining(a2, n));
                    n += self.copyOut(a1 + n, e.value_ptr.*, remaining(a2, n));
                    if (n < a2) {
                        self.putByte(a1 + n, 0);
                        n += 1;
                    }
                }
                self.setR1(n);
                return .cont;
            },
            SYS_mmap => {
                const len = a2;
                if (r[4] & MAP_ANON == 0) {
                    self.setR1(EBADF);
                    return .cont;
                }
                const rounded = (len + 15) & ~@as(u32, 15);
                if (self.mmap_next + rounded <= MMAP_END) {
                    self.setR1(self.mmap_next);
                    self.mmap_next += rounded;
                } else {
                    self.setR1(ENOMEM);
                }
                return .cont;
            },
            SYS_munmap => {
                self.setR1(0);
                return .cont;
            },
            SYS_mprotect => {
                self.setR1(0);
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

    fn putByte(self: *Emulator, addr: u32, v: u8) void {
        if (addr < self.ram.len) self.ram[addr] = v;
    }

    fn guestStr(self: *Emulator, addr: u32) []const u8 {
        if (addr >= self.ram.len) return "";
        var end: u32 = addr;
        while (end < self.ram.len and self.ram[end] != 0) end += 1;
        return self.ram[addr..end];
    }

    fn copyOut(self: *Emulator, addr: u32, bytes: []const u8, limit: u32) u32 {
        var n: u32 = @intCast(@min(bytes.len, limit));
        if (!self.inBounds(addr, n)) n = 0;
        if (n > 0) @memcpy(self.ram[addr .. addr + n], bytes[0..n]);
        return n;
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
    try emu.start(src, .{}, &diag);
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
    try emu.start(src, .{}, &diag);
    const st = emu.tick(100000);
    try std.testing.expect(st == .halted);
}

test "breakpoint halts at the right pc and continue resumes" {
    const a = std.testing.allocator;
    var emu = try Emulator.init(a);
    defer emu.deinit();
    var diag: tb32.Diagnostic = .{};
    const src =
        \\.text
        \\.entry _start
        \\_start:
        \\    nop
        \\    nop
        \\    hlt
    ;
    try emu.start(src, .{}, &diag);
    emu.setBreak(0x1008, true);
    const st = emu.tick(100);
    try std.testing.expect(st == .breakpoint);
    try std.testing.expectEqual(@as(u32, 0x1008), emu.cpu.pc);
    try std.testing.expect(emu.tick(100) == .halted);
}

test "stepOne advances exactly one instruction" {
    const a = std.testing.allocator;
    var emu = try Emulator.init(a);
    defer emu.deinit();
    var diag: tb32.Diagnostic = .{};
    const src =
        \\.text
        \\.entry _start
        \\_start:
        \\    nop
        \\    hlt
    ;
    try emu.start(src, .{}, &diag);
    const pc0 = emu.cpu.pc;
    _ = emu.stepOne();
    try std.testing.expectEqual(pc0 + 4, emu.cpu.pc);
}

test "stepLine advances past a multi-instruction line" {
    const a = std.testing.allocator;
    var emu = try Emulator.init(a);
    defer emu.deinit();
    var diag: tb32.Diagnostic = .{};
    const src =
        \\.text
        \\_start:
        \\    li r1, 5
        \\    li r2, 6
        \\    hlt
    ;
    try emu.start(src, .{}, &diag);
    const pc0 = emu.cpu.pc;
    try std.testing.expect(emu.stepLine() == .running);
    try std.testing.expectEqual(pc0 + 8, emu.cpu.pc);
}

test "seeded getrandom is reproducible" {
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
    try emu.start(src, .{ .seed = 42 }, &diag);
    _ = emu.tick(100000);
    var first: [8]u8 = undefined;
    @memcpy(&first, emu.ram[0x2000..0x2008]);
    try emu.start(src, .{ .seed = 42 }, &diag);
    _ = emu.tick(100000);
    try std.testing.expectEqualSlices(u8, &first, emu.ram[0x2000..0x2008]);
}

test "run config populates env and argv" {
    const a = std.testing.allocator;
    var emu = try Emulator.init(a);
    defer emu.deinit();
    var diag: tb32.Diagnostic = .{};
    const src = "\n.text\n_start:\nhlt\n";
    const args = [_][]const u8{ "prog", "one" };
    const keys = [_][]const u8{"HOME"};
    const vals = [_][]const u8{"/root"};
    try emu.start(src, .{ .args = &args, .env_keys = &keys, .env_vals = &vals }, &diag);
    try std.testing.expectEqualStrings("/root", emu.env.get("HOME").?);
    try std.testing.expectEqual(@as(u32, 2), emu.cpu.r[1]);
}
