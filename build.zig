const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zignight",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "zignight_check",
        .root_module = exe_mod,
    });
    const check = b.step("check", "Check if zignight_check compiles");
    check.dependOn(&exe_check.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    exe_mod.addIncludePath(b.path("miniaudio"));
    exe_mod.addCSourceFile(.{ .file = b.path("miniaudio/miniaudio.c") });
    exe.linkLibC();
    exe_check.linkLibC();

    const mibu_dep = b.dependency("mibu", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("mibu", mibu_dep.module("mibu"));
}
