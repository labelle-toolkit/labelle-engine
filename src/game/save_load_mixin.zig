//! Save/Load mixin — generic game state serialization.
//!
//! Provides saveGameState/loadGameState methods on the Game struct.
//! Component save behavior is declared via Saveable(...) in labelle-core.
//! No game-specific code — works with any component registry.

const std = @import("std");
const core = @import("labelle-core");
const serde = core.serde;

const SAVE_VERSION: u32 = 2;
const MAX_SAVE_SIZE = 256 * 1024 * 1024; // 256 MB

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Reg = Game.ComponentRegistry;

    return struct {
        fn entityToU64(entity: Entity) u64 {
            return @intCast(entity);
        }

        /// `true` when `T` is registered in the game's
        /// `ComponentRegistry`. The built-in save/load channel for
        /// engine-defined components (`Position`, `Parent`,
        /// `PrefabInstance`, `PrefabChild`) guards on the negation
        /// of this so a game that decides to register one of them
        /// directly doesn't end up with duplicate JSON keys (the
        /// registry-driven path would also emit that component).
        fn isRegistered(comptime T: type) bool {
            const names = comptime Reg.names();
            inline for (names) |name| {
                if (Reg.getType(name) == T) return true;
            }
            return false;
        }

        /// Read a boolean field out of a serialised Parent object,
        /// defaulting to `false` for missing / non-bool values. Kept
        /// local so the save and load sides of the built-in Parent
        /// pathway stay symmetric and the call sites don't repeat the
        /// `switch (v) { .bool => ... }` boilerplate.
        fn parentFlag(parent_obj: std.json.ObjectMap, field: []const u8) bool {
            const v = parent_obj.get(field) orelse return false;
            return switch (v) {
                .bool => |b| b,
                else => false,
            };
        }

        /// Safe JSON accessors for the load path. All return `null`
        /// on a tag mismatch rather than panicking via `.object` /
        /// `.integer` tag casts — so a malformed save file (wrong
        /// type, missing field, `null` where an object is expected)
        /// produces a logged warning and a skipped entity, not a
        /// debug-assertion panic or release-mode memory corruption.
        fn getComponentsObject(entry: std.json.Value) ?std.json.ObjectMap {
            if (entry != .object) return null;
            const comps_val = entry.object.get("components") orelse return null;
            return switch (comps_val) {
                .object => |o| o,
                else => null,
            };
        }

        fn getObjectField(obj: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
            const v = obj.get(name) orelse return null;
            return switch (v) {
                .object => |o| o,
                else => null,
            };
        }

        fn getStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
            const v = obj.get(name) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        }

        /// Read a non-negative integer field as `u64` (for entity IDs).
        /// Clamps negative and out-of-range values to `null` so the
        /// caller's `orelse continue` pattern gracefully drops malformed
        /// entries.
        fn getU64Field(obj: std.json.ObjectMap, name: []const u8) ?u64 {
            const v = obj.get(name) orelse return null;
            return switch (v) {
                .integer => |i| if (i >= 0) @intCast(i) else null,
                else => null,
            };
        }

        /// Read the top-level `id` of a save entry as `u64`. Missing
        /// or non-integer `id` fields return `null` so the caller can
        /// skip the entry instead of panicking.
        fn getSavedId(entry: std.json.Value) ?u64 {
            if (entry != .object) return null;
            return getU64Field(entry.object, "id");
        }

        /// Read a numeric field as `f32`, accepting both `.float` and
        /// `.integer` JSON tags; returns 0 for missing or non-numeric
        /// values. Used for the Position shim in Phase 1a.
        fn getNumberField(obj: std.json.ObjectMap, name: []const u8) f32 {
            const v = obj.get(name) orelse return 0;
            return switch (v) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => 0,
            };
        }

        /// Walk a dotted `children[i]...` path from `root` through
        /// `game.getChildren`, returning the entity at the end or
        /// `null` when the path doesn't resolve (missing index,
        /// malformed syntax, root has no children, etc.). Matches the
        /// path format `spawnFromPrefab` (and the scene-bridge
        /// auto-tagger) emit, so save/load Phase 1 can find the
        /// re-spawned child that corresponds to each saved PrefabChild.
        fn findChildByLocalPath(self: *Game, root: Entity, local_path: []const u8) ?Entity {
            // Empty path is not valid — `PrefabChild.local_path` is always
            // at least `"children[0]"` when a child was legitimately
            // emitted. An empty string on the saved side indicates a
            // corrupted save, and resolving it to `root` would alias the
            // child's ID onto the root entity in `id_map`, causing Phase 2
            // to apply the child's components on top of the root. Return
            // null so the caller's `orelse` path logs + skips instead.
            if (local_path.len == 0) return null;

            var current: Entity = root;
            var rest = local_path;
            while (rest.len > 0) {
                if (rest[0] == '.') rest = rest[1..];
                const prefix = "children[";
                if (!std.mem.startsWith(u8, rest, prefix)) return null;
                rest = rest[prefix.len..];
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
                const idx = std.fmt.parseInt(usize, rest[0..close], 10) catch return null;
                rest = rest[close + 1 ..];

                const children = self.getChildren(current);
                if (idx >= children.len) return null;
                current = children[idx];
            }
            return current;
        }

        /// Recursively insert `root` and every descendant into `set`.
        /// Used by Phase 1a to record which entities came in through
        /// `spawnFromPrefab` (and were therefore renderer-tracked by
        /// the prefab spawn path) so Step 5 can skip re-tracking them.
        fn markSubtreeRendererTracked(
            self: *Game,
            root: Entity,
            set: *std.AutoHashMap(u64, void),
        ) !void {
            try set.put(entityToU64(root), {});
            for (self.getChildren(root)) |child| {
                try markSubtreeRendererTracked(self, child, set);
            }
        }

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
                    0...0x07, 0x0b, 0x0e...0x1f => try std.fmt.format(writer, "\\u{x:0>4}", .{c}),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        }

        /// Collect entities from a view into an ArrayList, closing the view after.
        fn collectEntities(comptime T: type, ecs: anytype, allocator: std.mem.Allocator) !std.ArrayList(Entity) {
            var buf: std.ArrayList(Entity) = .{};
            errdefer buf.deinit(allocator);
            var view = ecs.view(.{T}, .{});
            defer view.deinit();
            while (view.next()) |ent| {
                try buf.append(allocator, ent);
            }
            return buf;
        }

        // ─── Save ───────────────────────────────────────────────────

        pub fn saveGameState(self: *Game, filename: []const u8) !void {
            @setEvalBranchQuota(10000);
            const allocator = self.allocator;
            const names = comptime Reg.names();

            // Collect all entities with saveable or marker components
            var entity_set = std.AutoHashMap(u64, void).init(allocator);
            defer entity_set.deinit();
            var entity_list: std.ArrayList(u64) = .{};
            defer entity_list.deinit(allocator);

            inline for (names) |name| {
                const T = Reg.getType(name);
                if (comptime core.getSavePolicy(T)) |policy| {
                    if (policy == .saveable or policy == .marker) {
                        var entities = try collectEntities(T, &self.active_world.ecs_backend, allocator);
                        defer entities.deinit(allocator);
                        for (entities.items) |entity| {
                            const id = entityToU64(entity);
                            if (!entity_set.contains(id)) {
                                try entity_set.put(id, {});
                                try entity_list.append(allocator, id);
                            }
                        }
                    }
                }
            }

            var aw: std.ArrayList(u8) = .{};
            defer aw.deinit(allocator);
            const writer = aw.writer(allocator);

            try std.fmt.format(writer, "{{\n  \"version\": {d},\n  \"entities\": [\n", .{SAVE_VERSION});

            for (entity_list.items, 0..) |id, idx| {
                const entity: Entity = @intCast(id);

                if (idx > 0) try writer.writeAll(",\n");
                try writer.writeAll("    {\n");
                try std.fmt.format(writer, "      \"id\": {d}", .{id});

                // Components (saveable + marker from registry + built-in Position)
                try writer.writeAll(",\n      \"components\": {");
                var first_comp = true;

                // Save Position (built-in) — only if not already in the component registry
                const Position = core.Position;
                if (comptime !isRegistered(Position)) {
                    const pos = self.getPosition(entity);
                    if (!first_comp) try writer.writeAll(",");
                    try writer.writeAll("\n        \"Position\": {\"x\": ");
                    try std.fmt.format(writer, "{d}", .{pos.x});
                    try writer.writeAll(", \"y\": ");
                    try std.fmt.format(writer, "{d}", .{pos.y});
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
                if (comptime !isRegistered(Parent)) {
                    if (self.active_world.ecs_backend.getComponent(entity, Parent)) |parent| {
                        if (!first_comp) try writer.writeAll(",");
                        try writer.writeAll("\n        \"Parent\": {\"entity\": ");
                        try std.fmt.format(writer, "{d}", .{entityToU64(parent.entity)});
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
                if (comptime !isRegistered(PrefabInstance)) {
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
                if (comptime !isRegistered(PrefabChildT)) {
                    if (self.active_world.ecs_backend.getComponent(entity, PrefabChildT)) |pc| {
                        if (!first_comp) try writer.writeAll(",");
                        try writer.writeAll("\n        \"PrefabChild\": {\"root\": ");
                        try std.fmt.format(writer, "{d}", .{entityToU64(pc.root)});
                        try writer.writeAll(", \"local_path\": ");
                        try writeJsonString(writer, pc.local_path);
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

            const cwd = std.fs.cwd();
            const file = try cwd.createFile(filename, .{});
            defer file.close();
            try file.writeAll(aw.items);
        }

        // ─── Load ───────────────────────────────────────────────────

        pub fn loadGameState(self: *Game, filename: []const u8) !void {
            @setEvalBranchQuota(10000);
            const allocator = self.allocator;
            const names = comptime Reg.names();

            const cwd = std.fs.cwd();
            const json = try cwd.readFileAlloc(allocator, filename, MAX_SAVE_SIZE);
            defer allocator.free(json);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
            defer parsed.deinit();

            const root = parsed.value.object;

            const version = (root.get("version") orelse return error.MissingField).integer;
            if (version != SAVE_VERSION) {
                return error.UnsupportedVersion;
            }

            const entities_json = (root.get("entities") orelse return error.MissingField).array;

            // Step 1: Clear scene tracking and destroy all entities atomically.
            //
            // Both scene-entity lists have to be cleared here:
            //   * `clearActiveSceneEntities()` — clears the active scene's
            //     *own* list (the one `active_scene_clear_entities_fn`
            //     wraps).
            //   * `self.scene_entities` — the Game-level list, populated
            //     by `trackSceneEntity` via the JSONC bridge's
            //     `spawnPrefabImpl`. `resetEcsBackend` doesn't touch it,
            //     so without this clear the list retains pre-load entity
            //     IDs that are dangling after the ECS reset. Phase 1a's
            //     `spawnFromPrefab` then appends new IDs on top, and a
            //     later `unloadCurrentScene` would iterate the stale ones
            //     and hit `destroyEntityOnly` with invalid handles.
            self.scene_entities.clearRetainingCapacity();
            self.clearActiveSceneEntities();
            self.resetEcsBackend();

            // Step 2: Create new entities and build ID map.
            //
            // Two-phase structure (RFC-SAVE-LOAD-PREFABS §Architecture,
            // Slice 3):
            //
            //   Phase 1 — PrefabInstance-tagged entities are re-spawned
            //   via `game.spawnFromPrefab`. The prefab reinstantiation
            //   brings back non-saveable components (Sprite, animation
            //   overlays, etc.) and the full child structure for free.
            //   For each saved PrefabChild, we walk the spawned tree by
            //   its `local_path` and map the saved child ID to the
            //   newly-spawned child entity.
            //
            //   Phase 1b — any saved entity NOT covered by Phase 1 (no
            //   PrefabInstance tag, and its ID wasn't mapped via a
            //   PrefabChild lookup) is created fresh with `createEntity`.
            //   Same as the v2 behaviour; preserves the non-prefab path.
            //
            //   Phase 2 (Step 3 below) applies saved component data on
            //   every entity — prefab-spawned or fresh — as overrides.
            var id_map = std.AutoHashMap(u64, u64).init(allocator);
            defer id_map.deinit();

            // Entities spawned via Phase 1a's `spawnFromPrefab` (the
            // root + every descendant the prefab creates) are already
            // renderer-tracked by `spawnPrefabImpl` — it routes each
            // visual component through `game.addSprite`/`addShape`,
            // which call `renderer.trackEntity` themselves. Step 5
            // below re-tracks any entity carrying a Sprite/Shape for
            // the Phase 1c createEntity path (bare entities whose
            // visuals come via Phase 2's `addComponent`). Without this
            // set, Phase 1a entities get registered with the renderer
            // twice — duplicate render-list entries, double cleanup
            // pressure, etc. Bugbot flagged this on da17581.
            var renderer_already_tracked = std.AutoHashMap(u64, void).init(allocator);
            defer renderer_already_tracked.deinit();

            // Phase 1a: spawn prefab roots. We need Position for the
            // spawn point; read it from the saved `Position` component.
            //
            // Skip entities that ALSO carry a PrefabChild tag — those
            // are nested-prefab entries where an outer prefab's
            // `spawnFromPrefab` already reinstantiates this whole
            // subtree. Calling spawnFromPrefab again here would create
            // a duplicate "ghost" root alongside the already-spawned
            // one. Phase 1b maps the nested root through the outer
            // tree's `(root, local_path)` walk instead.
            for (entities_json.items) |entry| {
                const components = getComponentsObject(entry) orelse continue;
                const pi_obj = getObjectField(components, "PrefabInstance") orelse continue;
                if (components.get("PrefabChild") != null) continue;
                const path_str = getStringField(pi_obj, "path") orelse continue;
                // Validate `saved_id` BEFORE spawning. If the entry is
                // missing a valid id, the spawned tree would have no
                // id_map entry — Phase 2 couldn't reconcile it and it
                // would remain as an orphan prefab tree in the world.
                // Reading first turns a silent leak into a skip.
                const saved_id = getSavedId(entry) orelse continue;

                // Extract spawn Position from saved components, defaulting
                // to (0,0) when absent (the prefab's own Position wins in
                // that case via `spawnPrefab`'s `parent_offset` path).
                var spawn_pos: core.Position = .{ .x = 0, .y = 0 };
                if (getObjectField(components, "Position")) |pos_obj| {
                    spawn_pos.x = getNumberField(pos_obj, "x");
                    spawn_pos.y = getNumberField(pos_obj, "y");
                }

                const new_root = self.spawnFromPrefab(path_str, spawn_pos) orelse {
                    self.log.warn("[SaveLoad] Phase 1: spawnFromPrefab('{s}') failed; falling back to fresh entity", .{path_str});
                    continue;
                };

                try id_map.put(saved_id, entityToU64(new_root));
                // Mark the root + every descendant as already-tracked
                // so Step 5's trackEntity pass skips them (see the
                // comment on `renderer_already_tracked` above).
                try markSubtreeRendererTracked(self, new_root, &renderer_already_tracked);
            }

            // Phase 1b: for each saved PrefabChild, walk the spawned
            // tree by `local_path` and map the saved child ID to the
            // already-spawned child entity. Requires Phase 1a to have
            // populated `id_map` with the root mappings first.
            for (entities_json.items) |entry| {
                const components = getComponentsObject(entry) orelse continue;
                const pc_obj = getObjectField(components, "PrefabChild") orelse continue;
                const saved_child_id = getSavedId(entry) orelse continue;
                const saved_root_id = getU64Field(pc_obj, "root") orelse continue;
                const local_path = getStringField(pc_obj, "local_path") orelse continue;

                const current_root_id = id_map.get(saved_root_id) orelse {
                    self.log.warn("[SaveLoad] Phase 1b: PrefabChild root {d} not in id_map — root spawn failed or save is inconsistent", .{saved_root_id});
                    continue;
                };
                const root_entity: Entity = @intCast(current_root_id);

                const child_entity = findChildByLocalPath(self, root_entity, local_path) orelse {
                    self.log.warn("[SaveLoad] Phase 1b: failed to walk local_path '{s}' from root entity {d}", .{ local_path, current_root_id });
                    continue;
                };
                try id_map.put(saved_child_id, entityToU64(child_entity));
            }

            // Phase 1c (the v2 path): any saved entity whose ID isn't
            // already in the id_map — non-prefab entities, or entities
            // whose prefab resolve failed — gets a fresh `createEntity`
            // so Phase 2 has something to apply components to.
            for (entities_json.items) |entry| {
                const saved_id = getSavedId(entry) orelse continue;
                if (id_map.contains(saved_id)) continue;
                const new_entity = self.createEntity();
                try id_map.put(saved_id, entityToU64(new_entity));
            }

            // Step 3: Restore components (includes Position)
            for (entities_json.items) |entry| {
                // Defensive accessors — a malformed entry whose `id` isn't
                // an integer, or whose `components` field is the wrong
                // shape, must not crash the load; skip the entry so the
                // rest of the save still applies. Same treatment
                // Phase 1a/1b/1c went through; mirror here so no
                // direct `.integer` / `.object` tag casts remain in the
                // load path.
                const saved_id = getSavedId(entry) orelse continue;
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);

                const components = getComponentsObject(entry) orelse continue;

                // Restore Position (built-in) — only if not in component registry
                const Position_load = core.Position;
                if (comptime !isRegistered(Position_load)) {
                    if (getObjectField(components, "Position")) |pos_obj| {
                        self.setPosition(entity, .{
                            .x = getNumberField(pos_obj, "x"),
                            .y = getNumberField(pos_obj, "y"),
                        });
                    }
                }

                inline for (names) |name| {
                    const T = Reg.getType(name);
                    if (comptime core.getSavePolicy(T)) |policy| {
                        if (policy == .saveable or policy == .marker) {
                            const comp_name = comptime serde.componentName(T);
                            if (components.get(comp_name)) |comp_val| {
                                if (serde.readComponent(T, comp_val, serde.autoSkipField)) |restored| {
                                    var comp = restored;
                                    serde.remapEntityRefs(T, &comp, &id_map);
                                    self.active_world.ecs_backend.addComponent(entity, comp);
                                } else |_| {}
                            }
                        }
                    }
                }

                // Restore Parent (built-in) — counterpart to the Parent
                // save block above. Uses `setParent` so the engine's
                // Children back-link is rebuilt alongside.
                //
                // Mirrors the save-side `has_parent_in_registry` guard
                // and Position's load-side guard: if a game ever
                // registers `Game.ParentComp`, the registry-driven
                // restore already handles Parent via `addComponent`, so
                // this built-in block would double-restore and trigger
                // `setParent` with stale state (review #470).
                //
                // Skip the restore unless we can both parse a valid
                // saved entity ID and map it to a post-load entity —
                // passing a stale or raw ID to `setParent` would trip
                // `assertEntityAlive` in debug or corrupt hierarchy
                // state in release builds.
                const Parent_load = Game.ParentComp;
                if (comptime !isRegistered(Parent_load)) {
                    if (components.get("Parent")) |parent_val| blk: {
                        // A malformed save carrying `"Parent": 123` or
                        // `"Parent": null` would otherwise trip the
                        // `.object` tag-cast safety check and panic in
                        // debug before the field-level guards below
                        // had a chance to skip the restore.
                        const parent_obj = switch (parent_val) {
                            .object => |o| o,
                            else => break :blk,
                        };
                        const ent_val = parent_obj.get("entity") orelse break :blk;
                        const saved_parent_id: u64 = switch (ent_val) {
                            .integer => |i| if (i >= 0) @intCast(i) else break :blk,
                            else => break :blk,
                        };
                        const current_parent_id = id_map.get(saved_parent_id) orelse break :blk;
                        const parent_entity: Entity = @intCast(current_parent_id);
                        const inherit_rotation = parentFlag(parent_obj, "inherit_rotation");
                        const inherit_scale = parentFlag(parent_obj, "inherit_scale");
                        self.setParent(entity, parent_entity, .{
                            .inherit_rotation = inherit_rotation,
                            .inherit_scale = inherit_scale,
                        });
                    }
                }

                // Restore PrefabInstance (built-in) — counterpart to
                // the save block above. String fields are duped into
                // the world's nested-entity arena so they outlive the
                // parsed JSON deinit.
                const PrefabInstance_load = Game.PrefabInstanceComp;
                if (comptime !isRegistered(PrefabInstance_load)) {
                    if (components.get("PrefabInstance")) |pi_val| blk: {
                        const pi_obj = switch (pi_val) {
                            .object => |o| o,
                            else => break :blk,
                        };
                        const path_str = switch (pi_obj.get("path") orelse break :blk) {
                            .string => |s| s,
                            else => break :blk,
                        };
                        const overrides_str = switch (pi_obj.get("overrides") orelse break :blk) {
                            .string => |s| s,
                            else => break :blk,
                        };
                        const pi_arena = self.active_world.nested_entity_arena.allocator();
                        const path_dup = try pi_arena.dupe(u8, path_str);
                        const overrides_dup = try pi_arena.dupe(u8, overrides_str);
                        self.active_world.ecs_backend.addComponent(entity, PrefabInstance_load{
                            .path = path_dup,
                            .overrides = overrides_dup,
                        });
                    }
                }

                // Restore PrefabChild (built-in) — counterpart to the
                // save block above. `root` is an entity ref, remapped
                // through `id_map`; `local_path` is duped into the
                // world arena to outlive the parsed JSON.
                const PrefabChild_load = Game.PrefabChildComp;
                if (comptime !isRegistered(PrefabChild_load)) {
                    if (components.get("PrefabChild")) |pc_val| blk: {
                        const pc_obj = switch (pc_val) {
                            .object => |o| o,
                            else => break :blk,
                        };
                        const root_val = pc_obj.get("root") orelse break :blk;
                        const saved_root_id: u64 = switch (root_val) {
                            .integer => |i| if (i >= 0) @intCast(i) else break :blk,
                            else => break :blk,
                        };
                        const current_root_id = id_map.get(saved_root_id) orelse break :blk;
                        const root_entity: Entity = @intCast(current_root_id);
                        const local_path_str = switch (pc_obj.get("local_path") orelse break :blk) {
                            .string => |s| s,
                            else => break :blk,
                        };
                        const pc_arena = self.active_world.nested_entity_arena.allocator();
                        const local_path_dup = try pc_arena.dupe(u8, local_path_str);
                        self.active_world.ecs_backend.addComponent(entity, PrefabChild_load{
                            .root = root_entity,
                            .local_path = local_path_dup,
                        });
                    }
                }
            }

            // Step 4: Restore ref arrays ([]const u64 slices)
            const arena = self.active_world.nested_entity_arena.allocator();

            for (entities_json.items) |entry| {
                const obj = entry.object;
                const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);

                if (obj.get("ref_arrays")) |ref_arrays_val| {
                    const ref_obj = ref_arrays_val.object;
                    inline for (names) |name| {
                        const T = Reg.getType(name);
                        if (comptime serde.hasRefArrayFields(T)) {
                            if (self.active_world.ecs_backend.getComponent(entity, T)) |comp| {
                                try serde.readRefArrays(T, comp, ref_obj, &id_map, arena);
                            }
                        }
                    }
                }
            }

            // Step 5: Register entities with scene + re-track visuals
            const Sprite = Game.SpriteComp;
            const Shape = Game.ShapeComp;
            for (entities_json.items) |entry| {
                const obj = entry.object;
                const saved_id: u64 = @intCast((obj.get("id") orelse continue).integer);
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);
                self.addEntityToActiveScene(entity);

                // Re-register visual components with the renderer (#38).
                // Skip entities spawned via Phase 1a's `spawnFromPrefab`
                // — their Sprite/Shape already went through `addSprite`
                // / `addShape` during the prefab spawn, which tracks
                // with the renderer. Double-tracking risks duplicate
                // render-list entries / mismatched cleanup.
                if (renderer_already_tracked.contains(entityToU64(entity))) continue;

                if (self.active_world.ecs_backend.hasComponent(entity, Sprite)) {
                    self.renderer.trackEntity(entity, .sprite);
                } else if (self.active_world.ecs_backend.hasComponent(entity, Shape)) {
                    self.renderer.trackEntity(entity, .shape);
                }
            }

            // Step 6: Post-load cleanup

            // 6a: Component-level postLoad hooks
            inline for (names) |name| {
                const T = Reg.getType(name);
                if (comptime core.hasPostLoad(T)) {
                    var entities = try collectEntities(T, &self.active_world.ecs_backend, allocator);
                    defer entities.deinit(allocator);
                    for (entities.items) |ent| {
                        if (self.active_world.ecs_backend.getComponent(ent, T)) |comp| {
                            comp.postLoad(self, ent);
                        }
                    }
                }
            }

            // 6b: post_load_add markers
            inline for (names) |name| {
                const T = Reg.getType(name);
                const markers = comptime core.getPostLoadMarkers(T);
                if (markers.len > 0) {
                    var entities = try collectEntities(T, &self.active_world.ecs_backend, allocator);
                    defer entities.deinit(allocator);
                    for (entities.items) |ent| {
                        inline for (markers) |Marker| {
                            if (!self.active_world.ecs_backend.hasComponent(ent, Marker)) {
                                self.active_world.ecs_backend.addComponent(ent, Marker{});
                            }
                        }
                    }
                }
            }

            // 6c: post_load_create entities
            inline for (names) |name| {
                const T = Reg.getType(name);
                if (comptime core.getPostLoadCreate(T)) {
                    const ent = self.createEntity();
                    self.active_world.ecs_backend.addComponent(ent, T{});
                    self.addEntityToActiveScene(ent);
                }
            }
        }
    };
}
