const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get labelle-engine dependency (includes labelle-gfx and ecs)
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Main executable
    const exe = b.addExecutable(.{
        .name = "example_1",
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

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_exe.step);
}
