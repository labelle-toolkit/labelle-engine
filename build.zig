const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_module = core_dep.module("labelle-core");

    const scene_dep = b.dependency("scene", .{ .target = target, .optimize = optimize });
    const scene_module = scene_dep.module("scene");

    const jsonc_dep = b.dependency("jsonc", .{ .target = target, .optimize = optimize });
    const jsonc_module = jsonc_dep.module("jsonc");

    const engine_module = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine_module.addImport("labelle-core", core_module);
    engine_module.addImport("scene", scene_module);
    engine_module.addImport("jsonc", jsonc_module);

    const test_step = b.step("test", "Run engine tests");

    // Test files in test/ directory
    const test_files = [_][]const u8{
        "test/root_test.zig",
        "test/scene_test.zig",
        "test/gestures_test.zig",
        "test/sparse_set_test.zig",
        "test/query_test.zig",
        "test/gui_view_test.zig",
        "test/animation_atlas_test.zig",
        "test/gui_runtime_state_test.zig",
        "test/form_binder_test.zig",
        "test/script_runner_test.zig",
        "test/game_log_test.zig",
        "test/save_policy_test.zig",
        "test/save_load_mixin_test.zig",
    };

    for (test_files) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "labelle-core", .module = core_module },
                    .{ .name = "engine", .module = engine_module },
                    .{ .name = "scene", .module = scene_module },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
