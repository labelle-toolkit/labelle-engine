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

    const labelle_dep = b.dependency("labelle", .{
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

    // Usage example
    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("usage/example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "labelle", .module = labelle },
                .{ .name = "ecs", .module = ecs },
            },
        }),
    });

    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());

    const example_step = b.step("example", "Run the usage example");
    example_step.dependOn(&run_example.step);
}
