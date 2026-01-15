// ============================================================================
// ImGui GUI Example with SDL2 Backend
// ============================================================================
// Demonstrates ImGui GUI with SDL2 graphics backend.
// Uses SDL graphics backend with imgui_sdl_adapter.
// ============================================================================

const std = @import("std");

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
};

/// GUI backend selection
pub const GuiBackend = enum {
    none,
    raygui,
    microui,
    nuklear,
    imgui,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Backend options - SDL graphics with imgui GUI
    const backend = b.option(Backend, "backend", "Graphics backend (default: sdl)") orelse .sdl;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend (default: zig_ecs)") orelse .zig_ecs;
    const gui_backend = b.option(GuiBackend, "gui_backend", "GUI backend (default: imgui)") orelse .imgui;

    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .ecs_backend = ecs_backend,
        .gui_backend = gui_backend,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    const exe = b.addExecutable(.{
        .name = "example_gui_sdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
            },
        }),
    });

    // Link SDL2 libraries
    exe.linkLibC();

    const target_os = target.result.os.tag;
    if (target_os == .macos) {
        // macOS: use Homebrew-installed SDL2
        exe.linkSystemLibrary("sdl2");
        exe.linkSystemLibrary("sdl2_ttf");
        exe.linkSystemLibrary("sdl2_image");

        // macOS frameworks required by SDL2
        exe.linkFramework("Cocoa");
        exe.linkFramework("CoreAudio");
        exe.linkFramework("Carbon");
        exe.linkFramework("Metal");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("AudioToolbox");
        exe.linkFramework("ForceFeedback");
        exe.linkFramework("GameController");
        exe.linkFramework("CoreHaptics");
        exe.linkSystemLibrary("iconv");

        // SDL2_ttf dependencies
        exe.linkSystemLibrary("freetype");
        exe.linkSystemLibrary("harfbuzz");
        exe.linkSystemLibrary("bz2");
        exe.linkSystemLibrary("zlib");
        exe.linkSystemLibrary("graphite2");

        // SDL2_image dependencies
        exe.linkSystemLibrary("jpeg");
        exe.linkSystemLibrary("libpng");
        exe.linkSystemLibrary("tiff");
        exe.linkSystemLibrary("webp");
    } else if (target_os == .linux) {
        // Linux: use system SDL2 packages
        exe.linkSystemLibrary("SDL2");
        exe.linkSystemLibrary("SDL2_ttf");
        exe.linkSystemLibrary("SDL2_image");
    } else if (target_os == .windows) {
        // Windows: use SDL2 libraries
        exe.linkSystemLibrary("SDL2");
        exe.linkSystemLibrary("SDL2_ttf");
        exe.linkSystemLibrary("SDL2_image");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
