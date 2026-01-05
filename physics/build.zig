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

    // Helper to add a physics benchmark executable
    // Usage: zig build bench-all (runs all benchmarks)
    const addPhysicsBenchmark = struct {
        fn add(
            builder: *std.Build,
            tgt: std.Build.ResolvedTarget,
            physics: *std.Build.Module,
            box2d: *std.Build.Dependency,
            comptime source: []const u8,
            comptime exe_name: []const u8,
            comptime step_name: []const u8,
            comptime description: []const u8,
        ) *std.Build.Step {
            const exe = builder.addExecutable(.{
                .name = exe_name,
                .root_module = builder.createModule(.{
                    .root_source_file = builder.path(source),
                    .target = tgt,
                    .optimize = .ReleaseFast,
                    .imports = &.{
                        .{ .name = "labelle-physics", .module = physics },
                    },
                }),
            });
            exe.root_module.linkLibrary(box2d.artifact("box2d"));
            builder.installArtifact(exe);

            const run = builder.addRunArtifact(exe);
            run.step.dependOn(builder.getInstallStep());

            const step = builder.step(step_name, description);
            step.dependOn(&run.step);

            return &run.step;
        }
    }.add;

    const run_velocity_step = addPhysicsBenchmark(
        b,
        target,
        physics_mod,
        box2d_dep,
        "benchmark/velocity_benchmark.zig",
        "velocity-benchmark",
        "bench-velocity",
        "Run velocity control benchmark",
    );

    const run_collision_step = addPhysicsBenchmark(
        b,
        target,
        physics_mod,
        box2d_dep,
        "benchmark/collision_benchmark.zig",
        "collision-benchmark",
        "bench-collision",
        "Run collision query benchmark",
    );

    const run_compound_step = addPhysicsBenchmark(
        b,
        target,
        physics_mod,
        box2d_dep,
        "benchmark/compound_benchmark.zig",
        "compound-benchmark",
        "bench-compound",
        "Run compound shapes benchmark",
    );

    // All benchmarks step
    const all_bench_step = b.step("bench-all", "Run all physics benchmarks");
    all_bench_step.dependOn(&run_bench.step);
    all_bench_step.dependOn(run_velocity_step);
    all_bench_step.dependOn(run_collision_step);
    all_bench_step.dependOn(run_compound_step);
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
