const std = @import("std");

/// Render module build configuration
/// Provides rendering pipeline that bridges ECS components to graphics backend
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ZSpec dependency for tests
    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // Note: When built standalone, render module needs labelle-gfx and ecs dependencies
    // These would typically be provided by the parent labelle-engine build

    // ZSpec tests
    const zspec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
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

/// Add render module to a parent build
/// Called by labelle-engine's build.zig
pub fn addRenderModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    labelle_gfx_mod: *std.Build.Module,
    ecs_module: *std.Build.Module,
    build_options_mod: *std.Build.Module,
) *std.Build.Module {
    const render_mod = b.addModule("labelle-render", .{
        .root_source_file = b.path("render/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle", .module = labelle_gfx_mod },
            .{ .name = "ecs", .module = ecs_module },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    return render_mod;
}
