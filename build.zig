const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libtb32 = b.dependency("tb32", .{
        .target = target,
        .optimize = optimize,
    });
    const tb32_mod = libtb32.module("tb32");

    const exe = b.addExecutable(.{
        .name = "tb32emu",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tb32", tb32_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tb32emu");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("tb32", tb32_mod);
    const test_step = b.step("test", "Run tb32emu tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
