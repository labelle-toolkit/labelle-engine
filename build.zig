const std = @import("std");

/// Graphics backend selection
pub const Backend = enum {
    raylib,
    sokol,
    sdl,
    bgfx,
    zgpu,
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

    // Detect iOS target (raylib, SDL, etc. not supported on iOS)
    const is_ios = target.result.os.tag == .ios;

    // Detect iOS simulator on ARM - needs special handling for NEON intrinsics
    // iOS simulator on Apple Silicon (aarch64) doesn't fully support all NEON intrinsics
    // Note: Only apply ARM-specific workarounds on aarch64, not x86_64 simulators
    const is_ios_simulator = is_ios and target.result.abi == .simulator and target.result.cpu.arch == .aarch64;

    // Build options
    const backend = b.option(Backend, "backend", "Graphics backend to use (default: raylib)") orelse .raylib;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend to use (default: zig_ecs)") orelse .zig_ecs;
    const gui_backend = b.option(GuiBackend, "gui_backend", "GUI backend to use (default: none)") orelse .none;
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

    // For iOS, add SDK paths to zflecs artifact (C library needs system headers)
    if (is_ios) {
        const ios_sdk_path = std.zig.system.darwin.getSdk(b.allocator, &target.result);
        if (ios_sdk_path) |sdk| {
            const zflecs_artifact = zflecs_dep.artifact("flecs");
            const inc_path = b.pathJoin(&.{ sdk, "usr", "include" });
            const lib_path = b.pathJoin(&.{ sdk, "usr", "lib" });

            zflecs_artifact.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
            zflecs_artifact.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
        }
    }

    // mr_ecs module - only loaded when explicitly selected (requires Zig 0.16+)
    const mr_ecs_module: ?*std.Build.Module = if (ecs_backend == .mr_ecs) blk: {
        const mr_ecs_dep = b.dependency("mr_ecs", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk mr_ecs_dep.module("mr_ecs");
    } else null;

    // labelle-gfx dependency - handles iOS internally (skips raylib for iOS)
    const labelle_dep = b.dependency("labelle-gfx", .{
        .target = target,
        .optimize = optimize,
    });
    const labelle = labelle_dep.module("labelle");

    // raylib module - get from labelle-gfx's re-exported module (not available on iOS)
    // labelle-gfx uses the raylib-zig fork with getGLFWWindow() for ImGui integration
    const raylib: ?*std.Build.Module = if (!is_ios) labelle_dep.builder.modules.get("raylib") else null;

    // sokol dependency - DO NOT pass with_sokol_imgui here as it changes the
    // dependency hash and conflicts with labelle-gfx's sokol. For ImGui support,
    // we'll compile sokol_imgui separately (similar to rlImGui approach).
    // For iOS, we need to pass dont_link_system_libs and handle SDK paths manually.
    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .dont_link_system_libs = is_ios,
    });
    const sokol = sokol_dep.module("sokol");

    // For iOS, add SDK paths to sokol_clib artifact
    // Workaround for Zig bug #22704 where sysroot doesn't affect framework search paths
    if (is_ios) {
        const ios_sdk_path = std.zig.system.darwin.getSdk(b.allocator, &target.result);
        if (ios_sdk_path) |sdk| {
            const sokol_clib = sokol_dep.artifact("sokol_clib");
            const fw_path = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" });
            const subfw_path = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" });
            const inc_path = b.pathJoin(&.{ sdk, "usr", "include" });
            const lib_path = b.pathJoin(&.{ sdk, "usr", "lib" });

            sokol_clib.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
            sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_path });
            sokol_clib.root_module.addSystemFrameworkPath(.{ .cwd_relative = subfw_path });
            sokol_clib.root_module.addLibraryPath(.{ .cwd_relative = lib_path });
        }
    }

    // SDL module - get from labelle-gfx's re-exported module (not available on iOS)
    // labelle-gfx v0.15.0+ re-exports SDL to avoid Zig module conflicts
    const sdl: ?*std.Build.Module = if (!is_ios) labelle_dep.builder.modules.get("sdl") else null;

    // zbgfx, zgpu, wgpu_native, zglfw - not available on iOS
    const zbgfx: ?*std.Build.Module = if (!is_ios) blk: {
        const zbgfx_dep = labelle_dep.builder.dependency("zbgfx", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk zbgfx_dep.module("zbgfx");
    } else null;

    const zgpu: ?*std.Build.Module = if (!is_ios) blk: {
        const zgpu_dep = labelle_dep.builder.dependency("zgpu", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk zgpu_dep.module("root");
    } else null;

    // wgpu_native - lower-level WebGPU bindings (alternative to zgpu)
    const wgpu_native: ?*std.Build.Module = if (!is_ios) blk: {
        const wgpu_native_dep = labelle_dep.builder.dependency("wgpu_native_zig", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk wgpu_native_dep.module("wgpu");
    } else null;

    // zglfw - GLFW bindings for zgpu/wgpu_native (not available on iOS)
    const zglfw: ?*std.Build.Module = if (!is_ios) blk: {
        const zglfw_dep = labelle_dep.builder.dependency("zglfw", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk zglfw_dep.module("root");
    } else null;

    // zaudio (miniaudio wrapper) for sokol/SDL audio backends
    // Note: zaudio is disabled on iOS because miniaudio requires Objective-C compilation
    // for AVFoundation.h, but zaudio compiles it as C. Will need Sokol audio backend for iOS.
    const zaudio_dep: ?*std.Build.Dependency = if (!is_ios) b.dependency("zaudio", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const zaudio: ?*std.Build.Module = if (zaudio_dep) |dep| dep.module("root") else null;

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

    // Clay UI dependency (Zig bindings)
    const zclay_dep = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });
    const zclay = zclay_dep.module("zclay");

    // For iOS simulator, disable SIMD in Clay to avoid NEON intrinsic issues
    if (is_ios_simulator) {
        for (zclay.link_objects.items) |link_object| {
            switch (link_object) {
                .other_step => |compile_step| {
                    compile_step.root_module.addCMacro("CLAY_DISABLE_SIMD", "1");
                },
                else => {},
            }
        }
    }

    // Build options module for compile-time configuration (create once, reuse everywhere)
    const build_options = b.addOptions();

    // Clay GUI backend uses ARM NEON intrinsics that don't work on iOS simulator
    // Fall back to .none when clay is selected but unavailable
    const effective_gui_backend: GuiBackend = if (gui_backend == .clay and is_ios_simulator) blk: {
        std.log.warn("Clay GUI backend disabled on iOS simulator (uses unsupported ARM NEON intrinsics)", .{});
        break :blk .none;
    } else gui_backend;

    build_options.addOption(Backend, "backend", backend);
    build_options.addOption(EcsBackend, "ecs_backend", ecs_backend);
    build_options.addOption(GuiBackend, "gui_backend", effective_gui_backend);
    build_options.addOption(bool, "physics_enabled", physics_enabled);
    build_options.addOption(bool, "is_ios", is_ios);
    build_options.addOption(bool, "is_ios_simulator", is_ios_simulator);
    const build_options_mod = build_options.createModule();

    // Physics module (optional, enabled with -Dphysics=true)
    var physics_module: ?*std.Build.Module = null;
    if (physics_enabled) {
        const box2d_dep = b.dependency("box2d", .{
            .target = target,
            .optimize = optimize,
        });

        const box2d_artifact = box2d_dep.artifact("box2d");

        // For iOS simulator, disable SIMD to avoid NEON intrinsic issues
        if (is_ios_simulator) {
            box2d_artifact.root_module.addCMacro("BOX2D_DISABLE_SIMD", "1");
        }

        // Create physics module first (needed for iOS SDK path addition below)
        physics_module = b.addModule("labelle-physics", .{
            .root_source_file = b.path("physics/mod.zig"),
            .target = target,
            .optimize = optimize,
        });
        physics_module.?.addImport("box2d", box2d_dep.module("box2d"));
        physics_module.?.linkLibrary(box2d_dep.artifact("box2d"));

        // For iOS (device or simulator), add SDK paths to box2d artifact (C library needs system headers)
        if (is_ios) {
            const ios_sdk_path = std.zig.system.darwin.getSdk(b.allocator, &target.result);
            if (ios_sdk_path) |sdk| {
                const inc_path = b.pathJoin(&.{ sdk, "usr", "include" });
                const lib_path = b.pathJoin(&.{ sdk, "usr", "lib" });

                box2d_artifact.root_module.addSystemIncludePath(.{ .cwd_relative = inc_path });
                box2d_artifact.root_module.addLibraryPath(.{ .cwd_relative = lib_path });

                // Also add to the physics module for @cImport
                physics_module.?.addSystemIncludePath(.{ .cwd_relative = inc_path });
            }
        }
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
    // Imports are conditional based on platform (iOS only has sokol)
    const input_interface = b.addModule("input", .{
        .root_source_file = b.path("input/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = if (!is_ios) &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib.? },
            .{ .name = "sokol", .module = sokol },
            .{ .name = "sdl2", .module = sdl.? },
            .{ .name = "zglfw", .module = zglfw.? }, // For zgpu/wgpu_native input
        } else &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "sokol", .module = sokol },
        },
    });

    // Create the Graphics interface module that wraps the selected backend
    // This allows plugins to use graphics types without pulling in specific backend modules
    // Note: labelle-gfx handles iOS internally (only sokol backend available on iOS)
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
    // On iOS, uses sokol_audio backend (no zaudio - miniaudio requires Objective-C for AVFoundation)
    const audio_interface = b.addModule("audio", .{
        .root_source_file = b.path("audio/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = if (!is_ios) &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib.? },
            .{ .name = "zaudio", .module = zaudio.? },
        } else &.{
            // iOS: uses sokol_audio backend
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "sokol", .module = sokol },
        },
    });

    // Link miniaudio library for audio module (only needed for sokol/SDL backends, not iOS)
    if (backend != .raylib and zaudio_dep != null) {
        audio_interface.linkLibrary(zaudio_dep.?.artifact("miniaudio"));
    }

    // Link sokol library for iOS audio (sokol_audio backend)
    if (is_ios) {
        audio_interface.linkLibrary(sokol_dep.artifact("sokol_clib"));
    }

    // Nuklear module (optional, loaded when gui_backend is nuklear)
    const nuklear_module: ?*std.Build.Module = if (gui_backend == .nuklear) blk: {
        const nuklear_dep = b.dependency("nuklear", .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .vertex_backend = true,
            .font_baking = true,
            .default_font = true,
            .no_stb_rect_pack = true, // Raylib already provides stb_rect_pack
        });
        break :blk nuklear_dep.module("nuklear");
    } else null;

    // zgui/ImGui dependency (optional, loaded when gui_backend is imgui)
    // Note: sokol uses dcimgui instead of zgui for ImGui integration
    const zgui_dep: ?*std.Build.Dependency = if (gui_backend == .imgui and backend != .sokol) blk: {
        // zgui backend enum matches zgui/build.zig Backend enum
        const ZguiBackend = enum {
            no_backend,
            glfw_wgpu,
            glfw_opengl3,
            glfw_vulkan,
            glfw_dx12,
            win32_dx12,
            glfw,
            sdl2_opengl3,
            osx_metal,
            sdl2,
            sdl2_renderer,
            sdl3,
            sdl3_opengl3,
            sdl3_renderer,
            sdl3_gpu,
        };

        // Select appropriate zgui backend based on graphics backend
        const zgui_backend: ZguiBackend = switch (backend) {
            .raylib => .no_backend, // raylib uses rlImGui for ImGui integration
            .sokol => unreachable, // sokol uses dcimgui, not zgui
            .sdl => .sdl2_renderer, // SDL uses SDL2 renderer
            .bgfx => .glfw, // bgfx uses GLFW (rendering handled separately)
            .zgpu => .glfw_wgpu, // zgpu uses GLFW+WebGPU
            .wgpu_native => .no_backend, // wgpu_native uses custom ImGui adapter
        };

        // SDL2 renderer backend needs obsolete functions (GetTexDataAsRGBA32, SetTexID)
        const needs_obsolete = (zgui_backend == .sdl2_renderer);

        break :blk b.dependency("zgui", .{
            .target = target,
            .optimize = optimize,
            .backend = zgui_backend,
            .disable_obsolete = !needs_obsolete,
        });
    } else null;

    // dcimgui dependency for sokol + ImGui integration
    // sokol uses dcimgui + sokol_imgui instead of zgui
    // Note: We compile sokol_imgui.c separately to avoid modifying sokol's dependency hash
    const cimgui_dep: ?*std.Build.Dependency = if (gui_backend == .imgui and backend == .sokol) blk: {
        break :blk b.dependency("cimgui", .{
            .target = target,
            .optimize = optimize,
        });
    } else null;

    // Create the GUI interface module that wraps the selected backend
    // Imports are conditional based on platform (iOS only has sokol)
    const gui_interface = b.addModule("gui", .{
        .root_source_file = b.path("gui/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = if (!is_ios) &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib.? },
            .{ .name = "sokol", .module = sokol },
            .{ .name = "sdl2", .module = sdl.? },
            .{ .name = "zbgfx", .module = zbgfx.? },
            .{ .name = "zgpu", .module = zgpu.? },
            .{ .name = "wgpu", .module = wgpu_native.? }, // For wgpu_native ImGui adapter
            .{ .name = "labelle", .module = labelle }, // For zgpu/wgpu_native context access
            .{ .name = "zglfw", .module = zglfw.? }, // For GLFW window access
            .{ .name = "zclay", .module = zclay },
        } else &.{
            // iOS: reduced imports, no labelle-gfx modules
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "sokol", .module = sokol },
            .{ .name = "zclay", .module = zclay },
        },
    });

    // Add nuklear module to GUI if using nuklear backend
    if (nuklear_module) |nk| {
        gui_interface.addImport("nuklear", nk);
    }

    // Add zgui module and link library to GUI if using imgui backend
    if (zgui_dep) |dep| {
        gui_interface.addImport("zgui", dep.module("root"));
        gui_interface.linkLibrary(dep.artifact("imgui"));

        // Link OpenGL framework on macOS for glfw_opengl3 backend
        // Note: sokol uses cimgui_dep instead of zgui_dep, so only raylib is relevant here
        if (target.result.os.tag == .macos and backend == .raylib) {
            gui_interface.linkFramework("OpenGL", .{});
        }

        // For raylib backend, compile and link rlImGui (raylib + ImGui bridge)
        if (backend == .raylib) {
            const rlimgui_dep = b.dependency("rlimgui", .{});
            const raylib_zig_dep = labelle_dep.builder.dependency("raylib_zig", .{
                .target = target,
                .optimize = optimize,
            });

            // Create a module for rlImGui C++ sources
            const rlimgui_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libcpp = true,
            });

            // Add rlImGui source file
            rlimgui_mod.addCSourceFile(.{
                .file = rlimgui_dep.path("rlImGui.cpp"),
                .flags = &.{
                    "-std=c++11",
                    "-fno-sanitize=undefined",
                    "-DNO_FONT_AWESOME", // Disable Font Awesome (optional feature)
                },
            });

            // Add include paths for ImGui (from zgui) and rlImGui headers
            rlimgui_mod.addIncludePath(dep.path("libs/imgui"));
            rlimgui_mod.addIncludePath(rlimgui_dep.path(""));

            // Add raylib include path - raylib headers are in the raylib submodule
            const raylib_c_dep = raylib_zig_dep.builder.dependency("raylib", .{
                .target = target,
                .optimize = optimize,
            });
            rlimgui_mod.addIncludePath(raylib_c_dep.path("src"));

            // Link against imgui
            rlimgui_mod.linkLibrary(dep.artifact("imgui"));

            // Create static library from the module
            const rlimgui_lib = b.addLibrary(.{
                .name = "rlimgui",
                .root_module = rlimgui_mod,
            });

            // Link rlImGui to GUI interface
            gui_interface.linkLibrary(rlimgui_lib);

            // Add rlimgui include path so cImport can find rlImGui.h
            gui_interface.addIncludePath(rlimgui_dep.path(""));
            gui_interface.addIncludePath(dep.path("libs/imgui"));
            gui_interface.addIncludePath(raylib_c_dep.path("src"));
        }
    }

    // Add cimgui module and link library to GUI if using imgui backend with sokol
    // sokol uses dcimgui + sokol_imgui instead of zgui
    if (cimgui_dep) |dep| {
        gui_interface.addImport("cimgui", dep.module("cimgui"));
        gui_interface.linkLibrary(dep.artifact("cimgui_clib"));

        // Add include paths for cImport to find cimgui.h
        gui_interface.addIncludePath(dep.path("src"));

        // Compile sokol_imgui.c as a separate library
        // sokol_imgui provides the bridge between ImGui and sokol_gfx
        const sokol_imgui_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
        });

        // Determine sokol backend define based on target platform
        // Supported: macOS/iOS (Metal), Windows (D3D11), Linux/BSD (OpenGL), Web (GLES3)
        // Other platforms default to OpenGL Core which may not work
        const sokol_backend_define: []const u8 = switch (target.result.os.tag) {
            .macos, .ios => "-DSOKOL_METAL",
            .windows => "-DSOKOL_D3D11",
            .linux, .freebsd, .openbsd => "-DSOKOL_GLCORE",
            .emscripten => "-DSOKOL_GLES3",
            else => "-DSOKOL_GLCORE", // Fallback, may not work on all platforms
        };

        // Add sokol_imgui.c source file
        sokol_imgui_mod.addCSourceFile(.{
            .file = sokol_dep.path("src/sokol/c/sokol_imgui.c"),
            .flags = &.{
                "-DIMPL",
                sokol_backend_define,
                "-fno-sanitize=undefined",
            },
        });

        // Add include paths for sokol headers and cimgui headers
        sokol_imgui_mod.addIncludePath(sokol_dep.path("src/sokol/c"));
        sokol_imgui_mod.addIncludePath(dep.path("src"));

        // Link against cimgui
        sokol_imgui_mod.linkLibrary(dep.artifact("cimgui_clib"));

        // Link against sokol (for sokol_gfx)
        sokol_imgui_mod.linkLibrary(sokol_dep.artifact("sokol_clib"));

        // Create static library from the module
        const sokol_imgui_lib = b.addLibrary(.{
            .name = "sokol_imgui",
            .root_module = sokol_imgui_mod,
        });

        // Link sokol_imgui to GUI interface
        gui_interface.linkLibrary(sokol_imgui_lib);

        // Add sokol headers include path for sokol_imgui.zig cImport
        gui_interface.addIncludePath(sokol_dep.path("src/sokol/c"));
    }

    // Compile imgui_impl_wgpu.cpp for wgpu_native backend
    // wgpu_native needs IMGUI_IMPL_WEBGPU_BACKEND_WGPU define (not Dawn)
    // Not available on iOS
    if (zgui_dep) |dep| {
        if (backend == .wgpu_native and !is_ios) {
            // Fetch wgpu_native and zglfw dependencies here since they're not available on iOS
            const local_wgpu_native_dep = labelle_dep.builder.dependency("wgpu_native_zig", .{
                .target = target,
                .optimize = optimize,
            });
            const local_zglfw_dep = labelle_dep.builder.dependency("zglfw", .{
                .target = target,
                .optimize = optimize,
            });

            // Get wgpu_native's include path from the target-specific dependency
            // wgpu_native_zig uses lazy dependencies like "wgpu_macos_aarch64_release"
            // We need to compute the same target name to get the headers
            const target_res = target.result;
            const os_str = @tagName(target_res.os.tag);
            const arch_str = @tagName(target_res.cpu.arch);
            const mode_str = switch (optimize) {
                .Debug => "debug",
                else => "release",
            };
            const abi_str: [:0]const u8 = switch (target_res.os.tag) {
                .ios => switch (target_res.abi) {
                    .simulator => "_simulator",
                    else => "",
                },
                .windows => switch (target_res.abi) {
                    .msvc => "_msvc",
                    else => "_gnu",
                },
                else => "",
            };

            // Format: wgpu_<os>_<arch><abi>_<mode>
            const target_name_slices = [_][:0]const u8{ "wgpu_", os_str, "_", arch_str, abi_str, "_", mode_str };
            const wgpu_target_name = std.mem.concatWithSentinel(b.allocator, u8, &target_name_slices, 0) catch @panic("OOM");

            // Get the wgpu binary package through wgpu_native_zig's builder
            const wgpu_binary_dep = local_wgpu_native_dep.builder.lazyDependency(wgpu_target_name, .{});
            const wgpu_include_path = if (wgpu_binary_dep) |wdep|
                wdep.path("include")
            else blk: {
                std.log.warn("Could not find wgpu binary dependency '{s}' for ImGui backend", .{wgpu_target_name});
                break :blk local_wgpu_native_dep.path("include"); // Fallback (will fail at compile time)
            };

            // Create a module for ImGui wgpu_native backend sources
            const imgui_wgpu_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libcpp = true,
            });

            // Compile imgui_impl_wgpu.cpp with IMGUI_IMPL_WEBGPU_BACKEND_WGPU define
            imgui_wgpu_mod.addCSourceFile(.{
                .file = dep.path("libs/imgui/backends/imgui_impl_wgpu.cpp"),
                .flags = &.{
                    "-std=c++11",
                    "-fno-sanitize=undefined",
                    "-DIMGUI_IMPL_WEBGPU_BACKEND_WGPU", // Use wgpu-native API, not Dawn
                },
            });

            // Compile imgui_impl_glfw.cpp for input handling
            imgui_wgpu_mod.addCSourceFile(.{
                .file = dep.path("libs/imgui/backends/imgui_impl_glfw.cpp"),
                .flags = &.{
                    "-std=c++11",
                    "-fno-sanitize=undefined",
                },
            });

            // Add include paths
            imgui_wgpu_mod.addIncludePath(dep.path("libs/imgui")); // ImGui headers
            imgui_wgpu_mod.addIncludePath(wgpu_include_path); // wgpu_native WebGPU headers
            imgui_wgpu_mod.addIncludePath(local_zglfw_dep.path("libs/glfw/include")); // GLFW headers

            // Link against zgui's imgui library for core ImGui symbols
            imgui_wgpu_mod.linkLibrary(dep.artifact("imgui"));

            // Create static library from the module
            const imgui_wgpu_lib = b.addLibrary(.{
                .name = "imgui_wgpu_native",
                .root_module = imgui_wgpu_mod,
            });

            // Link to GUI interface
            gui_interface.linkLibrary(imgui_wgpu_lib);

            // Add include paths for Zig cImport
            gui_interface.addIncludePath(dep.path("libs/imgui"));
            gui_interface.addIncludePath(dep.path("libs/imgui/backends"));
            gui_interface.addIncludePath(wgpu_include_path);
            gui_interface.addIncludePath(local_zglfw_dep.path("libs/glfw/include"));
        }
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
    // Note: labelle-gfx handles iOS internally (only sokol backend available on iOS)
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
        },
    });

    // Add physics module to engine if enabled
    if (physics_module) |physics| {
        engine_mod.addImport("physics", physics);
    }

    // Unit tests (standard zig test) - not for iOS
    const unit_tests = if (!is_ios) b.addTest(.{
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
    }) else null;

    if (unit_tests) |tests| {
        const run_unit_tests = b.addRunArtifact(tests);
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
                .{ .name = "labelle-core", .module = core_mod },
            },
        }),
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const core_test_step = b.step("core-test", "Run core module tests");
    core_test_step.dependOn(&run_core_tests.step);

    // ZSpec tests and main test step - not for iOS
    if (!is_ios) {
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

        // Main test step runs all module tests
        const test_step = b.step("test", "Run all tests");
        test_step.dependOn(&run_core_tests.step);
        test_step.dependOn(&run_zspec_tests.step);
    }

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
