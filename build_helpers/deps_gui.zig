//! GUI Backend Build Helpers
//!
//! Handles GUI backend dependencies and module setup for:
//! - Nuklear (immediate mode GUI)
//! - ImGui via zgui (raylib, SDL, bgfx)
//! - ImGui via dcimgui + sokol_imgui (sokol backend)
//! - rlImGui bridge (raylib + ImGui integration)
//! - wgpu_native ImGui adapter

const std = @import("std");

/// GUI backend selection (mirrors build.zig)
pub const GuiBackend = enum {
    none,
    raygui,
    microui,
    nuklear,
    imgui,
    clay,
};

/// Graphics backend selection (mirrors build.zig)
pub const Backend = enum {
    raylib,
    sokol,
    sdl,
    bgfx,
    wgpu_native,
};

/// Context for GUI module setup
pub const GuiContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gui_backend: GuiBackend,
    graphics_backend: Backend,
    is_desktop: bool,
    is_ios: bool,
    is_wasm: bool,
    is_android: bool,

    // Dependencies (may be null based on platform)
    labelle_dep: *std.Build.Dependency,
    sokol_dep: ?*std.Build.Dependency,

    // Modules (may be null based on platform)
    raylib: ?*std.Build.Module,
    sdl: ?*std.Build.Module,
    zbgfx: ?*std.Build.Module,
    wgpu_native: ?*std.Build.Module,
    zglfw: ?*std.Build.Module,
    labelle: *std.Build.Module,
    sokol: ?*std.Build.Module,
    zclay: ?*std.Build.Module,
    build_options_mod: *std.Build.Module,
};

/// Load Nuklear dependency if gui_backend is nuklear
pub fn loadNuklear(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Module {
    const nuklear_dep = b.dependency("nuklear", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .vertex_backend = true,
        .font_baking = true,
        .default_font = true,
        .no_stb_rect_pack = true, // Raylib already provides stb_rect_pack
    });
    return nuklear_dep.module("nuklear");
}

/// zgui backend enum (matches zgui/build.zig)
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

/// Get appropriate zgui backend for graphics backend
fn getZguiBackend(graphics_backend: Backend) ZguiBackend {
    return switch (graphics_backend) {
        .raylib => .no_backend, // raylib uses rlImGui
        .sokol => unreachable, // sokol uses dcimgui
        .sdl => .sdl2_renderer,
        .bgfx => .glfw,
        .wgpu_native => .no_backend, // uses custom adapter
    };
}

/// Load zgui dependency for ImGui (non-sokol backends)
pub fn loadZgui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    graphics_backend: Backend,
) ?*std.Build.Dependency {
    if (graphics_backend == .sokol) return null;

    const zgui_backend = getZguiBackend(graphics_backend);
    const needs_obsolete = (zgui_backend == .sdl2_renderer);

    return b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = zgui_backend,
        .disable_obsolete = !needs_obsolete,
    });
}

/// Load dcimgui dependency for sokol + ImGui
pub fn loadCimgui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });
}

/// Create the GUI interface module with all necessary imports
pub fn createGuiModule(ctx: GuiContext) *std.Build.Module {
    // Start with minimal imports, add optional ones after
    const gui_interface = ctx.b.addModule("gui", .{
        .root_source_file = ctx.b.path("gui/mod.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{
            .{ .name = "build_options", .module = ctx.build_options_mod },
            .{ .name = "labelle", .module = ctx.labelle },
        },
    });

    // Add optional modules based on what's available (backend-dependent)
    if (ctx.sokol) |m| gui_interface.addImport("sokol", m);
    if (ctx.raylib) |m| gui_interface.addImport("raylib", m);
    if (ctx.sdl) |m| gui_interface.addImport("sdl2", m);
    if (ctx.zbgfx) |m| gui_interface.addImport("zbgfx", m);
    if (ctx.wgpu_native) |m| gui_interface.addImport("wgpu", m);
    if (ctx.zglfw) |m| gui_interface.addImport("zglfw", m);
    if (ctx.zclay) |m| gui_interface.addImport("zclay", m);

    return gui_interface;
}

/// Configure GUI module with Nuklear backend
pub fn configureNuklear(gui_interface: *std.Build.Module, nuklear_module: *std.Build.Module) void {
    gui_interface.addImport("nuklear", nuklear_module);
}

/// Configure GUI module with zgui/ImGui backend
pub fn configureZgui(
    ctx: GuiContext,
    gui_interface: *std.Build.Module,
    zgui_dep: *std.Build.Dependency,
) void {
    gui_interface.addImport("zgui", zgui_dep.module("root"));
    gui_interface.linkLibrary(zgui_dep.artifact("imgui"));

    // Link OpenGL on macOS for raylib backend
    if (ctx.target.result.os.tag == .macos and ctx.graphics_backend == .raylib) {
        gui_interface.linkFramework("OpenGL", .{});
    }

    // For raylib backend, setup rlImGui bridge
    if (ctx.graphics_backend == .raylib) {
        setupRlImGui(ctx, gui_interface, zgui_dep);
    }

    // For wgpu_native backend, setup ImGui adapter
    if (ctx.graphics_backend == .wgpu_native and ctx.is_desktop) {
        setupWgpuNativeImgui(ctx, gui_interface, zgui_dep);
    }
}

/// Setup rlImGui bridge for raylib + ImGui integration
fn setupRlImGui(
    ctx: GuiContext,
    gui_interface: *std.Build.Module,
    zgui_dep: *std.Build.Dependency,
) void {
    const rlimgui_dep = ctx.b.dependency("rlimgui", .{});
    const raylib_zig_dep = ctx.labelle_dep.builder.dependency("raylib_zig", .{
        .target = ctx.target,
        .optimize = ctx.optimize,
    });

    // Create module for rlImGui C++ sources
    const rlimgui_mod = ctx.b.createModule(.{
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libcpp = true,
    });

    // Add rlImGui source
    rlimgui_mod.addCSourceFile(.{
        .file = rlimgui_dep.path("rlImGui.cpp"),
        .flags = &.{
            "-std=c++11",
            "-fno-sanitize=undefined",
            "-DNO_FONT_AWESOME",
        },
    });

    // Include paths
    rlimgui_mod.addIncludePath(zgui_dep.path("libs/imgui"));
    rlimgui_mod.addIncludePath(rlimgui_dep.path(""));

    // Raylib headers
    const raylib_c_dep = raylib_zig_dep.builder.dependency("raylib", .{
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    rlimgui_mod.addIncludePath(raylib_c_dep.path("src"));

    // Link imgui
    rlimgui_mod.linkLibrary(zgui_dep.artifact("imgui"));

    // Create static library
    const rlimgui_lib = ctx.b.addLibrary(.{
        .name = "rlimgui",
        .root_module = rlimgui_mod,
    });

    // Link to GUI interface
    gui_interface.linkLibrary(rlimgui_lib);
    gui_interface.addIncludePath(rlimgui_dep.path(""));
    gui_interface.addIncludePath(zgui_dep.path("libs/imgui"));
    gui_interface.addIncludePath(raylib_c_dep.path("src"));
}

/// Configure GUI module with dcimgui + sokol_imgui backend
pub fn configureCimgui(
    ctx: GuiContext,
    gui_interface: *std.Build.Module,
    cimgui_dep: *std.Build.Dependency,
) void {
    gui_interface.addImport("cimgui", cimgui_dep.module("cimgui"));
    gui_interface.linkLibrary(cimgui_dep.artifact("cimgui_clib"));
    gui_interface.addIncludePath(cimgui_dep.path("src"));

    // Compile sokol_imgui.c
    const sokol_imgui_mod = ctx.b.createModule(.{
        .target = ctx.target,
        .optimize = ctx.optimize,
    });

    // Determine sokol backend define
    const sokol_backend_define: []const u8 = switch (ctx.target.result.os.tag) {
        .macos, .ios => "-DSOKOL_METAL",
        .windows => "-DSOKOL_D3D11",
        .linux => if (ctx.is_android) "-DSOKOL_GLES3" else "-DSOKOL_GLCORE",
        .freebsd, .openbsd => "-DSOKOL_GLCORE",
        .emscripten => "-DSOKOL_GLES3",
        else => "-DSOKOL_GLCORE",
    };

    // sokol_dep must be available for sokol backend with imgui
    const sokol_dep = ctx.sokol_dep orelse return;

    sokol_imgui_mod.addCSourceFile(.{
        .file = sokol_dep.path("src/sokol/c/sokol_imgui.c"),
        .flags = &.{
            "-DIMPL",
            sokol_backend_define,
            "-fno-sanitize=undefined",
        },
    });

    // Include paths
    sokol_imgui_mod.addIncludePath(sokol_dep.path("src/sokol/c"));
    sokol_imgui_mod.addIncludePath(cimgui_dep.path("src"));

    // Link libraries
    sokol_imgui_mod.linkLibrary(cimgui_dep.artifact("cimgui_clib"));
    sokol_imgui_mod.linkLibrary(sokol_dep.artifact("sokol_clib"));

    // Create static library
    const sokol_imgui_lib = ctx.b.addLibrary(.{
        .name = "sokol_imgui",
        .root_module = sokol_imgui_mod,
    });

    // Link to GUI interface
    gui_interface.linkLibrary(sokol_imgui_lib);
    gui_interface.addIncludePath(sokol_dep.path("src/sokol/c"));
}

/// Setup wgpu_native ImGui adapter
fn setupWgpuNativeImgui(
    ctx: GuiContext,
    gui_interface: *std.Build.Module,
    zgui_dep: *std.Build.Dependency,
) void {
    // Get wgpu_native dependency
    const wgpu_native_dep = ctx.labelle_dep.builder.dependency("wgpu_native_zig", .{
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    const zglfw_dep = ctx.labelle_dep.builder.dependency("zglfw", .{
        .target = ctx.target,
        .optimize = ctx.optimize,
    });

    // Compute wgpu target name for lazy dependency
    const target_res = ctx.target.result;
    const os_str = @tagName(target_res.os.tag);
    const arch_str = @tagName(target_res.cpu.arch);
    const mode_str = switch (ctx.optimize) {
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

    const target_name_slices = [_][:0]const u8{ "wgpu_", os_str, "_", arch_str, abi_str, "_", mode_str };
    const wgpu_target_name = std.mem.concatWithSentinel(ctx.b.allocator, u8, &target_name_slices, 0) catch @panic("OOM");

    // Get wgpu binary package
    const wgpu_binary_dep = wgpu_native_dep.builder.lazyDependency(wgpu_target_name, .{});
    const wgpu_include_path = if (wgpu_binary_dep) |wdep|
        wdep.path("include")
    else blk: {
        std.log.warn("Could not find wgpu binary dependency '{s}' for ImGui backend", .{wgpu_target_name});
        break :blk wgpu_native_dep.path("include");
    };

    // Create module for ImGui wgpu backend
    const imgui_wgpu_mod = ctx.b.createModule(.{
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libcpp = true,
    });

    // Compile imgui_impl_wgpu.cpp
    imgui_wgpu_mod.addCSourceFile(.{
        .file = zgui_dep.path("libs/imgui/backends/imgui_impl_wgpu.cpp"),
        .flags = &.{
            "-std=c++11",
            "-fno-sanitize=undefined",
            "-DIMGUI_IMPL_WEBGPU_BACKEND_WGPU",
        },
    });

    // Compile imgui_impl_glfw.cpp
    imgui_wgpu_mod.addCSourceFile(.{
        .file = zgui_dep.path("libs/imgui/backends/imgui_impl_glfw.cpp"),
        .flags = &.{
            "-std=c++11",
            "-fno-sanitize=undefined",
        },
    });

    // Include paths
    imgui_wgpu_mod.addIncludePath(zgui_dep.path("libs/imgui"));
    imgui_wgpu_mod.addIncludePath(wgpu_include_path);
    imgui_wgpu_mod.addIncludePath(zglfw_dep.path("libs/glfw/include"));

    // Link imgui
    imgui_wgpu_mod.linkLibrary(zgui_dep.artifact("imgui"));

    // Create static library
    const imgui_wgpu_lib = ctx.b.addLibrary(.{
        .name = "imgui_wgpu_native",
        .root_module = imgui_wgpu_mod,
    });

    // Link to GUI interface
    gui_interface.linkLibrary(imgui_wgpu_lib);
    gui_interface.addIncludePath(zgui_dep.path("libs/imgui"));
    gui_interface.addIncludePath(zgui_dep.path("libs/imgui/backends"));
    gui_interface.addIncludePath(wgpu_include_path);
    gui_interface.addIncludePath(zglfw_dep.path("libs/glfw/include"));
}
