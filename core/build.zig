const std = @import("std");

/// Core module build configuration
/// Standalone core module with entity utilities and ZON coercion
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ECS dependency (for Entity type)
    const ecs_dep = b.dependency("zig_ecs", .{
        .target = target,
        .optimize = optimize,
    });
    const ecs_module = ecs_dep.module("zig-ecs");

    // ZSpec dependency
    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // Core module
    const core_mod = createCoreModule(b, target, optimize, ecs_module, "mod.zig");

    // ZSpec tests
    const zspec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
                .{ .name = "engine-utils", .module = core_mod },
            },
        }),
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });

    const run_zspec_tests = b.addRunArtifact(zspec_tests);
    const zspec_test_step = b.step("zspec", "Run zspec tests");
    zspec_test_step.dependOn(&run_zspec_tests.step);

    // Main test step runs zspec tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_zspec_tests.step);
}

/// Add core module to a parent build
/// Called by labelle-engine's build.zig
pub fn addCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ecs_module: *std.Build.Module,
) *std.Build.Module {
    return createCoreModule(b, target, optimize, ecs_module, "core/mod.zig");
}

/// Helper to create core module with configurable root path
fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ecs_module: *std.Build.Module,
    root_source_path: []const u8,
) *std.Build.Module {
    const core_mod = b.addModule("engine-utils", .{
        .root_source_file = b.path(root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs", .module = ecs_module },
        },
    });
    return core_mod;
}
