const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const want_console = b.option(bool, "console", "Attach a console window for stderr and panic output") orelse false;

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
        if (!want_console) exe.subsystem = .Windows;
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

    addWebStep(b, libtb32);
}

fn addWebStep(b: *std.Build, libtb32: *std.Build.Dependency) void {
    const web_out = b.option([]const u8, "web-out", "Output directory for the static web build") orelse "../emulator";

    const wasm = b.addExecutable(.{
        .name = "tb32emu",
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseFast,
    });
    wasm.root_module.addImport("tb32", libtb32.module("tb32"));
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.max_memory = 256 * 1024 * 1024;

    const copies = [_][2][]const u8{
        .{ "src/web/index.web.html", "index.html" },
        .{ "src/web/wasm-bridge.js", "wasm-bridge.js" },
        .{ "src/web/app.js", "app.js" },
        .{ "src/web/mobile.js", "mobile.js" },
        .{ "src/web/editor.js", "editor.js" },
        .{ "src/web/terminal.js", "terminal.js" },
        .{ "src/web/debugger.js", "debugger.js" },
        .{ "src/web/style.css", "style.css" },
        .{ "src/web/web.css", "web.css" },
        .{ "src/web/vendor/vt.js", "vendor/vt.js" },
        .{ "src/web/vendor/vt.css", "vendor/vt.css" },
        .{ "src/web/vendor/codemirror/codemirror.min.css", "vendor/codemirror/codemirror.min.css" },
        .{ "src/web/vendor/codemirror/codemirror.min.js", "vendor/codemirror/codemirror.min.js" },
        .{ "src/web/vendor/codemirror/simple.min.js", "vendor/codemirror/simple.min.js" },
    };

    const upd = b.addWriteFiles();
    upd.addCopyFileToSource(wasm.getEmittedBin(), b.fmt("{s}/tb32emu.wasm", .{web_out}));
    for (copies) |c| {
        upd.addCopyFileToSource(b.path(c[0]), b.fmt("{s}/{s}", .{ web_out, c[1] }));
    }

    const web_step = b.step("web", "Build the static web bundle");
    web_step.dependOn(&upd.step);
}
