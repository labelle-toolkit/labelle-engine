const std = @import("std");

/// Graphics backend selection
pub const Backend = enum {
    raylib,
    sokol,
    sdl,
};

/// ECS backend selection
pub const EcsBackend = enum {
    zig_ecs,
    zflecs,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const backend = b.option(Backend, "backend", "Graphics backend to use (default: raylib)") orelse .raylib;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend to use (default: zig_ecs)") orelse .zig_ecs;

    // ECS dependencies
    const ecs_dep = b.dependency("zig_ecs", .{
        .target = target,
        .optimize = optimize,
    });
    const zig_ecs_module = ecs_dep.module("zig-ecs");

    const zflecs_dep = b.dependency("zflecs", .{
        .target = target,
        .optimize = optimize,
    });
    const zflecs_module = zflecs_dep.module("root");

    const labelle_dep = b.dependency("labelle-gfx", .{
        .target = target,
        .optimize = optimize,
    });
    const labelle = labelle_dep.module("labelle");

    // Input backend dependencies
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib");

    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const sokol = sokol_dep.module("sokol");

    // SDL module - get from labelle-gfx's re-exported module
    // labelle-gfx v0.15.0+ re-exports SDL to avoid Zig module conflicts
    const sdl = labelle_dep.builder.modules.get("sdl").?;

    // zaudio (miniaudio wrapper) for sokol/SDL audio backends
    const zaudio_dep = b.dependency("zaudio", .{
        .target = target,
        .optimize = optimize,
    });
    const zaudio = zaudio_dep.module("root");

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

    // Build options module for compile-time configuration (create once, reuse everywhere)
    const build_options = b.addOptions();
    build_options.addOption(Backend, "backend", backend);
    build_options.addOption(EcsBackend, "ecs_backend", ecs_backend);
    const build_options_mod = build_options.createModule();

    // Create the ECS interface module that wraps the selected backend
    const ecs_interface = b.addModule("ecs", .{
        .root_source_file = b.path("src/ecs/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "zig_ecs", .module = zig_ecs_module },
            .{ .name = "zflecs", .module = zflecs_module },
        },
    });

    // Create the Input interface module that wraps the selected backend
    const input_interface = b.addModule("input", .{
        .root_source_file = b.path("src/input/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib },
            .{ .name = "sokol", .module = sokol },
            .{ .name = "sdl2", .module = sdl },
        },
    });

    // Create the Audio interface module that wraps the selected backend
    const audio_interface = b.addModule("audio", .{
        .root_source_file = b.path("src/audio/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib },
            .{ .name = "zaudio", .module = zaudio },
        },
    });

    // Link miniaudio library for audio module (needed for sokol/SDL backends)
    audio_interface.linkLibrary(zaudio_dep.artifact("miniaudio"));

    // Main module
    const engine_mod = b.addModule("labelle-engine", .{
        .root_source_file = b.path("src/scene.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle", .module = labelle },
            .{ .name = "ecs", .module = ecs_interface },
            .{ .name = "input", .module = input_interface },
            .{ .name = "audio", .module = audio_interface },
            .{ .name = "build_options", .module = build_options_mod },
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
                .{ .name = "ecs", .module = ecs_interface },
                .{ .name = "input", .module = input_interface },
                .{ .name = "audio", .module = audio_interface },
                .{ .name = "build_options", .module = build_options_mod },
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
                .{ .name = "ecs", .module = ecs_interface },
                .{ .name = "input", .module = input_interface },
                .{ .name = "audio", .module = audio_interface },
                .{ .name = "build_options", .module = build_options_mod },
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

    // Build.zig.zon module for version info
    const build_zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    // Main CLI executable - unified interface for labelle projects
    const cli_exe = b.addExecutable(.{
        .name = "labelle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zts", .module = zts },
                .{ .name = "build_zon", .module = build_zon_mod },
            },
        }),
    });

    b.installArtifact(cli_exe);

    // Benchmark executable - compares ECS backend performance
    const bench_exe = b.addExecutable(.{
        .name = "ecs-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ecs/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
            .imports = &.{
                .{ .name = "ecs", .module = ecs_interface },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "zig_ecs", .module = zig_ecs_module },
                .{ .name = "zflecs", .module = zflecs_module },
            },
        }),
    });

    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run ECS benchmarks (use -Decs_backend=zig_ecs or -Decs_backend=zflecs)");
    bench_step.dependOn(&run_bench.step);
}
