const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get labelle-engine dependency
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
    });
    const engine_mod = engine_dep.module("labelle-engine");
    const labelle_mod = engine_dep.module("labelle");
    const ecs_mod = engine_dep.module("ecs");

    // Main executable
    const exe = b.addExecutable(.{
        .name = "example_6",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "labelle", .module = labelle_mod },
                .{ .name = "ecs", .module = ecs_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run example 6");
    run_step.dependOn(&run_cmd.step);
}
