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
        "test/jsonc_bridge_leak_test.zig",
        "test/scene_ref_test.zig",
        "test/asset_catalog_test.zig",
        "test/animation_def_test.zig",
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

    // In-source tests under `src/assets/` (catalog, worker, loader,
    // loaders/*) cannot be dragged into a `test/*` binary through the
    // cross-module `engine` import — Zig only discovers top-level
    // `test` blocks in files that belong to the **same** module as
    // the test binary's root. Rooting an extra test binary directly
    // at `src/assets/mod.zig` gives those files a module of their
    // own where `_ = @import("...")` chains actually cascade the
    // test blocks into the binary. Added as part of #440 while the
    // real image loader started writing its own in-source tests.
    const assets_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/assets/mod.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(assets_tests).step);
}
