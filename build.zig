const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libc = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.addWriteFiles().add("inc.h",
            \\#include <time.h>
        ),
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("c", libc.createModule());

    const exe = b.addExecutable(.{
        .name = "tak",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "");
    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);

    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const test_step = b.step("test", "");
    const test_exe = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(test_exe);
    test_step.dependOn(&run_tests.step);
}
