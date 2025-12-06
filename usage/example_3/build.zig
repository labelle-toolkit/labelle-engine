const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const labelle_engine_dep = b.dependency("labelle_engine", .{
        .target = target,
        .optimize = optimize,
    });
    const labelle_engine = labelle_engine_dep.module("labelle-engine");

    const labelle_dep = b.dependency("labelle", .{
        .target = target,
        .optimize = optimize,
    });
    const labelle = labelle_dep.module("labelle");

    const ecs_dep = b.dependency("zig_ecs", .{
        .target = target,
        .optimize = optimize,
    });
    const ecs = ecs_dep.module("zig-ecs");

    // Main executable
    const exe = b.addExecutable(.{
        .name = "example-labelle-rendering",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = labelle_engine },
                .{ .name = "labelle", .module = labelle },
                .{ .name = "ecs", .module = ecs },
            },
        }),
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_exe.step);
}
