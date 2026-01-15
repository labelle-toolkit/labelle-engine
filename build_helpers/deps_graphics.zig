//! Graphics Backend Build Helpers
//!
//! Handles graphics backend dependencies:
//! - zbgfx (bgfx wrapper)
//! - wgpu_native (WebGPU via wgpu-native)
//! - zglfw (GLFW bindings)
//! - zaudio (miniaudio wrapper)

const std = @import("std");

/// Graphics backend selection (mirrors build.zig)
pub const Backend = enum {
    raylib,
    sokol,
    sdl,
    bgfx,
    wgpu_native,
};

/// Graphics dependencies loaded from labelle-gfx
pub const GraphicsDeps = struct {
    zbgfx: ?*std.Build.Module,
    wgpu_native: ?*std.Build.Module,
    zglfw: ?*std.Build.Module,
    zaudio: ?*std.Build.Module,
    zaudio_dep: ?*std.Build.Dependency,
};

/// Load desktop-only graphics dependencies from labelle-gfx
pub fn loadDesktopDeps(
    labelle_dep: *std.Build.Dependency,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) GraphicsDeps {
    // zbgfx
    const zbgfx_dep = labelle_dep.builder.dependency("zbgfx", .{
        .target = target,
        .optimize = optimize,
    });
    const zbgfx = zbgfx_dep.module("zbgfx");

    // wgpu_native
    const wgpu_native_dep = labelle_dep.builder.dependency("wgpu_native_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const wgpu_native = wgpu_native_dep.module("wgpu");

    // zglfw
    const zglfw_dep = labelle_dep.builder.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zglfw = zglfw_dep.module("root");

    // zaudio
    const zaudio_dep = b.dependency("zaudio", .{
        .target = target,
        .optimize = optimize,
    });
    const zaudio = zaudio_dep.module("root");

    return .{
        .zbgfx = zbgfx,
        .wgpu_native = wgpu_native,
        .zglfw = zglfw,
        .zaudio = zaudio,
        .zaudio_dep = zaudio_dep,
    };
}

/// Return empty deps for non-desktop platforms (iOS, WASM)
pub fn emptyDeps() GraphicsDeps {
    return .{
        .zbgfx = null,
        .wgpu_native = null,
        .zglfw = null,
        .zaudio = null,
        .zaudio_dep = null,
    };
}

/// Create the input interface module
pub fn createInputModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
    raylib: ?*std.Build.Module,
    sokol: *std.Build.Module,
    sdl: ?*std.Build.Module,
    zglfw: ?*std.Build.Module,
    is_desktop: bool,
) *std.Build.Module {
    // WASM with raylib backend also needs raylib for raylib_input
    const use_raylib = raylib != null;

    return b.addModule("input", .{
        .root_source_file = b.path("input/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = if (is_desktop) &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib.? },
            .{ .name = "sokol", .module = sokol },
            .{ .name = "sdl2", .module = sdl.? },
            .{ .name = "zglfw", .module = zglfw.? },
        } else if (use_raylib) &.{
            // WASM with raylib backend: raylib + sokol
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib.? },
            .{ .name = "sokol", .module = sokol },
        } else &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "sokol", .module = sokol },
        },
    });
}

/// Create the graphics interface module
pub fn createGraphicsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
    labelle: *std.Build.Module,
) *std.Build.Module {
    return b.addModule("graphics", .{
        .root_source_file = b.path("graphics/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "labelle", .module = labelle },
        },
    });
}

/// Create the audio interface module
pub fn createAudioModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
    raylib: ?*std.Build.Module,
    sokol: *std.Build.Module,
    zaudio: ?*std.Build.Module,
    is_desktop: bool,
) *std.Build.Module {
    // Desktop needs sokol for sokol_audio backend, raylib for raylib_audio, zaudio for miniaudio
    // WASM with raylib backend also needs raylib for raylib_audio
    const use_raylib = raylib != null;
    const use_zaudio = zaudio != null;

    return b.addModule("audio", .{
        .root_source_file = b.path("audio/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = if (is_desktop) &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib.? },
            .{ .name = "sokol", .module = sokol },
            .{ .name = "zaudio", .module = zaudio.? },
            .{ .name = "sokol", .module = sokol },
        } else if (use_raylib and !use_zaudio) &.{
            // WASM with raylib backend: raylib + sokol, no zaudio
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "raylib", .module = raylib.? },
            .{ .name = "sokol", .module = sokol },
        } else &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "sokol", .module = sokol },
        },
    });
}

/// Configure audio module with miniaudio library (for sokol/SDL backends on desktop)
pub fn configureAudioMiniaudio(
    audio_interface: *std.Build.Module,
    zaudio_dep: *std.Build.Dependency,
) void {
    audio_interface.linkLibrary(zaudio_dep.artifact("miniaudio"));
}

/// Configure audio module with sokol_audio (for iOS/WASM)
pub fn configureAudioSokol(
    audio_interface: *std.Build.Module,
    sokol_dep: *std.Build.Dependency,
) void {
    audio_interface.linkLibrary(sokol_dep.artifact("sokol_clib"));
}
