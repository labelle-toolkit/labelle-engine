const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const ecs_dep = b.dependency("zig_ecs", .{
        .target = target,
        .optimize = optimize,
    });
    const ecs = ecs_dep.module("zig-ecs");

    const labelle_dep = b.dependency("labelle-gfx", .{
        .target = target,
        .optimize = optimize,
    });
    const labelle = labelle_dep.module("labelle");

    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });
    const zspec = zspec_dep.module("zspec");

    // Main module
    const engine_mod = b.addModule("labelle-engine", .{
        .root_source_file = b.path("src/scene.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle", .module = labelle },
            .{ .name = "ecs", .module = ecs },
        },
    });

    // Unit tests (standard zig test)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scene.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle", .module = labelle },
                .{ .name = "ecs", .module = ecs },
            },
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("unit-test", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // ZSpec tests
    const zspec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zspec", .module = zspec },
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "labelle", .module = labelle },
                .{ .name = "ecs", .module = ecs },
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

    // Usage examples
    const example_files = [_]struct { name: []const u8, path: []const u8, desc: []const u8 }{
        .{ .name = "example-1", .path = "usage/example_1/example.zig", .desc = "Run example 1: Basic usage" },
        .{ .name = "example-2", .path = "usage/example_2/ecs_components.zig", .desc = "Run example 2: ECS components" },
    };

    const all_examples_step = b.step("examples", "Run all examples");
    var first_example_run: ?*std.Build.Step = null;

    for (example_files) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "labelle-engine", .module = engine_mod },
                    .{ .name = "labelle", .module = labelle },
                    .{ .name = "ecs", .module = ecs },
                },
            }),
        });

        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(b.getInstallStep());

        const run_step = b.step(ex.name, ex.desc);
        run_step.dependOn(&run_exe.step);

        all_examples_step.dependOn(&run_exe.step);

        // Save first example for backwards compatibility alias
        if (first_example_run == null) {
            first_example_run = &run_exe.step;
        }
    }

    // Alias 'example' to run example-1 for backwards compatibility
    const example_step = b.step("example", "Run example 1 (alias for example-1)");
    if (first_example_run) |step| {
        example_step.dependOn(step);
    }
}
