const std = @import("std");

/// Graphics backend selection
pub const Backend = enum {
    raylib,
    sokol,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const backend = b.option(Backend, "backend", "Graphics backend to use (default: raylib)") orelse .raylib;

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

    const zts_dep = b.dependency("zts", .{
        .target = target,
        .optimize = optimize,
    });
    const zts = zts_dep.module("zts");

    // Build options module for compile-time configuration
    const build_options = b.addOptions();
    build_options.addOption(Backend, "backend", backend);

    // Main module
    const engine_mod = b.addModule("labelle-engine", .{
        .root_source_file = b.path("src/scene.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle", .module = labelle },
            .{ .name = "ecs", .module = ecs },
            .{ .name = "build_options", .module = build_options.createModule() },
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
                .{ .name = "build_options", .module = build_options.createModule() },
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
                .{ .name = "build_options", .module = build_options.createModule() },
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

    // Note: Examples have their own build.zig and are built separately
    // To run example_1: cd usage/example_1 && zig build run

    // Generator executable - generates project files from project.labelle
    const generator_exe = b.addExecutable(.{
        .name = "labelle-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generator_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zts", .module = zts },
            },
        }),
    });

    b.installArtifact(generator_exe);

    const run_generator = b.addRunArtifact(generator_exe);
    run_generator.step.dependOn(b.getInstallStep());

    // Pass arguments to generator
    if (b.args) |args| {
        run_generator.addArgs(args);
    }

    const generate_step = b.step("generate", "Generate project files from project.labelle");
    generate_step.dependOn(&run_generator.step);
}
