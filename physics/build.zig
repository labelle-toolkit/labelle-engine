const std = @import("std");

/// Physics module build configuration
/// Standalone physics module with Box2D backend
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Physics module can be built standalone for testing
    const physics_mod = addPhysicsModule(b, target, optimize, null, null);

    // Unit tests for physics module
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("mod.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run physics module tests");
    test_step.dependOn(&run_unit_tests.step);

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "physics-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    // Link Box2D
    linkBox2d(b, bench_exe, target, optimize);

    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run physics benchmarks");
    bench_step.dependOn(&run_bench.step);

    _ = physics_mod;
}

/// Add physics module to a parent build
/// Called by labelle-engine's build.zig when physics is enabled
pub fn addPhysicsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ecs_module: ?*std.Build.Module,
    build_options_mod: ?*std.Build.Module,
) *std.Build.Module {
    // Box2D dependency
    const box2d_dep = b.dependency("box2d", .{
        .target = target,
        .optimize = optimize,
    });

    var imports = std.ArrayList(std.Build.Module.Import).init(b.allocator);

    // Add Box2D
    imports.append(.{
        .name = "box2d",
        .module = box2d_dep.module("box2d"),
    }) catch @panic("OOM");

    // Add ECS interface if provided (for entity types)
    if (ecs_module) |ecs| {
        imports.append(.{
            .name = "ecs",
            .module = ecs,
        }) catch @panic("OOM");
    }

    // Add build options if provided
    if (build_options_mod) |opts| {
        imports.append(.{
            .name = "build_options",
            .module = opts,
        }) catch @panic("OOM");
    }

    const physics_mod = b.addModule("labelle-physics", .{
        .root_source_file = b.path("physics/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports.toOwnedSlice() catch @panic("OOM"),
    });

    // Link Box2D library
    physics_mod.linkLibrary(box2d_dep.artifact("box2d"));

    return physics_mod;
}

/// Link Box2D to an artifact (for executables/tests)
fn linkBox2d(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const box2d_dep = b.dependency("box2d", .{
        .target = target,
        .optimize = optimize,
    });
    artifact.linkLibrary(box2d_dep.artifact("box2d"));
}
