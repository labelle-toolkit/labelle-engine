//! Save direction — serialises game state to a save file.
//!
//! Extracted verbatim from `save_load_mixin.zig`; behaviour is identical.
//! Provides `saveGameState`. Shared helpers (`entityToU64`,
//! `isRegistered`, `collectEntities`, `SAVE_VERSION`) live in `common.zig`
//! and are reached through `Common.<fn>` — this mixin instantiates the
//! common mixin against the same `Game`, the idiom `loop_mixin` uses.
//! The `writeJsonString` escape helper is save-only (the reader never
//! writes strings) so it stays private here.

const std = @import("std");
const io_helper = @import("../../io_helper.zig");
const core = @import("labelle-core");
const serde = core.serde;
const common = @import("common.zig");

const SAVE_VERSION = common.SAVE_VERSION;

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Reg = Game.ComponentRegistry;
    const Common = common.Mixin(Game);

    return struct {
        /// Write a JSON-escaped string literal (including surrounding
        /// quotes) to `writer`. Used by the built-in save pathway for
        /// components with `[]const u8` fields (PrefabInstance.path,
        /// PrefabInstance.overrides, PrefabChild.local_path) — serde's
        /// `writeComponent` doesn't support string slices, so the save
        /// mixin handles these components as built-ins and needs its
        /// own escape helper.
        fn writeJsonString(writer: anytype, s: []const u8) !void {
            try writer.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0x08 => try writer.writeAll("\\b"),
                    0x0c => try writer.writeAll("\\f"),
                    0...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        }

        // ─── Save ───────────────────────────────────────────────────

        pub fn saveGameState(self: *Game, filename: []const u8) !void {
            @setEvalBranchQuota(10000);
            const allocator = self.allocator;
            const names = comptime Reg.names();

            // Collect all entities with saveable or marker components
            var entity_set = std.AutoHashMap(u64, void).init(allocator);
            defer entity_set.deinit();
            var entity_list: std.ArrayList(u64) = .empty;
            defer entity_list.deinit(allocator);

            inline for (names) |name| {
                const T = Reg.getType(name);
                if (comptime core.getSavePolicy(T)) |policy| {
                    if (policy == .saveable or policy == .marker) {
                        var entities = try Common.collectEntities(T, &self.active_world.ecs_backend, allocator);
                        defer entities.deinit(allocator);
                        for (entities.items) |entity| {
                            const id = Common.entityToU64(entity);
                            if (!entity_set.contains(id)) {
                                try entity_set.put(id, {});
                                try entity_list.append(allocator, id);
                            }
                        }
                    }
                }
            }

            // Auto-collect prefab-tagged entities regardless of whether
            // they carry any game-owned saveable / marker component.
            //
            // Why: a "pure visual" prefab — e.g. a background
            // prefab whose root declares only `Sprite` + the engine's
            // auto-attached `PrefabInstance` — would otherwise be
            // skipped by the registry-driven sweep above (no entry
            // in `Reg.names()` carries it), silently miss from the
            // save file, and never respawn on load. The prefab is
            // gone even though Phase 1 would have perfectly
            // reconstructed it from its `path`. Flagged in
            // `Game.spawnFromPrefab`'s docstring as a "authors need
            // at least one saveable or marker component" limitation;
            // this sweep removes that limitation.
            //
            // Collects both tag types:
            //
            // * `PrefabInstance` — ensures every prefab root survives
            //   save/load regardless of other components.
            //
            // * `PrefabChild` — usually redundant (most prefab
            //   descendants carry game-owned saveables that got them
            //   collected already), but catches the edge case where a
            //   prefab-declared child has no game state at all and is
            //   referenced by another saved entity via its entity ID.
            //   Phase 1b's `(root, local_path)` remap can't populate
            //   `id_map` without the child's saved entry, so saving
            //   it is what keeps the ref-remap working.
            //
            // The registry-identity guard (`isRegistered`) that the
            // write-side uses for these built-ins doesn't apply here
            // — even if a game registers `PrefabInstance` / `PrefabChild`
            // in its own registry, the entity-presence sweep is
            // idempotent with the registry-driven one above (both
            // funnel through the same `entity_set` dedup).
            inline for (.{ Game.PrefabInstanceComp, Game.PrefabChildComp }) |Tag| {
                var view = self.active_world.ecs_backend.view(.{Tag}, .{});
                defer view.deinit();
                while (view.next()) |entity| {
                    const id = Common.entityToU64(entity);
                    if (!entity_set.contains(id)) {
                        try entity_set.put(id, {});
                        try entity_list.append(allocator, id);
                    }
                }
            }

            // Auto-collect Tilemap entities (T2 Phase 2). Same rationale as
            // the prefab-tag sweep above: the built-in `Tilemap` carries no
            // registry component, so a tilemap-only entity would otherwise
            // be missed by the registry-driven sweep and silently dropped
            // from the save. Skipped when a game registers `Tilemap` in its
            // own `ComponentRegistry` (then the registry sweep collected it).
            if (comptime !Common.isRegistered(Game.TilemapComp)) {
                var tm_view = self.active_world.ecs_backend.view(.{Game.TilemapComp}, .{});
                defer tm_view.deinit();
                while (tm_view.next()) |entity| {
                    const id = Common.entityToU64(entity);
                    if (!entity_set.contains(id)) {
                        try entity_set.put(id, {});
                        try entity_list.append(allocator, id);
                    }
                }
            }

            var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
            defer alloc_writer.deinit();
            const writer = &alloc_writer.writer;

            try writer.print("{{\n  \"version\": {d},\n", .{SAVE_VERSION});

            // Record the active scene name so `loadGameState` can
            // re-acquire and bind THAT scene's atlas manifest through the
            // deterministic catalog gate — even when the load is issued
            // from a different scene (the menu→Load case, where
            // `current_scene_name` is still "menu" at load time). Without
            // this the loader has no way to know which atlas packs the
            // restored colony references, which is exactly why
            // flying-platform shipped a manual `assets.acquire(...)` loop
            // in its Load handler (FP#542). Optional + back-compat: older
            // saves simply omit the key and `loadGameState` falls back to
            // the current scene's manifest (the pre-#638 behaviour).
            if (self.current_scene_name) |scene_name| {
                try writer.writeAll("  \"scene\": ");
                try writeJsonString(writer, scene_name);
                try writer.writeAll(",\n");
            }

            try writer.writeAll("  \"entities\": [\n");

            for (entity_list.items, 0..) |id, idx| {
                const entity: Entity = @intCast(id);

                if (idx > 0) try writer.writeAll(",\n");
                try writer.writeAll("    {\n");
                try writer.print("      \"id\": {d}", .{id});

                // Components (saveable + marker from registry + built-in Position)
                try writer.writeAll(",\n      \"components\": {");
                var first_comp = true;

                // Save Position (built-in) — only if not already in the component registry
                const Position = core.Position;
                if (comptime !Common.isRegistered(Position)) {
                    const pos = self.getPosition(entity);
                    if (!first_comp) try writer.writeAll(",");
                    try writer.writeAll("\n        \"Position\": {\"x\": ");
                    try writer.print("{d}", .{pos.x});
                    try writer.writeAll(", \"y\": ");
                    try writer.print("{d}", .{pos.y});
                    try writer.writeAll("}");
                    first_comp = false;
                }

                // Save Parent (built-in). Games don't register the
                // engine's `ParentComponent` in their ComponentRegistry
                // (it's generic over Entity + used internally by
                // `setParent`), but the save mixin needs to persist it
                // so prefab hierarchies survive save/load — otherwise
                // every child-with-Position drifts to scene origin
                // after load (see labelle-core #11).
                //
                // Guarded by a type-identity check: if a game does
                // register the engine's `ParentComponent` directly in
                // its ComponentRegistry, the registry-driven save/load
                // path already handles it and writing the built-in
                // block on top would produce duplicate JSON keys.
                // Mirrors Position's `has_position_in_registry`.
                // Note: this does NOT protect against a game defining
                // a *different* component whose serde name happens to
                // be "Parent" — that would still collide. Deliberately
                // scoped to the common case (same type) for now.
                const Parent = Game.ParentComp;
                if (comptime !Common.isRegistered(Parent)) {
                    if (self.active_world.ecs_backend.getComponent(entity, Parent)) |parent| {
                        if (!first_comp) try writer.writeAll(",");
                        try writer.writeAll("\n        \"Parent\": {\"entity\": ");
                        try writer.print("{d}", .{Common.entityToU64(parent.entity)});
                        try writer.writeAll(", \"inherit_rotation\": ");
                        try writer.writeAll(if (parent.inherit_rotation) "true" else "false");
                        try writer.writeAll(", \"inherit_scale\": ");
                        try writer.writeAll(if (parent.inherit_scale) "true" else "false");
                        try writer.writeAll("}");
                        first_comp = false;
                    }
                }

                // Save PrefabInstance (built-in) — attached by
                // `spawnFromPrefab` to prefab-root entities so save/load
                // Phase 1 can re-instantiate the prefab and bring back
                // non-saveable components (Sprite, animation overlays)
                // on load. Path + overrides-blob are both `[]const u8`,
                // which serde.writeComponent can't round-trip, so
                // PrefabInstance lives in the built-in channel alongside
                // Position and Parent. Same registry-identity guard so
                // a game registering the type in its ComponentRegistry
                // doesn't produce duplicate JSON keys.
                const PrefabInstance = Game.PrefabInstanceComp;
                if (comptime !Common.isRegistered(PrefabInstance)) {
                    if (self.active_world.ecs_backend.getComponent(entity, PrefabInstance)) |pi| {
                        if (!first_comp) try writer.writeAll(",");
                        try writer.writeAll("\n        \"PrefabInstance\": {\"path\": ");
                        try writeJsonString(writer, pi.path);
                        try writer.writeAll(", \"overrides\": ");
                        try writeJsonString(writer, pi.overrides);
                        try writer.writeAll("}");
                        first_comp = false;
                    }
                }

                // Save PrefabChild (built-in) — attached by
                // `spawnFromPrefab` to every child entity created as
                // part of a prefab instantiation. `root` points back
                // at the PrefabInstance entity; serialised as u64 and
                // remapped through the load `id_map` so lineage
                // survives entity-ID reassignment (same pattern
                // Parent.entity uses).
                const PrefabChildT = Game.PrefabChildComp;
                if (comptime !Common.isRegistered(PrefabChildT)) {
                    if (self.active_world.ecs_backend.getComponent(entity, PrefabChildT)) |pc| {
                        if (!first_comp) try writer.writeAll(",");
                        try writer.writeAll("\n        \"PrefabChild\": {\"root\": ");
                        try writer.print("{d}", .{Common.entityToU64(pc.root)});
                        try writer.writeAll(", \"local_path\": ");
                        try writeJsonString(writer, pc.local_path);
                        try writer.writeAll("}");
                        first_comp = false;
                    }
                }

                // Save Tilemap (built-in, T2 Phase 2). `asset_name` is a
                // `[]const u8` (serde can't round-trip it — same reason
                // PrefabInstance lives here), and T2 tilemaps are immutable
                // (deterministic from the asset), so ONLY the asset
                // reference persists — the decoded map is never saved.
                // Same registry-identity guard as the other built-ins.
                const TilemapT = Game.TilemapComp;
                if (comptime !Common.isRegistered(TilemapT)) {
                    if (self.active_world.ecs_backend.getComponent(entity, TilemapT)) |tm| {
                        if (!first_comp) try writer.writeAll(",");
                        try writer.writeAll("\n        \"Tilemap\": {\"asset_name\": ");
                        try writeJsonString(writer, tm.asset_name);
                        try writer.writeAll("}");
                        first_comp = false;
                    }
                }

                inline for (names) |name| {
                    const T = Reg.getType(name);
                    if (comptime core.getSavePolicy(T)) |policy| {
                        if (policy == .saveable or policy == .marker) {
                            if (self.active_world.ecs_backend.getComponent(entity, T)) |comp| {
                                if (!first_comp) try writer.writeAll(",");
                                try writer.writeAll("\n        \"");
                                try writer.writeAll(comptime serde.componentName(T));
                                try writer.writeAll("\": ");
                                try serde.writeComponent(T, comp, writer, serde.autoSkipField);
                                first_comp = false;
                            }
                        }
                    }
                }
                try writer.writeAll("\n      }");

                // Ref arrays — collect all ref array fields across components into one JSON object
                var has_ref_arrays = false;
                inline for (names) |name| {
                    const T = Reg.getType(name);
                    if (comptime core.getSavePolicy(T)) |policy| {
                        if ((policy == .saveable or policy == .marker) and comptime serde.hasRefArrayFields(T)) {
                            if (self.active_world.ecs_backend.getComponent(entity, T)) |comp| {
                                if (!has_ref_arrays) {
                                    try writer.writeAll(",\n      \"ref_arrays\": {");
                                    has_ref_arrays = true;
                                } else {
                                    try writer.writeAll(",");
                                }
                                try serde.writeRefArrayFields(T, comp, writer);
                            }
                        }
                    }
                }
                if (has_ref_arrays) {
                    try writer.writeAll("}");
                }

                try writer.writeAll("\n    }");
            }

            try writer.writeAll("\n  ]\n}\n");

            const _io = io_helper.io();
            // `buffered()` reads the not-yet-drained bytes without
            // transferring ownership — `defer alloc_writer.deinit()`
            // above is responsible for freeing the buffer.
            try std.Io.Dir.cwd().writeFile(_io, .{ .sub_path = filename, .data = alloc_writer.writer.buffered() });
        }
    };
}
