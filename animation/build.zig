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
    const step = b.step("test", "Test animation independently of the engine");
    for ([_][]const u8{ "test/definition_test.zig", "test/marker_test.zig" }) |path| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "animation", .module = module }},
        }) });
        step.dependOn(&b.addRunArtifact(tests).step);
    }
}
