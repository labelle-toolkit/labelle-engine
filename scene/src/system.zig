/// SystemRegistry — auto-discovers and dispatches plugin systems at comptime.
///
/// Mirrors ComponentRegistryWithPlugins: plugins export `pub const Systems`
/// with lifecycle functions that the engine calls at the right phase.
///
/// Plugin system convention:
///   pub const Systems = struct {
///       pub const game_states = .{ "playing" };  // optional — omit to run in all states
///       pub fn setup(game: anytype) void { ... }
///       pub fn tick(game: anytype, dt: f32) void { ... }
///       pub fn postTick(game: anytype, dt: f32) void { ... }
///       pub fn drawGui(game: anytype) void { ... }
///       pub fn renderMeshes(game: anytype) void { ... }
///       pub fn deinit() void { ... }
///   };
///
/// All functions are optional — only declare what you need.
/// game_states is optional — omit to run in all states. The game's
/// project.labelle can override this with per-plugin `.states`.
///
/// Usage (in generated main.zig):
///   const PluginSystems = engine.SystemRegistry(.{
///       @import("box2d"),
///       @import("labelle-gfx"),
///   });
///   // In setup:  PluginSystems.setup(&g);
///   // In tick:   PluginSystems.tick(&g, dt);
///   // In render: PluginSystems.drawGui(&g);

pub fn SystemRegistry(comptime plugin_modules: anytype) type {
    const info = @typeInfo(@TypeOf(plugin_modules));

    return struct {
        const std = @import("std");
        const std_time = std.time;
        const builtin = @import("builtin");
        const profiler = @import("profiler.zig");
        // Compiled into every build (incl. ReleaseFast); recording is gated
        // at runtime by `profiler.recording()` (`LABELLE_PROFILE`). Public
        // because the generated `main.zig` reads it to expose the array.
        pub const profiling_enabled = true;

        /// Plugin system timing (tick + postTick), rolling over the dump
        /// window. Exposed via `Game.plugin_profile_ptr` for the live
        /// inspector overlay (#380). Aliases the shared `profiler.PluginRow`
        /// so `Game`'s opaque pointer casts back to a stable layout.
        pub const PluginProfileEntry = profiler.PluginRow;
        /// Frames since the last profiler log dump (advances only while recording).
        var prof_frame_counter: u64 = 0;

        pub const plugin_system_count: usize = countPluginSystems();

        fn countPluginSystems() usize {
            comptime {
                var count: usize = 0;
                for (info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "Systems")) count += 1;
                }
                return count;
            }
        }

        /// Per-plugin timing data (updated each frame).
        pub var plugin_profile: [plugin_system_count]PluginProfileEntry = initPluginProfile();

        fn initPluginProfile() [plugin_system_count]PluginProfileEntry {
            comptime {
                var entries: [plugin_system_count]PluginProfileEntry = undefined;
                var idx: usize = 0;
                for (info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "Systems")) {
                        entries[idx] = .{ .name = field.name };
                        idx += 1;
                    }
                }
                return entries;
            }
        }

        /// Call setup() on all plugin systems that declare it.
        pub fn setup(game: anytype) void {
            comptime var pidx: usize = 0;
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "setup")) {
                        // Unconditionally timed (one-shot at boot; the
                        // inspector can't have enabled capture yet) so
                        // boot cost is always visible in the overlay.
                        const t0 = profiler.nowNs();
                        Sys.setup(game);
                        plugin_profile[pidx].setup.record(profiler.nowNs() - t0);
                    }
                    pidx += 1;
                }
            }
        }

        /// Call tick() on all plugin systems that declare it.
        /// Respects game_states — skips plugins not active in the current state.
        pub fn tick(game: anytype, dt: f32) void {
            const current_state = getGameState(game);
            const rec = profiler.recording();
            comptime var pidx: usize = 0;
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "tick")) {
                        if (isStateAllowed(Sys, current_state)) {
                            if (rec) {
                                const t0 = profiler.nowNs();
                                Sys.tick(game, dt);
                                plugin_profile[pidx].tick.record(profiler.nowNs() - t0);
                            } else {
                                Sys.tick(game, dt);
                            }
                        }
                    }
                    pidx += 1;
                }
            }
            // tick() runs once per frame before postTick(): drive the dump here.
            if (rec) {
                prof_frame_counter += 1;
                if (prof_frame_counter >= profiler.dump_interval_frames) {
                    dumpProfile();
                    prof_frame_counter = 0;
                }
            }
        }

        /// Log a worst-first ranking of per-plugin tick times over the
        /// window, then reset. Called from `tick` while recording.
        fn dumpProfile() void {
            var rows: [plugin_system_count]profiler.Row = undefined;
            for (&plugin_profile, 0..) |*e, i| {
                rows[i] = .{ .name = e.name, .worst_ns = e.tick.worst_ns, .avg_ns = e.tick.avgNs() };
                e.tick.resetWindow();
                e.post_tick.resetWindow();
                e.draw_gui.resetWindow();
                // `setup` is deliberately NOT reset: one-shot boot cost.
            }
            profiler.report("plugin", &rows);
        }

        /// Call postTick() on all plugin systems that declare it.
        pub fn postTick(game: anytype, dt: f32) void {
            const current_state = getGameState(game);
            const rec = profiler.recording();
            comptime var pidx: usize = 0;
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "postTick")) {
                        if (isStateAllowed(Sys, current_state)) {
                            if (rec) {
                                const t0 = profiler.nowNs();
                                Sys.postTick(game, dt);
                                plugin_profile[pidx].post_tick.record(profiler.nowNs() - t0);
                            } else {
                                Sys.postTick(game, dt);
                            }
                        }
                    }
                    pidx += 1;
                }
            }
        }

        /// Call drawGui() on all plugin systems that declare it.
        pub fn drawGui(game: anytype) void {
            const current_state = getGameState(game);
            const rec = profiler.recording();
            comptime var pidx: usize = 0;
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "drawGui")) {
                        if (isStateAllowed(Sys, current_state)) {
                            if (rec) {
                                const t0 = profiler.nowNs();
                                Sys.drawGui(game);
                                plugin_profile[pidx].draw_gui.record(profiler.nowNs() - t0);
                            } else {
                                Sys.drawGui(game);
                            }
                        }
                    }
                    pidx += 1;
                }
            }
        }

        /// Call renderMeshes() on all plugin systems that declare it — the
        /// render-phase custom-mesh seam (labelle-gfx#290 Stage 4). Invoked
        /// during the render phase AFTER the world sprite pass (`g.render()`),
        /// so plugin-submitted textured meshes composite over sprites; a
        /// plugin's callback iterates its own components and calls
        /// `game.drawMesh(...)` (see `mesh_mixin`). This is the immediate
        /// sibling of `drawGui` for world-space textured geometry — e.g. the
        /// future `labelle-spine` plugin's `SpineSkeleton` system submits its
        /// per-frame skinned meshes here.
        ///
        /// Respects game_states like the other lifecycle phases, and is
        /// zero-cost when no plugin declares `renderMeshes` (the `@hasDecl`
        /// branch folds away at comptime, leaving an empty `inline for`).
        pub fn renderMeshes(game: anytype) void {
            const current_state = getGameState(game);
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "renderMeshes")) {
                        if (isStateAllowed(Sys, current_state)) {
                            Sys.renderMeshes(game);
                        }
                    }
                }
            }
        }

        /// Check if a plugin's Systems is allowed to run in the current game state.
        /// Plugins without game_states run in all states.
        fn isStateAllowed(comptime Sys: type, state: ?[]const u8) bool {
            if (!@hasDecl(Sys, "game_states")) return true;
            const game_state = state orelse return true;
            const states = Sys.game_states;
            inline for (states) |s| {
                if (std.mem.eql(u8, s, game_state)) return true;
            }
            return false;
        }

        /// Query the game for its current state string.
        fn getGameState(game: anytype) ?[]const u8 {
            const GameType = @TypeOf(game);
            const Inner = if (@typeInfo(GameType) == .pointer) @typeInfo(GameType).pointer.child else GameType;
            if (@hasDecl(Inner, "getState")) {
                return game.getState();
            }
            return null;
        }

        /// Call deinit() on all plugin systems in reverse order (mirrors setup).
        pub fn deinit() void {
            const fields = info.@"struct".fields;
            comptime var i: usize = fields.len;
            inline while (i > 0) {
                i -= 1;
                const mod = @field(plugin_modules, fields[i].name);
                if (@hasDecl(mod, "Systems")) {
                    const Sys = @field(mod, "Systems");
                    if (@hasDecl(Sys, "deinit")) {
                        Sys.deinit();
                    }
                }
            }
        }

        /// Returns true if any plugin module exports a Systems declaration.
        pub fn hasSystems() bool {
            inline for (info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Systems")) return true;
            }
            return false;
        }

        /// Gizmo category entry — name + index, discovered from plugins.
        pub const GizmoCategoryEntry = struct {
            name: []const u8,
            id: u8,
        };

        /// Number of gizmo categories across all plugins.
        pub const gizmo_category_count: usize = countGizmoCategories();

        fn countGizmoCategories() usize {
            comptime {
                var count: usize = 0;
                for (info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "GizmoCategories")) {
                        for (@typeInfo(@field(mod, "GizmoCategories")).@"struct".decls) |_| {
                            count += 1;
                        }
                    }
                }
                return count;
            }
        }

        /// Collect all gizmo categories from plugins that export GizmoCategories.
        pub fn gizmoCategories() [gizmo_category_count]GizmoCategoryEntry {
            comptime {
                var entries: [gizmo_category_count]GizmoCategoryEntry = undefined;
                var idx: usize = 0;
                for (info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "GizmoCategories")) {
                        const Cats = @field(mod, "GizmoCategories");
                        for (@typeInfo(Cats).@"struct".decls) |decl| {
                            entries[idx] = .{
                                .name = decl.name,
                                .id = @field(Cats, decl.name),
                            };
                            idx += 1;
                        }
                    }
                }
                return entries;
            }
        }
    };
}
