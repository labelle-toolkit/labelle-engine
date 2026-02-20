const std = @import("std");
const platform_ios = @import("build_helpers/platform_ios.zig");
const deps_gui = @import("build_helpers/deps_gui.zig");
const deps_graphics = @import("build_helpers/deps_graphics.zig");

/// Graphics backend selection
pub const Backend = enum {
    raylib,
    sokol,
    sdl,
    bgfx,
    wgpu_native,
};

/// ECS backend selection
pub const EcsBackend = enum {
    zig_ecs,
    zflecs,
    mr_ecs,
};

/// GUI backend selection
pub const GuiBackend = enum {
    none,
    raygui,
    microui,
    nuklear,
    imgui,
    clay,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Platform detection
    const is_ios = target.result.os.tag == .ios;
    const is_ios_simulator = is_ios and target.result.abi == .simulator and target.result.cpu.arch == .aarch64;
    const is_wasm = target.result.os.tag == .emscripten or target.result.cpu.arch == .wasm32;
    const is_android = target.result.os.tag == .linux and target.result.abi == .android;
    const is_desktop = !is_ios and !is_wasm and !is_android;

    // Build options
    const backend = b.option(Backend, "backend", "Graphics backend to use (default: raylib)") orelse .raylib;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend to use (default: zig_ecs)") orelse .zig_ecs;
    const gui_backend = b.option(GuiBackend, "gui_backend", "GUI backend to use (default: none)") orelse .none;
    const physics_enabled = b.option(bool, "physics", "Enable physics module (Box2D)") orelse false;

    // ==========================================================================
    // ECS Dependencies
    // ==========================================================================

    // zig_ecs - pure Zig, always available
    const ecs_dep = b.dependency("zig_ecs", .{ .target = target, .optimize = optimize });
    const zig_ecs_module = ecs_dep.module("zig-ecs");

    // zflecs - C code, skip on WASM (libc issues with emscripten)
    const zflecs_dep: ?*std.Build.Dependency = if (!is_wasm) b.dependency("zflecs", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const zflecs_module: ?*std.Build.Module = if (zflecs_dep) |dep| dep.module("root") else null;

    // Configure zflecs for iOS
    if (is_ios and zflecs_dep != null) {
        platform_ios.configureZflecs(zflecs_dep.?, target.result);
    }

    // mr_ecs - only when selected, skip on WASM
    const mr_ecs_module: ?*std.Build.Module = if (ecs_backend == .mr_ecs and !is_wasm) blk: {
        const mr_ecs_dep = b.dependency("mr_ecs", .{ .target = target, .optimize = optimize });
        break :blk mr_ecs_dep.module("mr_ecs");
    } else null;

    // ==========================================================================
    // Graphics Dependencies
    // ==========================================================================

    // labelle-gfx - handles iOS internally
    // Note: sokol is always available in labelle-gfx (no enable-sokol option needed)
    const labelle_dep = b.dependency("labelle-gfx", .{
        .target = target,
        .optimize = optimize,
    });
    const labelle = labelle_dep.module("labelle");

    // raylib - from labelle-gfx (needed for raylib backend on any platform)
    const raylib: ?*std.Build.Module = if (backend == .raylib) labelle_dep.builder.modules.get("raylib") else null;

    // SDL - from labelle-gfx (desktop only)
    const sdl: ?*std.Build.Module = if (is_desktop) labelle_dep.builder.modules.get("sdl") else null;

    // sokol - only available when enabled in labelle-gfx
    // Note: sokol is NOT declared in our build.zig.zon to prevent duplicate dependencies
    const sokol: ?*std.Build.Module = labelle_dep.builder.modules.get("sokol");
    if (backend == .sokol and sokol == null) {
        @panic("sokol backend selected but sokol module not exported by labelle-gfx");
    }

    // Export sokol for consumers when present
    if (sokol) |sk| {
        b.modules.put("sokol", sk) catch @panic("Failed to export sokol module");
    }

    // Note: sokol_dep is null because sokol is provided by labelle-gfx.
    // iOS/Android sokol configuration is handled by labelle-gfx.
    const sokol_dep: ?*std.Build.Dependency = null;

    // Desktop-only graphics deps (zbgfx, wgpu_native, zglfw, zaudio)
    const gfx_deps = if (is_desktop)
        deps_graphics.loadDesktopDeps(labelle_dep, b, target, optimize, backend)
    else
        deps_graphics.emptyDeps();

    // ==========================================================================
    // Other Dependencies
    // ==========================================================================

    const zspec_dep = b.dependency("zspec", .{ .target = target, .optimize = optimize });
    const zspec = zspec_dep.module("zspec");

    const zts_dep = b.dependency("zts", .{ .target = target, .optimize = optimize });
    const zts = zts_dep.module("zts");

    // Clay UI - skip on WASM and iOS simulator (SIMD issues)
    const zclay_dep: ?*std.Build.Dependency = if (!is_wasm and !is_ios_simulator)
        b.dependency("zclay", .{ .target = target, .optimize = optimize })
    else
        null;
    const zclay: ?*std.Build.Module = if (zclay_dep) |dep| dep.module("zclay") else null;

    // ==========================================================================
    // Build Options Module
    // ==========================================================================

    const build_options = b.addOptions();
    build_options.addOption(Backend, "backend", backend);
    build_options.addOption(EcsBackend, "ecs_backend", ecs_backend);
    build_options.addOption(GuiBackend, "gui_backend", gui_backend);
    build_options.addOption(bool, "physics_enabled", physics_enabled);
    build_options.addOption(bool, "is_ios", is_ios);
    build_options.addOption(bool, "is_ios_simulator", is_ios_simulator);
    build_options.addOption(bool, "is_wasm", is_wasm);
    build_options.addOption(bool, "is_android", is_android);
    build_options.addOption(bool, "has_zclay", zclay != null);
    build_options.addOption(bool, "has_zflecs", zflecs_module != null);
    const build_options_mod = build_options.createModule();

    // ==========================================================================
    // Physics Module (optional)
    // ==========================================================================

    var physics_module: ?*std.Build.Module = null;
    if (physics_enabled) {
        const box2d_dep = b.dependency("box2d", .{ .target = target, .optimize = optimize });

        // Configure Box2D for iOS
        if (is_ios) {
            platform_ios.configureBox2d(box2d_dep, target.result, is_ios_simulator);
        } else if (is_ios_simulator or is_wasm) {
            // Disable SIMD on iOS simulator and WASM (limited SIMD support)
            box2d_dep.artifact("box2d").root_module.addCMacro("BOX2D_DISABLE_SIMD", "1");
        }

        // Configure emscripten sysroot for WASM builds
        if (is_wasm) {
            const emsdk_dep = b.dependency("emsdk", .{});
            box2d_dep.artifact("box2d").root_module.addIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));
        }

        physics_module = b.addModule("labelle-physics", .{
            .root_source_file = b.path("physics/mod.zig"),
            .target = target,
            .optimize = optimize,
        });
        physics_module.?.addImport("box2d", box2d_dep.module("box2d"));
        physics_module.?.linkLibrary(box2d_dep.artifact("box2d"));

        // Add iOS SDK include path for @cImport
        if (is_ios) {
            platform_ios.addModuleIncludePath(physics_module.?, target.result);
        }

        // Add emscripten sysroot for @cImport on WASM
        if (is_wasm) {
            const emsdk_dep = b.dependency("emsdk", .{});
            physics_module.?.addIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));
        }
    }

    // ==========================================================================
    // Interface Modules
    // ==========================================================================

    // labelle-core plugin SDK (RFC #289) — needed by ecs_interface for core.Ecs(Backend) trait
    const labelle_core_dep = b.dependency("labelle-core", .{ .target = target, .optimize = optimize });
    const labelle_core_mod = labelle_core_dep.module("labelle-core");

    // ECS interface
    const ecs_interface = b.addModule("ecs", .{
        .root_source_file = b.path("ecs/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "zig_ecs", .module = zig_ecs_module },
        },
    });
    ecs_interface.addImport("labelle-core", labelle_core_mod);
    if (zflecs_module) |m| ecs_interface.addImport("zflecs", m);
    if (mr_ecs_module) |m| ecs_interface.addImport("mr_ecs", m);

    // Input interface
    const input_interface = deps_graphics.createInputModule(
        b,
        target,
        optimize,
        build_options_mod,
        raylib,
        sokol,
        sdl,
        gfx_deps.zglfw,
        backend,
    );

    // Graphics interface
    const graphics_interface = deps_graphics.createGraphicsModule(
        b,
        target,
        optimize,
        build_options_mod,
        labelle,
    );

    // Audio interface
    const audio_interface = deps_graphics.createAudioModule(
        b,
        target,
        optimize,
        build_options_mod,
        raylib,
        sokol,
        gfx_deps.zaudio,
        backend,
    );

    // Link miniaudio for sokol/SDL backends on desktop
    if (backend != .raylib and gfx_deps.zaudio_dep != null) {
        deps_graphics.configureAudioMiniaudio(audio_interface, gfx_deps.zaudio_dep.?);
    }

    // Link sokol_audio for iOS/WASM
    if (is_ios or is_wasm) {
        if (sokol_dep) |dep| {
            deps_graphics.configureAudioSokol(audio_interface, dep);
        }
        // Note: when using sokol from labelle-gfx, audio is already configured
    }

    // ==========================================================================
    // GUI Module
    // ==========================================================================

    // Load GUI backend dependencies
    const nuklear_module: ?*std.Build.Module = if (gui_backend == .nuklear)
        deps_gui.loadNuklear(b, target, optimize)
    else
        null;

    const zgui_dep: ?*std.Build.Dependency = if (gui_backend == .imgui and backend != .sokol)
        deps_gui.loadZgui(b, target, optimize, @as(deps_gui.Backend, @enumFromInt(@intFromEnum(backend))))
    else
        null;

    const cimgui_dep: ?*std.Build.Dependency = if (gui_backend == .imgui and backend == .sokol)
        deps_gui.loadCimgui(b, target, optimize)
    else
        null;

    // Create GUI module
    const gui_context = deps_gui.GuiContext{
        .b = b,
        .target = target,
        .optimize = optimize,
        .gui_backend = @as(deps_gui.GuiBackend, @enumFromInt(@intFromEnum(gui_backend))),
        .graphics_backend = @as(deps_gui.Backend, @enumFromInt(@intFromEnum(backend))),
        .is_desktop = is_desktop,
        .is_ios = is_ios,
        .is_wasm = is_wasm,
        .is_android = is_android,
        .labelle_dep = labelle_dep,
        .sokol_dep = sokol_dep,
        .raylib = raylib,
        .sdl = sdl,
        .zbgfx = gfx_deps.zbgfx,
        .wgpu_native = gfx_deps.wgpu_native,
        .zglfw = gfx_deps.zglfw,
        .labelle = labelle,
        .sokol = sokol,
        .zclay = zclay,
        .build_options_mod = build_options_mod,
    };

    const gui_interface = deps_gui.createGuiModule(gui_context);

    // Configure GUI backend
    if (nuklear_module) |nk| {
        deps_gui.configureNuklear(gui_interface, nk);
    }
    if (zgui_dep) |dep| {
        deps_gui.configureZgui(gui_context, gui_interface, dep);
    }
    if (cimgui_dep) |dep| {
        deps_gui.configureCimgui(gui_context, gui_interface, dep);
    }

    // ==========================================================================
    // Core Modules
    // ==========================================================================

    const core_mod = b.addModule("engine-utils", .{
        .root_source_file = b.path("core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs", .module = ecs_interface },
        },
    });

    _ = b.addModule("labelle-hooks", .{
        .root_source_file = b.path("hooks/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // Main engine module
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
            .{ .name = "gui", .module = gui_interface },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "labelle-core", .module = labelle_core_mod },
        },
    });

    if (physics_module) |physics| {
        engine_mod.addImport("physics", physics);
    }

    // ==========================================================================
    // Tests
    // ==========================================================================

    // Unit tests (desktop only)
    if (is_desktop) {
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
                    .{ .name = "labelle-core", .module = labelle_core_mod },
                },
            }),
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        const unit_test_step = b.step("unit-test", "Run unit tests");
        unit_test_step.dependOn(&run_unit_tests.step);
    }

    // Core module tests
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/test/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zspec", .module = zspec },
                .{ .name = "engine-utils", .module = core_mod },
            },
        }),
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const core_test_step = b.step("core-test", "Run core module tests");
    core_test_step.dependOn(&run_core_tests.step);

    // Engine module tests
    const engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("engine/test/tests.zig"),
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

    const run_engine_tests = b.addRunArtifact(engine_tests);
    const engine_test_step = b.step("engine-test", "Run engine module tests");
    engine_test_step.dependOn(&run_engine_tests.step);

    // Scene module tests
    const scene_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("scene/test/tests.zig"),
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

    const run_scene_tests = b.addRunArtifact(scene_tests);
    const scene_test_step = b.step("scene-test", "Run scene module tests");
    scene_test_step.dependOn(&run_scene_tests.step);

    // ZSpec tests (desktop only)
    if (is_desktop) {
        // Generator module tests (host-only: uses filesystem/tmpdir)
        const generator_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/generator_tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zspec", .module = zspec },
                },
            }),
            .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
        });

        const run_generator_tests = b.addRunArtifact(generator_tests);
        const generator_test_step = b.step("generator-test", "Run generator module tests");
        generator_test_step.dependOn(&run_generator_tests.step);

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

        const test_step = b.step("test", "Run all tests");
        test_step.dependOn(&run_core_tests.step);
        test_step.dependOn(&run_engine_tests.step);
        test_step.dependOn(&run_scene_tests.step);
        test_step.dependOn(&run_generator_tests.step);
        test_step.dependOn(&run_zspec_tests.step);
    }

    // ==========================================================================
    // Generator
    // ==========================================================================

    // Generator - always builds for host (native), not cross-compilation target
    if (is_desktop) {
        const build_zon_mod = b.createModule(.{
            .root_source_file = b.path("build.zig.zon"),
        });

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
        if (b.args) |args| run_generator.addArgs(args);

        const generate_step = b.step("generate", "Generate project files from project.labelle");
        generate_step.dependOn(&run_generator.step);
    }

    // ==========================================================================
    // Benchmarks (skip on WASM)
    // ==========================================================================

    if (!is_wasm and zflecs_module != null) {
        const bench_module = b.createModule(.{
            .root_source_file = b.path("ecs/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "ecs", .module = ecs_interface },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "zig_ecs", .module = zig_ecs_module },
                .{ .name = "zflecs", .module = zflecs_module.? },
            },
        });
        if (mr_ecs_module) |m| bench_module.addImport("mr_ecs", m);

        const bench_exe = b.addExecutable(.{
            .name = "ecs-benchmark",
            .root_module = bench_module,
        });

        b.installArtifact(bench_exe);

        const run_bench = b.addRunArtifact(bench_exe);
        run_bench.step.dependOn(b.getInstallStep());

        const bench_step = b.step("bench", "Run ECS benchmarks");
        bench_step.dependOn(&run_bench.step);
    }
}
