const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const jsonc = b.dependency("jsonc", .{ .target = target, .optimize = optimize }).module("jsonc");
    const core = b.dependency("labelle_core", .{ .target = target, .optimize = optimize }).module("labelle-core");
    const module = b.addModule("animation", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "jsonc", .module = jsonc }, .{ .name = "labelle-core", .module = core } },
    });
    const step = b.step("test", "Test animation independently of the engine");
    for ([_][]const u8{ "test/definition_test.zig", "test/marker_test.zig", "test/anim_timing_test.zig", "test/animation_def_test.zig", "test/animation_def_runtime_test.zig", "test/animation_state_transitions_test.zig", "test/animation_events_test.zig", "test/sprite_animation_test.zig", "test/sprite_by_field_test.zig" }) |path| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "animation", .module = module }, .{ .name = "labelle-core", .module = core } },
        }) });
        step.dependOn(&b.addRunArtifact(tests).step);
    }
}
