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
    clay,
    raygui,
    microui,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Backend options - default to Clay GUI
    const backend = b.option(Backend, "backend", "Graphics backend (default: raylib)") orelse .raylib;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend (default: zig_ecs)") orelse .zig_ecs;
    const gui_backend = b.option(GuiBackend, "gui_backend", "GUI backend (default: clay)") orelse .clay;

    // Main run step with Clay UI
    const clay_exe = createExecutable(b, target, optimize, backend, ecs_backend, gui_backend, "example_clay_gui");
    const run_cmd = b.addRunArtifact(clay_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Clay GUI example");
    run_step.dependOn(&run_cmd.step);

    // Convenience steps for different graphics backends
    const clay_raylib = createExecutable(b, target, optimize, .raylib, .zig_ecs, .clay, "example_clay_gui_raylib");
    const run_raylib = b.step("run-raylib", "Run with Clay UI + Raylib");
    run_raylib.dependOn(&b.addRunArtifact(clay_raylib).step);

    const clay_sokol = createExecutable(b, target, optimize, .sokol, .zig_ecs, .clay, "example_clay_gui_sokol");
    const run_sokol = b.step("run-sokol", "Run with Clay UI + Sokol");
    run_sokol.dependOn(&b.addRunArtifact(clay_sokol).step);

    // Comparison runs with other GUI backends
    const raygui_exe = createExecutable(b, target, optimize, .raylib, .zig_ecs, .raygui, "example_gui_raygui");
    const run_raygui = b.step("run-raygui", "Run with Raygui for comparison");
    run_raygui.dependOn(&b.addRunArtifact(raygui_exe).step);

    const microui_exe = createExecutable(b, target, optimize, .raylib, .zig_ecs, .microui, "example_gui_microui");
    const run_microui = b.step("run-microui", "Run with Microui for comparison");
    run_microui.dependOn(&b.addRunArtifact(microui_exe).step);
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
