const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = switch (optimize) {
        .Debug, .ReleaseSafe => false,
        .ReleaseSmall, .ReleaseFast => true,
    };

    const miniaudio_dep = b.dependency("miniaudio", .{});

    const miniaudio_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    miniaudio_mod.addIncludePath(miniaudio_dep.path("."));
    miniaudio_mod.addCSourceFile(.{ .file = miniaudio_dep.path("miniaudio.c") });

    const miniaudio = b.addLibrary(.{
        .name = "miniaudio",
        .root_module = miniaudio_mod,
    });
    miniaudio.installHeader(miniaudio_dep.path("miniaudio.h"), "miniaudio.h");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    exe_mod.linkLibrary(miniaudio);

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

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
}
