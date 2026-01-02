const std = @import("std");

/// Physics module build configuration
/// Standalone physics module with Box2D backend
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Box2D dependency
    const box2d_dep = b.dependency("box2d", .{
        .target = target,
        .optimize = optimize,
    });

    // ZSpec dependency
    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // Physics module
    const physics_mod = b.addModule("labelle-physics", .{
        .root_source_file = b.path("mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    physics_mod.addImport("box2d", box2d_dep.module("box2d"));
    physics_mod.linkLibrary(box2d_dep.artifact("box2d"));

    // ZSpec tests
    const zspec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
                .{ .name = "labelle-physics", .module = physics_mod },
            },
        }),
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });
    zspec_tests.root_module.linkLibrary(box2d_dep.artifact("box2d"));

    const run_zspec_tests = b.addRunArtifact(zspec_tests);
    const zspec_test_step = b.step("zspec", "Run zspec tests");
    zspec_test_step.dependOn(&run_zspec_tests.step);

    // Main test step runs zspec tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_zspec_tests.step);

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "physics-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "labelle-physics", .module = physics_mod },
            },
        }),
    });
    bench_exe.root_module.linkLibrary(box2d_dep.artifact("box2d"));

    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run physics benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Velocity benchmark
    const velocity_bench_exe = b.addExecutable(.{
        .name = "velocity-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/velocity_benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "labelle-physics", .module = physics_mod },
            },
        }),
    });
    velocity_bench_exe.root_module.linkLibrary(box2d_dep.artifact("box2d"));
    b.installArtifact(velocity_bench_exe);

    const run_velocity_bench = b.addRunArtifact(velocity_bench_exe);
    run_velocity_bench.step.dependOn(b.getInstallStep());

    const velocity_bench_step = b.step("bench-velocity", "Run velocity control benchmark");
    velocity_bench_step.dependOn(&run_velocity_bench.step);

    // Collision benchmark
    const collision_bench_exe = b.addExecutable(.{
        .name = "collision-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/collision_benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "labelle-physics", .module = physics_mod },
            },
        }),
    });
    collision_bench_exe.root_module.linkLibrary(box2d_dep.artifact("box2d"));
    b.installArtifact(collision_bench_exe);

    const run_collision_bench = b.addRunArtifact(collision_bench_exe);
    run_collision_bench.step.dependOn(b.getInstallStep());

    const collision_bench_step = b.step("bench-collision", "Run collision query benchmark");
    collision_bench_step.dependOn(&run_collision_bench.step);

    // Compound shapes benchmark
    const compound_bench_exe = b.addExecutable(.{
        .name = "compound-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/compound_benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "labelle-physics", .module = physics_mod },
            },
        }),
    });
    compound_bench_exe.root_module.linkLibrary(box2d_dep.artifact("box2d"));
    b.installArtifact(compound_bench_exe);

    const run_compound_bench = b.addRunArtifact(compound_bench_exe);
    run_compound_bench.step.dependOn(b.getInstallStep());

    const compound_bench_step = b.step("bench-compound", "Run compound shapes benchmark");
    compound_bench_step.dependOn(&run_compound_bench.step);

    // All benchmarks step
    const all_bench_step = b.step("bench-all", "Run all physics benchmarks");
    all_bench_step.dependOn(&run_bench.step);
    all_bench_step.dependOn(&run_velocity_bench.step);
    all_bench_step.dependOn(&run_collision_bench.step);
    all_bench_step.dependOn(&run_compound_bench.step);
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
