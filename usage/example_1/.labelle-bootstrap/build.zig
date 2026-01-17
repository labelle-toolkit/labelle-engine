const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
    });

    // Get the generator executable from the engine
    const generator = engine_dep.artifact("labelle-generate");

    // Run step that executes the generator
    const run_generator = b.addRunArtifact(generator);
    run_generator.setCwd(b.path(".."));  // Run in project directory

    // Pass through any arguments
    if (b.args) |args| {
        run_generator.addArgs(args);
    }

    const run_step = b.step("run", "Run the generator");
    run_step.dependOn(&run_generator.step);
}
