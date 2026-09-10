const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const jsonc = b.dependency("jsonc", .{ .target = target, .optimize = optimize }).module("jsonc");
    const module = b.addModule("animation", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jsonc", .module = jsonc }},
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/definition_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "animation", .module = module }},
    }) });
    b.step("test", "Test animation definitions independently of the engine").dependOn(&b.addRunArtifact(tests).step);
}
