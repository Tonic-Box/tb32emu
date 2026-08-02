const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libtb32 = b.dependency("tb32", .{
        .target = target,
        .optimize = optimize,
    });
    const webview = b.dependency("webview", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tb32emu",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tb32", libtb32.module("tb32"));
    exe.root_module.addImport("webview", webview.module("webview"));
    exe.linkLibrary(webview.artifact("webviewStatic"));
    exe.linkLibCpp();
    if (target.result.os.tag == .windows) {
        exe.addWin32ResourceFile(.{ .file = b.path("app.rc") });
        if (optimize != .Debug) exe.subsystem = .Windows;
    }
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
    tests.root_module.addImport("tb32", libtb32.module("tb32"));
    tests.root_module.addImport("webview", webview.module("webview"));
    const test_step = b.step("test", "Run tb32emu tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
