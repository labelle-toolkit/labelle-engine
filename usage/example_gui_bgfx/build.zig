// ============================================================================
// ImGui GUI Example with bgfx Backend
// ============================================================================
// Demonstrates ImGui GUI with bgfx graphics backend.
// Uses bgfx graphics backend with imgui_bgfx_adapter.
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

    // Backend options - bgfx graphics with imgui GUI
    const backend = b.option(Backend, "backend", "Graphics backend (default: bgfx)") orelse .bgfx;
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

    // Get bgfx, glfw, and labelle-gfx modules (re-exported by engine)
    const zbgfx_mod = engine_dep.builder.modules.get("zbgfx") orelse
        @panic("zbgfx module not found - ensure backend=bgfx is set");
    const zglfw_mod = engine_dep.builder.modules.get("zglfw") orelse
        @panic("zglfw module not found");
    const labelle_gfx_mod = engine_dep.builder.modules.get("labelle-gfx") orelse
        @panic("labelle-gfx module not found");

    const exe = b.addExecutable(.{
        .name = "example_gui_bgfx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "zbgfx", .module = zbgfx_mod },
                .{ .name = "zglfw", .module = zglfw_mod },
                .{ .name = "labelle-gfx", .module = labelle_gfx_mod },
            },
        }),
    });
    // bgfx and glfw C libraries are linked transitively through the engine module
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
