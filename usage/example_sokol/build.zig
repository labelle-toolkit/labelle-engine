const std = @import("std");

pub const Backend = enum { raylib, sokol };
pub const EcsBackend = enum { zig_ecs, zflecs };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Default to Sokol backend for this example
    const backend = b.option(Backend, "backend", "Graphics backend") orelse .sokol;
    const ecs_backend = b.option(EcsBackend, "ecs_backend", "ECS backend") orelse .zig_ecs;

    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .ecs_backend = ecs_backend,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Get labelle-gfx dependency for sokol bindings
    const labelle_dep = engine_dep.builder.dependency("labelle-gfx", .{
        .target = target,
        .optimize = optimize,
    });
    const sokol_dep = labelle_dep.builder.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const sokol_mod = sokol_dep.module("sokol");

    const exe = b.addExecutable(.{
        .name = "example_sokol",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "sokol", .module = sokol_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
