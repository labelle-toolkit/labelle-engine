const std = @import("std");

/// Graphics backend selection
pub const Backend = enum {
    raylib,
    sokol,
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

    // Backend options (for custom combinations)
    const backend = b.option(Backend, "backend", "Graphics backend (default: raylib)") orelse .raylib;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend (default: zig_ecs)") orelse .zig_ecs;
    const gui_backend = b.option(GuiBackend, "gui_backend", "GUI backend (default: raygui)") orelse .raygui;

    // Default run step with custom options
    const default_exe = createExecutable(b, target, optimize, backend, ecs_backend, gui_backend, "example_gui");
    const run_step = b.step("run", "Run with selected backends (use -Dbackend=, -Dgui_backend=)");
    run_step.dependOn(&b.addRunArtifact(default_exe).step);

    // Convenience run steps for common backend combinations
    // Raylib + Raygui (default)
    const raylib_raygui = createExecutable(b, target, optimize, .raylib, .zig_ecs, .raygui, "example_gui_raylib_raygui");
    const run_raylib_raygui = b.step("run-raylib-raygui", "Run with raylib + raygui");
    run_raylib_raygui.dependOn(&b.addRunArtifact(raylib_raygui).step);

    // Raylib + Microui
    const raylib_microui = createExecutable(b, target, optimize, .raylib, .zig_ecs, .microui, "example_gui_raylib_microui");
    const run_raylib_microui = b.step("run-raylib-microui", "Run with raylib + microui");
    run_raylib_microui.dependOn(&b.addRunArtifact(raylib_microui).step);

    // Sokol + Raygui
    const sokol_raygui = createExecutable(b, target, optimize, .sokol, .zig_ecs, .raygui, "example_gui_sokol_raygui");
    const run_sokol_raygui = b.step("run-sokol-raygui", "Run with sokol + raygui");
    run_sokol_raygui.dependOn(&b.addRunArtifact(sokol_raygui).step);

    // Sokol + Microui
    const sokol_microui = createExecutable(b, target, optimize, .sokol, .zig_ecs, .microui, "example_gui_sokol_microui");
    const run_sokol_microui = b.step("run-sokol-microui", "Run with sokol + microui");
    run_sokol_microui.dependOn(&b.addRunArtifact(sokol_microui).step);

    // Raylib + Nuklear
    const raylib_nuklear = createExecutable(b, target, optimize, .raylib, .zig_ecs, .nuklear, "example_gui_raylib_nuklear");
    const run_raylib_nuklear = b.step("run-raylib-nuklear", "Run with raylib + nuklear");
    run_raylib_nuklear.dependOn(&b.addRunArtifact(raylib_nuklear).step);

    // Sokol + Nuklear
    const sokol_nuklear = createExecutable(b, target, optimize, .sokol, .zig_ecs, .nuklear, "example_gui_sokol_nuklear");
    const run_sokol_nuklear = b.step("run-sokol-nuklear", "Run with sokol + nuklear");
    run_sokol_nuklear.dependOn(&b.addRunArtifact(sokol_nuklear).step);

    // Raylib + ImGui
    const raylib_imgui = createExecutable(b, target, optimize, .raylib, .zig_ecs, .imgui, "example_gui_raylib_imgui");
    const run_raylib_imgui = b.step("run-raylib-imgui", "Run with raylib + imgui");
    run_raylib_imgui.dependOn(&b.addRunArtifact(raylib_imgui).step);

    // Sokol + ImGui
    const sokol_imgui = createExecutable(b, target, optimize, .sokol, .zig_ecs, .imgui, "example_gui_sokol_imgui");
    const run_sokol_imgui = b.step("run-sokol-imgui", "Run with sokol + imgui");
    run_sokol_imgui.dependOn(&b.addRunArtifact(sokol_imgui).step);

    // Shortcut aliases
    const run_microui = b.step("run-microui", "Alias for run-raylib-microui");
    run_microui.dependOn(run_raylib_microui);

    const run_nuklear = b.step("run-nuklear", "Alias for run-raylib-nuklear");
    run_nuklear.dependOn(run_raylib_nuklear);

    const run_sokol = b.step("run-sokol", "Alias for run-sokol-raygui");
    run_sokol.dependOn(run_sokol_raygui);

    const run_imgui = b.step("run-imgui", "Alias for run-raylib-imgui");
    run_imgui.dependOn(run_raylib_imgui);
}

fn createExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    backend: Backend,
    ecs_backend: EcsBackend,
    gui_backend: GuiBackend,
    name: []const u8,
) *std.Build.Step.Compile {
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .ecs_backend = ecs_backend,
        .gui_backend = gui_backend,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
            },
        }),
    });
    b.installArtifact(exe);

    return exe;
}
