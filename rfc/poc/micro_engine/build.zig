const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("micro_core", .{
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("micro_engine", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_dep.module("micro_core") },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_dep.module("micro_core") },
            },
        }),
    });
    const test_step = b.step("test", "Run micro_engine tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
