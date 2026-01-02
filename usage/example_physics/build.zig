// Physics Example Build
// Demonstrates physics integration with labelle-engine

const std = @import("std");

pub const Backend = enum {
    raylib,
    sokol,
};

pub const EcsBackend = enum {
    zig_ecs,
    zflecs,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(Backend, "backend", "Graphics backend (default: raylib)") orelse .raylib;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend (default: zig_ecs)") orelse .zig_ecs;

    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .ecs_backend = ecs_backend,
        .physics = true, // Enable physics module
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Get physics module separately for direct access
    const physics_mod = engine_dep.module("labelle-physics");

    const exe = b.addExecutable(.{
        .name = "example_physics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "labelle-physics", .module = physics_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the physics demo");
    run_step.dependOn(&run_cmd.step);
}
