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

    // Backend-agnostic handle/POD types referenced from both the
    // engine module and the standalone `src/assets/` test root.
    // Promoted to named modules so loader.zig can `@import("audio_types")` /
    // `@import("font_types")` and resolve identically in both compilations.
    const audio_types_module = b.createModule(.{
        .root_source_file = b.path("src/audio_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const font_types_module = b.createModule(.{
        .root_source_file = b.path("src/font_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const engine_module = b.addModule("engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // src/preview_mode.zig needs libc for its raw `close`/`write`/`fcntl`
        // bindings — 0.16 dropped `std.posix.fcntl`/`std.posix.close` and
        // routed file IO through `std.Io.File` (which would force an
        // `io: std.Io` thread-through), so going straight to libc is the
        // smallest restoration. Downstream consumers inherit libc linkage
        // automatically because the engine module declares it here.
        .link_libc = true,
    });
    engine_module.addImport("labelle-core", core_module);
    engine_module.addImport("scene", scene_module);
    engine_module.addImport("jsonc", jsonc_module);
    engine_module.addImport("audio_types", audio_types_module);
    engine_module.addImport("font_types", font_types_module);

    // #547: src/preview_iosurface.zig declares `extern "c"` bindings
    // for IOSurface + CoreFoundation. Even when no caller exercises
    // those code paths, Zig's analyzer reaches the function bodies
    // (e.g. `Producer.deinit`) for every test binary that imports
    // `engine`, and the linker then refuses to leave those symbols
    // unresolved. Linking the system frameworks at the module level
    // satisfies every downstream test binary in one place; non-macOS
    // builds skip them and the macOS-only code is unreachable behind
    // a `builtin.os.tag == .macos` gate at every entry point.
    if (target.result.os.tag == .macos) {
        engine_module.linkFramework("IOSurface", .{});
        engine_module.linkFramework("CoreFoundation", .{});
    }

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
        "test/jsonc/bridge_leak_test.zig",
        "test/jsonc/nested_lifecycle_test.zig",
        "test/scene_ref_test.zig",
        "test/asset_catalog_test.zig",
        "test/audio_loader_test.zig",
        "test/font_types_test.zig",
        "test/font_loader_test.zig",
        "test/asset_streaming_shim_test.zig",
        "test/animation_def_test.zig",
        "test/sprite_animation_test.zig",
        "test/sprite_animation_tick_test.zig",
        "test/sprite_by_field_test.zig",
        "test/sprite_by_field_tick_test.zig",
        "test/scene_assets_hooks_test.zig",
        "test/pause_hook_test.zig",
        // #578 — `pub const Events` on the engine, dual-emit through
        // the buffered event path so flows can listen to lifecycle
        // hooks as Event-node variants.
        "test/engine_events_test.zig",
        "test/spawn_from_prefab_test.zig",
        "test/jsonc/bridge_prefab_tags_test.zig",
        "test/save_load_two_phase_test.zig",
        "test/example_prefab_animation_walkthrough_test.zig",
        "test/jsonc/bridge_deserialize_test.zig",
        "test/jsonc/deserializer_test.zig",
        "test/jsonc/unified_format_test.zig",
        "test/jsonc_bridge_gizmo_visibility_test.zig",
        "test/collect_entities_test.zig",
        "test/set_sprite_flip_test.zig",
        // PIE viewport handshake (#543) — kept separate from
        // preview_mode_test.zig so the new coverage isn't gated on
        // that file's pre-existing 21-test subscription bug.
        "test/preview_handshake_test.zig",
        // PIE viewport frame stream (#544) — producer-side SHM
        // lifecycle + publishFrame. Companion to the handshake tests
        // above; spins up an in-test `preview_shm.Consumer` to read
        // back what the engine wrote.
        "test/preview_frame_stream_test.zig",
        // Backend-agnostic FrameCapture trait (#140 architecture rethink).
        // Validates the producer-side trait + publishFrame orchestration
        // without involving any real graphics backend — pure CPU mock.
        "test/preview_capture_test.zig",
        // preview_mode_test + flows_game_api_test: re-enabled after #543
        // fixed the variadic-`fcntl` ABI bug (declared non-variadic on
        // a function libc declares variadic — mismatched on
        // aarch64-darwin where variadic args go on the stack rather
        // than in registers). With std.c.fcntl (correctly variadic) in
        // src/preview_mode.zig, O_NONBLOCK actually lands on the FD,
        // pollSubscription's read can EAGAIN, and the 21 previously-
        // hanging subscription-flow tests run to completion.
        "test/preview_mode_test.zig",
        "test/flows_game_api_test.zig",
        // cli#229: `engine.requestedScene()` reads `LABELLE_SCENE` so
        // loading-scene controllers can honour `--scene=<name>` after
        // `assets.allReady` instead of racing the boot swap.
        "test/runtime_env_test.zig",
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

    // PIE viewport macOS IOSurface frame stream (#547). The test
    // binary itself is cross-platform — on non-macOS hosts every
    // `test` block early-returns — so we always wire it into the
    // step. On macOS we additionally link the system frameworks the
    // test uses to look up surfaces by ID and inspect pixels:
    //   - IOSurface for `IOSurfaceLookup`/`IOSurfaceLock`/etc.
    //   - CoreFoundation for `CFRelease` (and the property-dict
    //     helpers the producer side reaches through the engine module).
    //   - OpenGL is **not** required by these tests — they read
    //     pixels via `IOSurfaceGetBaseAddress` rather than going
    //     through `CGLTexImageIOSurface2D`. It's still listed in the
    //     ticket's "link these frameworks" callout for completeness
    //     and so a future test that does want GL interop doesn't
    //     have to re-touch build.zig.
    const iosurface_test_module = b.createModule(.{
        .root_source_file = b.path("test/preview_iosurface_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle-core", .module = core_module },
            .{ .name = "engine", .module = engine_module },
            .{ .name = "scene", .module = scene_module },
        },
    });
    if (target.result.os.tag == .macos) {
        iosurface_test_module.linkFramework("IOSurface", .{});
        iosurface_test_module.linkFramework("CoreFoundation", .{});
        iosurface_test_module.linkFramework("OpenGL", .{});
    }
    const iosurface_test = b.addTest(.{ .root_module = iosurface_test_module });
    test_step.dependOn(&b.addRunArtifact(iosurface_test).step);

    // In-source tests under `src/assets/` (catalog, worker, loader,
    // loaders/*) cannot be dragged into a `test/*` binary through the
    // cross-module `engine` import — Zig only discovers top-level
    // `test` blocks in files that belong to the **same** module as
    // the test binary's root. Rooting an extra test binary directly
    // at `src/assets/mod.zig` gives those files a module of their
    // own where `_ = @import("...")` chains actually cascade the
    // test blocks into the binary. Added as part of #440 while the
    // real image loader started writing its own in-source tests.
    const assets_tests_module = b.createModule(.{
        .root_source_file = b.path("src/assets/mod.zig"),
        .target = target,
        .optimize = optimize,
        // catalog.zig / worker.zig call `std.c.nanosleep`, which resolves to
        // an `extern "c"` decl — same libc-linkage requirement as the engine
        // module above. This standalone test binary doesn't go through the
        // `engine` import so it has to declare the link itself.
        .link_libc = true,
    });
    assets_tests_module.addImport("audio_types", audio_types_module);
    assets_tests_module.addImport("font_types", font_types_module);
    const assets_tests = b.addTest(.{ .root_module = assets_tests_module });
    test_step.dependOn(&b.addRunArtifact(assets_tests).step);

    // Issue #461 regression guard: the asset pipeline must compile
    // under `single_threaded = true` (WASM / emscripten default).
    // Historically `std.Thread.spawn` was unconditional and this
    // combination was a hard compile error on `main`, breaking every
    // downstream WASM build. A compile-only check here catches any
    // regression at `zig build test` time (the step it's wired to) —
    // no runtime needed because the point is the type-checker
    // reaching `std.Thread.spawn`.
    const assets_single_threaded_module = b.createModule(.{
        .root_source_file = b.path("src/assets/mod.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        .link_libc = true,
    });
    assets_single_threaded_module.addImport("audio_types", audio_types_module);
    assets_single_threaded_module.addImport("font_types", font_types_module);
    const assets_single_threaded = b.addTest(.{ .root_module = assets_single_threaded_module });
    test_step.dependOn(&assets_single_threaded.step);

    // zspec BDD specs — mirrors the `spec` step in labelle-pathfinding.
    // Uses zspec's own test runner; the spec files declare
    // `describe`-style nested structs rather than flat `test` blocks.
    // Wired into `test_step` as well so `zig build test` (what CI
    // runs) stays the single command that exercises everything.
    //
    // zspec is a `lazy` dependency: `b.lazyDependency` only resolves
    // (and fetches) it when a step that needs it is in the build graph,
    // so downstream consumers that just import the engine module never
    // pull this test-only dep. On the first run without the package in
    // cache it returns null and Zig re-invokes the build after fetching.
    if (b.lazyDependency("zspec", .{ .target = target, .optimize = optimize })) |zspec_dep| {
        const spec_module = b.createModule(.{
            .root_source_file = b.path("spec/spec_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
                .{ .name = "labelle-core", .module = core_module },
                .{ .name = "engine", .module = engine_module },
                .{ .name = "scene", .module = scene_module },
            },
        });
        const spec_tests = b.addTest(.{
            .root_module = spec_module,
            .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
        });
        const run_spec_tests = b.addRunArtifact(spec_tests);
        const spec_step = b.step("spec", "Run zspec BDD specs");
        spec_step.dependOn(&run_spec_tests.step);
        test_step.dependOn(&run_spec_tests.step);
    }
}
