const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve dependencies — each is a self-contained project
    const core_dep = b.dependency("micro_core", .{
        .target = target,
        .optimize = optimize,
    });
    const engine_dep = b.dependency("micro_engine", .{
        .target = target,
        .optimize = optimize,
    });
    const plugin_dep = b.dependency("micro_plugin", .{
        .target = target,
        .optimize = optimize,
    });

    const core_mod = core_dep.module("micro_core");
    const engine_mod = engine_dep.module("micro_engine");
    const plugin_mod = plugin_dep.module("micro_plugin");

    // Main — the micro game that wires everything
    const exe = b.addExecutable(.{
        .name = "poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "engine", .module = engine_mod },
                .{ .name = "micro_plugin", .module = plugin_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the POC");
    run_step.dependOn(&run_cmd.step);

    // Tests — validate all the design decisions
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "engine", .module = engine_mod },
                .{ .name = "micro_plugin", .module = plugin_mod },
            },
        }),
    });
    const test_step = b.step("test", "Run POC tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
