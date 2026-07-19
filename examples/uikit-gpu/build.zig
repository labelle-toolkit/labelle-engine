const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Core / gfx / engine (unified onto ONE labelle-core to avoid a
    //    diamond version mismatch — same overrideImport dance the assembler
    //    emits in a generated build.zig). ────────────────────────────────
    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    const gfx_dep = b.dependency("labelle_gfx", .{ .target = target, .optimize = optimize });
    const gfx_mod = gfx_dep.module("labelle-gfx");

    const engine_dep = b.dependency("engine", .{ .target = target, .optimize = optimize });
    const engine_mod = engine_dep.module("engine");

    overrideImport(gfx_mod, "labelle-core", core_mod);
    overrideImport(engine_mod, "labelle-core", core_mod);
    overrideImport(engine_mod, "labelle-gfx", gfx_mod);

    // In a flat sibling checkout every package fetches its OWN labelle-core
    // tarball (the assembler avoids this by staging a single core), so unify
    // core onto gfx's sub-packages too — `camera.CameraWith(.., y_axis)` takes
    // a core `YAxis` and would otherwise see two distinct enum instances.
    for ([_][]const u8{ "camera", "tilemap", "spatial_grid" }) |sub| {
        if (gfx_mod.import_table.get(sub)) |m| overrideImport(m, "labelle-core", core_mod);
    }
    // Same for the engine's sub-packages that cross core types.
    for ([_][]const u8{ "scene", "jsonc", "audio_types", "font_types", "labelle-gfx" }) |sub| {
        if (engine_mod.import_table.get(sub)) |m| overrideImport(m, "labelle-core", core_mod);
    }

    // ── sokol backend modules (raw gfx/input/audio/window + sokol_clib) ──
    const backend_dep = b.dependency("labelle_sokol", .{
        .target = target,
        .optimize = optimize,
        .with_imgui = false,
        .gamepad_enabled = true,
        .gamepad_hidapi = false,
    });
    const backend_gfx = backend_dep.module("gfx");
    const backend_input = backend_dep.module("input");
    const backend_audio = backend_dep.module("audio");
    const backend_window = backend_dep.module("window");
    const sokol_clib = backend_dep.artifact("sokol_clib");

    // Unify the app core onto the backend's transitive gamepad source (same
    // guards as the generated build — the import only exists on some targets).
    if (backend_input.import_table.get("sdl_gamepad")) |sdl_gp_mod| {
        overrideImport(sdl_gp_mod, "labelle_core", core_mod);
    }
    if (backend_input.import_table.get("labelle-core")) |_| {
        overrideImport(backend_input, "labelle-core", core_mod);
    }

    // ── ui_kit (labelle-gui#215) — the in-game UI kit producing the
    //    DrawList. labelle-gui does not export it as a build module, and it
    //    is dependency-free (redeclares the labelle-core extern glyph structs
    //    rather than importing them), so we point a fresh module straight at
    //    its `mod.zig`; its sibling @imports resolve on disk. ─────────────
    const ui_kit_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "../../../labelle-gui/src/ui_kit/mod.zig" },
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "uikit-gpu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
                .{ .name = "labelle-gfx", .module = gfx_mod },
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "backend_gfx", .module = backend_gfx },
                .{ .name = "backend_input", .module = backend_input },
                .{ .name = "backend_audio", .module = backend_audio },
                .{ .name = "backend_window", .module = backend_window },
                .{ .name = "ui_kit", .module = ui_kit_mod },
            },
        }),
    });
    exe.root_module.linkLibrary(sokol_clib);

    // macOS: the engine's IOSurface preview producer + sokol Metal path need
    // these frameworks (sokol's linker line doesn't propagate them).
    switch (target.result.os.tag) {
        .macos, .ios => {
            exe.root_module.linkFramework("IOSurface", .{});
            exe.root_module.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the on-GPU UI-kit demo");
    run_step.dependOn(&run_cmd.step);
}

/// Override a module import without leaking the old key (Zig's addImport dupes
/// the name). Verbatim from the assembler's generated build.zig.
fn overrideImport(m: *std.Build.Module, name: []const u8, module: *std.Build.Module) void {
    const gop = m.import_table.getOrPut(m.owner.allocator, name) catch @panic("OOM");
    if (!gop.found_existing) gop.key_ptr.* = name;
    gop.value_ptr.* = module;
}
