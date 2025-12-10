const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
    });
    const engine_mod = engine_dep.module("labelle-engine");

    // Get the generator executable from the engine dependency
    const generator_exe = engine_dep.artifact("labelle-generate");

    // Run the generator to create main.zig before compilation
    const generate_step = b.addRunArtifact(generator_exe);
    generate_step.addArgs(&.{ "--main-only", "." });
    generate_step.setCwd(b.path("."));

    // Create the executable
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

    // Make compilation depend on generation
    exe.step.dependOn(&generate_step.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);
}
