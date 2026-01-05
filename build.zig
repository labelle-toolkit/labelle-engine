const std = @import("std");

/// Graphics backend selection
pub const Backend = enum {
    raylib,
    sokol,
    sdl,
    bgfx,
    zgpu,
};

/// ECS backend selection
pub const EcsBackend = enum {
    zig_ecs,
    zflecs,
    mr_ecs,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const backend = b.option(Backend, "backend", "Graphics backend to use (default: raylib)") orelse .raylib;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend to use (default: zig_ecs)") orelse .zig_ecs;
    const physics_enabled = b.option(bool, "physics", "Enable physics module (Box2D)") orelse false;

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

    // mr_ecs module - only loaded when explicitly selected (requires Zig 0.16+)
    const mr_ecs_module: ?*std.Build.Module = if (ecs_backend == .mr_ecs) blk: {
        const mr_ecs_dep = b.dependency("mr_ecs", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk mr_ecs_dep.module("mr_ecs");
    } else null;

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
    build_options.addOption(bool, "physics_enabled", physics_enabled);
    const build_options_mod = build_options.createModule();

    // Physics module (optional, enabled with -Dphysics=true)
    var physics_module: ?*std.Build.Module = null;
    if (physics_enabled) {
        const box2d_dep = b.dependency("box2d", .{
            .target = target,
            .optimize = optimize,
        });

        physics_module = b.addModule("labelle-physics", .{
            .root_source_file = b.path("physics/mod.zig"),
            .target = target,
            .optimize = optimize,
        });
        physics_module.?.addImport("box2d", box2d_dep.module("box2d"));
        physics_module.?.linkLibrary(box2d_dep.artifact("box2d"));
    }

    // Create the ECS interface module that wraps the selected backend
    const ecs_interface = b.addModule("ecs", .{
        .root_source_file = b.path("ecs/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "zig_ecs", .module = zig_ecs_module },
            .{ .name = "zflecs", .module = zflecs_module },
        },
    });
    // Add mr_ecs if selected (requires Zig 0.16+)
    if (mr_ecs_module) |m| {
        ecs_interface.addImport("mr_ecs", m);
    }

    // Create the Input interface module that wraps the selected backend
    const input_interface = b.addModule("input", .{
        .root_source_file = b.path("input/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib },
            .{ .name = "sokol", .module = sokol },
            .{ .name = "sdl2", .module = sdl },
        },
    });

    // Create the Graphics interface module that wraps the selected backend
    // This allows plugins to use graphics types without pulling in specific backend modules
    const graphics_interface = b.addModule("graphics", .{
        .root_source_file = b.path("graphics/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "labelle", .module = labelle },
        },
    });

    // Create the Audio interface module that wraps the selected backend
    const audio_interface = b.addModule("audio", .{
        .root_source_file = b.path("audio/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib },
            .{ .name = "zaudio", .module = zaudio },
        },
    });

    // Link miniaudio library for audio module (only needed for sokol/SDL backends)
    if (backend != .raylib) {
        audio_interface.linkLibrary(zaudio_dep.artifact("miniaudio"));
    }

    // Core module - foundation types (entity utils, zon coercion)
    const core_mod = b.addModule("labelle-core", .{
        .root_source_file = b.path("core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs", .module = ecs_interface },
        },
    });

    // Hooks module - event/hook system
    _ = b.addModule("labelle-hooks", .{
        .root_source_file = b.path("hooks/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Render module - visual rendering pipeline
    // Uses graphics interface instead of labelle directly to avoid module collisions
    _ = b.addModule("labelle-render", .{
        .root_source_file = b.path("render/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graphics", .module = graphics_interface },
            .{ .name = "ecs", .module = ecs_interface },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // Main module (unified entry point with namespaced submodules)
    const engine_mod = b.addModule("labelle-engine", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle", .module = labelle },
            .{ .name = "graphics", .module = graphics_interface },
            .{ .name = "ecs", .module = ecs_interface },
            .{ .name = "input", .module = input_interface },
            .{ .name = "audio", .module = audio_interface },
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // Add physics module to engine if enabled
    if (physics_module) |physics| {
        engine_mod.addImport("physics", physics);
    }


    // Unit tests (standard zig test)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle", .module = labelle },
                .{ .name = "graphics", .module = graphics_interface },
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
                .{ .name = "graphics", .module = graphics_interface },
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

    // Core module tests
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/test/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zspec", .module = zspec },
                .{ .name = "labelle-core", .module = core_mod },
            },
        }),
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const core_test_step = b.step("core-test", "Run core module tests");
    core_test_step.dependOn(&run_core_tests.step);

    // Main test step runs all module tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_zspec_tests.step);
    test_step.dependOn(&run_core_tests.step);

    // Note: Examples have their own build.zig and are built separately
    // To run example_1: cd usage/example_1 && zig build run

    // Build.zig.zon module for version info (needed before generator_exe)
    const build_zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    // Generator executable - generates project files from project.labelle
    const generator_exe = b.addExecutable(.{
        .name = "labelle-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generator_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zts", .module = zts },
                .{ .name = "build_zon", .module = build_zon_mod },
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

    // Benchmark executable - compares ECS backend performance
    const bench_module = b.createModule(.{
        .root_source_file = b.path("ecs/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always use ReleaseFast for benchmarks
        .imports = &.{
            .{ .name = "ecs", .module = ecs_interface },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "zig_ecs", .module = zig_ecs_module },
            .{ .name = "zflecs", .module = zflecs_module },
        },
    });
    // Add mr_ecs if selected (requires Zig 0.16+)
    if (mr_ecs_module) |m| {
        bench_module.addImport("mr_ecs", m);
    }
    const bench_exe = b.addExecutable(.{
        .name = "ecs-benchmark",
        .root_module = bench_module,
    });

    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run ECS benchmarks (use -Decs_backend=zig_ecs or -Decs_backend=zflecs)");
    bench_step.dependOn(&run_bench.step);
}
