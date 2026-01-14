const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum { sokol };
pub const EcsBackend = enum { zig_ecs, zflecs };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend") orelse .zig_ecs;

    // Get labelle-engine dependency
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = .sokol,
        .ecs_backend = ecs_backend,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Get labelle-physics dependency
    const physics_dep = b.dependency("labelle-physics", .{
        .target = target,
        .optimize = optimize,
    });
    const physics_mod = physics_dep.module("labelle-physics");

    // Create executable
    const exe = b.addExecutable(.{
        .name = "mobile_physics_test",
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

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the physics test");
    run_step.dependOn(&run_cmd.step);

    // Test step (just builds to verify compilation)
    const test_step = b.step("test", "Build and verify compilation");
    test_step.dependOn(&exe.step);
}
