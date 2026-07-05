//! Load direction — reconstructs game state from a save file.
//!
//! Extracted verbatim from `save_load_mixin.zig`; behaviour is identical.
//! Provides `loadGameState` (with its Phase 1a/1b/1c → Phase 2 sequence
//! kept together here — the phases are load-bearing for understanding the
//! load-path symmetry) plus the post-load render gate (`armPostLoadRenderGate`,
//! `updatePostLoadRenderGate`, `releaseLoadAcquired`) and the load-only JSON
//! accessors. Shared helpers (`entityToU64`, `isRegistered`,
//! `collectEntities`, `SAVE_VERSION`) live in `common.zig` and are reached
//! through `Common.<fn>` — this mixin instantiates the common mixin against
//! the same `Game`, the idiom `loop_mixin` uses.

const std = @import("std");
const io_helper = @import("../../io_helper.zig");
const core = @import("labelle-core");
const serde = core.serde;
const common = @import("common.zig");

const SAVE_VERSION = common.SAVE_VERSION;
const MAX_SAVE_SIZE = 256 * 1024 * 1024; // 256 MB

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Reg = Game.ComponentRegistry;
    const Common = common.Mixin(Game);

    return struct {
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
            // `first` distinguishes the leading segment (no separator) from
            // subsequent ones (a single `.` separator is REQUIRED). This
            // rejects malformed paths a hostile / corrupted save could carry:
            //   * a leading `.` (`.children[0]`)
            //   * missing separators between segments
            //     (`children[0]children[1]`)
            //   * doubled / stray separators (`children[0]..children[1]`)
            // The old code stripped a `.` when present but never required
            // one, so all of the above resolved as if well-formed — aliasing
            // the wrong child's saved components onto the resolved entity.
            var first = true;
            while (rest.len > 0) {
                if (first) {
                    first = false;
                } else {
                    // Exactly one separator dot between segments.
                    if (rest[0] != '.') return null;
                    rest = rest[1..];
                }
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
            try set.put(Common.entityToU64(root), {});
            for (self.getChildren(root)) |child| {
                try markSubtreeRendererTracked(self, child, set);
            }
        }

        // ─── Load ───────────────────────────────────────────────────

        pub fn loadGameState(self: *Game, filename: []const u8) !void {
            @setEvalBranchQuota(10000);
            const allocator = self.allocator;
            const names = comptime Reg.names();

            const _io = io_helper.io();
            const json = try std.Io.Dir.cwd().readFileAlloc(_io, filename, allocator, .limited(MAX_SAVE_SIZE));
            defer allocator.free(json);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
            defer parsed.deinit();

            // Defensive: the top-level JSON must be an object. A malformed
            // save whose root is an array / scalar / null would otherwise
            // panic on the `.object` tag-cast in debug, or read garbage in
            // release. Saves are engine-written (trusted producer), so this
            // never fires normally — the value is a clean error instead of a
            // panic on a corrupted / hand-edited file.
            if (parsed.value != .object) return error.MalformedSave;
            const root = parsed.value.object;

            // `version` must be a non-negative integer. Tag-check before the
            // `.integer` access so a string / object / null version fails
            // cleanly rather than panicking.
            const version_val = root.get("version") orelse return error.MissingField;
            const version: i64 = switch (version_val) {
                .integer => |i| i,
                else => return error.MalformedSave,
            };
            if (version != SAVE_VERSION) {
                return error.UnsupportedVersion;
            }

            // `entities` must be an array. Tag-check before the `.array`
            // access for the same reason.
            const entities_val = root.get("entities") orelse return error.MissingField;
            const entities_json = switch (entities_val) {
                .array => |a| a,
                else => return error.MalformedSave,
            };

            // Optional saved scene name (engine#638). Saves written before
            // this field omit it — fall back to the current scene's
            // manifest (the pre-#638 gate behaviour). Borrowed from the
            // parsed JSON, so it's only valid for the duration of this
            // call; `armPostLoadRenderGate` resolves it to the
            // program-lifetime `SceneEntry.assets` slice before it's used
            // beyond this stack frame.
            const saved_scene: ?[]const u8 = if (root.get("scene")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null;

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
            // `scene_before_reset` fires for the same reason
            // `setSceneAtomic` emits it: plugin controllers with
            // per-world heap state must free it before
            // `resetEcsBackend` destroys the singleton component
            // that holds their pointer. Listeners that also handle
            // the F8 path see a consistent bracket across both
            // reset entry points. The scene name here is the
            // scene that's about to be reloaded (same name in,
            // same name out — the ECS is wiped and reloaded from
            // the save file, not swapped to a different scene).
            //
            // Only emit if `current_scene_name` is set —
            // `loadGameState` called before any scene loaded has
            // nothing to tear down that a name-keyed listener
            // could key off, and firing with an empty-string
            // payload would force listeners to handle the empty
            // sentinel. Fires BEFORE the tracking-list clears so
            // listeners see the pre-reset world — symmetrical
            // with the ordering in `setSceneAtomic`.
            if (self.current_scene_name) |current_scene| {
                self.emitHook(.{ .scene_before_reset = .{ .name = current_scene } });
            }
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

                try id_map.put(saved_id, Common.entityToU64(new_root));
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
                try id_map.put(saved_child_id, Common.entityToU64(child_entity));
            }

            // Phase 1c (the v2 path): any saved entity whose ID isn't
            // already in the id_map — non-prefab entities, or entities
            // whose prefab resolve failed — gets a fresh `createEntity`
            // so Phase 2 has something to apply components to.
            for (entities_json.items) |entry| {
                const saved_id = getSavedId(entry) orelse continue;
                if (id_map.contains(saved_id)) continue;
                const new_entity = self.createEntity();
                try id_map.put(saved_id, Common.entityToU64(new_entity));
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
                if (comptime !Common.isRegistered(Position_load)) {
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
                if (comptime !Common.isRegistered(Parent_load)) {
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
                if (comptime !Common.isRegistered(PrefabInstance_load)) {
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
                if (comptime !Common.isRegistered(PrefabChild_load)) {
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
                // Defensive: skip entries whose shape is wrong (non-object
                // entry, missing/negative/non-integer id) instead of
                // panicking on the `.object` / `.integer` tag-casts. Mirrors
                // the Phase 1/2 treatment via the shared `getSavedId` helper,
                // which also avoids `@intCast` trapping on a negative id.
                const saved_id = getSavedId(entry) orelse continue;
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);

                if (getObjectField(entry.object, "ref_arrays")) |ref_obj| {
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
                // Defensive: same shape guard as Step 4 — skip malformed
                // entries via `getSavedId` rather than tag-casting.
                const saved_id = getSavedId(entry) orelse continue;
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);
                self.addEntityToActiveScene(entity);

                // Re-register visual components with the renderer (#38).
                // Skip entities spawned via Phase 1a's `spawnFromPrefab`
                // — their Sprite/Shape already went through `addSprite`
                // / `addShape` during the prefab spawn, which tracks
                // with the renderer. Double-tracking risks duplicate
                // render-list entries / mismatched cleanup.
                if (renderer_already_tracked.contains(Common.entityToU64(entity))) continue;

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
                    var entities = try Common.collectEntities(T, &self.active_world.ecs_backend, allocator);
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
                    var entities = try Common.collectEntities(T, &self.active_world.ecs_backend, allocator);
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

            // Step 7: Arm the post-load render gate (#637).
            //
            // Phases 1–6 restored every saved entity synchronously, but
            // a prefab re-spawned in Phase 1a re-registers its atlas
            // through the streaming catalog (`registerAtlasFromMemory`
            // → `registerPendingAtlas`), which resets that atlas to
            // `texture_id == 0` and re-queues an async PNG decode/upload.
            // Until each atlas re-binds (the per-tick
            // `bridgeAllReadyImageAssets` calls `markPendingLoaded` once
            // its catalog upload lands), `findSprite` returns 0 for it
            // and the restored sprites would render with an unbound /
            // wrong texture — the corruption flash this fix targets.
            //
            // Mirror the scene-change readiness gate: hold the world
            // render until every `.image` atlas the loaded scene declares
            // has re-bound. We gate on the *scene's declared manifest*
            // (the same slice `setScene`/`gateOnManifest` use) because
            // those are exactly the atlases the restored sprites sample
            // from — and they're already acquired (refcount held since
            // the original scene load), so we only need to wait for the
            // re-decode, not re-acquire. `tick` clears the gate the first
            // frame `updatePostLoadRenderGate` finds them all bound.
            //
            // Scenes with no declared manifest (or a load fired before
            // any scene loaded) get no gate — there's nothing to wait on
            // and a never-clearing gate would freeze the world render.
            //
            // engine#638: arm against the SAVED scene's manifest, not the
            // currently-active scene. A menu→Load restores a colony save
            // while `current_scene_name` is still "menu" (load never swaps
            // scenes), so the menu's one-atlas manifest would gate nothing
            // useful. The saved manifest is the set the restored sprites
            // actually sample from. `armPostLoadRenderGate` also ACQUIRES
            // that manifest so the (re-)decode is triggered by the engine
            // itself — making loadGameState self-contained and retiring
            // the manual `assets.acquire(...)` loop games shipped (FP#542).
            self.armPostLoadRenderGate(saved_scene);
        }

        /// Arm the post-load render gate from the current scene's
        /// declared asset manifest. No-op when there's no current scene
        /// or the scene declares no assets (nothing to wait on). See the
        /// `post_load_render_gate` field doc + Step 7 in `loadGameState`.
        /// Upper bound on how many frames the post-load render gate may
        /// hold the world hidden. At 60 fps this is ~2 s — comfortably
        /// longer than the observed 1–2 s re-decode window, so a normal
        /// load always clears via the readiness path well before the
        /// deadline, yet a pathological never-binds atlas can't freeze
        /// the world forever (see `post_load_render_gate_deadline`).
        const POST_LOAD_GATE_MAX_FRAMES: u64 = 180;

        /// Release the image atlases a previous `loadGameState` acquired
        /// via `armPostLoadRenderGateFromEntry` (engine#638), balancing
        /// that acquire so repeated loads don't leak catalog refcounts.
        /// No-op when no load has pinned a manifest. Also called from
        /// `Game.deinit` so a game torn down after a load doesn't leak.
        pub fn releaseLoadAcquired(self: *Game) void {
            const prev = self.post_load_acquired_assets orelse return;
            self.post_load_acquired_assets = null;
            for (prev) |name| {
                const e = self.assets.entries.getPtr(name) orelse continue;
                if (e.loader_kind != .image) continue;
                self.assets.release(name);
            }
        }

        pub fn armPostLoadRenderGate(self: *Game, saved_scene: ?[]const u8) void {
            self.post_load_render_gate = null;
            self.post_load_render_gate_bridged = false;
            // Release the manifest the PREVIOUS load pinned — on EVERY
            // load, before resolving the new one (engine#638). Done here
            // (not only on the acquire path) so a load onto a scene with no
            // image manifest, an unregistered scene, or the early
            // no-manifest returns below still drops the prior pin. The
            // matching re-acquire happens in `armPostLoadRenderGateFromEntry`.
            releaseLoadAcquired(self);
            // Prefer the scene recorded IN the save (engine#638) — that's
            // the manifest the restored sprites actually sample from. Fall
            // back to the currently-active scene for legacy saves that
            // predate the `"scene"` field. Resolve to the program-lifetime
            // `SceneEntry.assets` slice so the gate can hold it across
            // frames without dangling on the parsed-JSON string.
            // Resolve the manifest slice: prefer the saved scene, then the
            // active scene as a fallback (legacy saves, or a saved scene
            // name that no longer resolves to a registered scene).
            const assets: []const []const u8 = blk: {
                if (saved_scene) |sn| {
                    if (self.scenes.get(sn)) |e| break :blk e.assets;
                }
                if (self.current_scene_name) |cn| {
                    if (self.scenes.get(cn)) |e| break :blk e.assets;
                }
                return;
            };
            armPostLoadRenderGateFromEntry(self, assets);
        }

        /// Shared body of `armPostLoadRenderGate` once the manifest slice
        /// is resolved. Acquires the manifest's image atlases (so the
        /// load triggers their decode itself — see #638), arms the gate,
        /// and settles it immediately.
        fn armPostLoadRenderGateFromEntry(self: *Game, assets: []const []const u8) void {
            if (assets.len == 0) return;
            // Only gate when at least one declared asset is an image
            // atlas — a manifest of pure audio/font entries has nothing
            // to re-bind and would otherwise wedge the gate open until
            // the next `updatePostLoadRenderGate` no-ops it (cheap, but
            // we skip arming to keep the steady state truly zero-cost).
            if (!postLoadGateHasImage(self, assets)) return;

            // Acquire the manifest's image atlases through the SAME catalog
            // path the scene-change gate uses (#638). A menu→Load lands on
            // a colony save whose packs the menu scene never acquired
            // (`menu` only pins `background`); without this nothing
            // triggers their (re-)decode and the world loads invisible —
            // which is exactly why flying-platform shipped a manual
            // `assets.acquire(...)` loop in its Load handler (FP#542).
            // Acquiring here makes loadGameState self-contained.
            //
            // Refcount discipline: a load does NOT swap scenes
            // (`current_scene_name` is unchanged), so the scene-swap
            // `releasePreviousAssets` never balances this acquire. The
            // PREVIOUS load's pin was already dropped by the
            // `releaseLoadAcquired` at the top of `armPostLoadRenderGate`
            // (runs on every load), so repeated loads (save A → save B) and
            // in-game same-scene reloads can't leak / double-pin the catalog
            // refcount. Idempotent per atlas: an already-`.ready` atlas just
            // bumps refcount (no re-decode).
            for (assets) |name| {
                const e = self.assets.entries.getPtr(name) orelse continue;
                if (e.loader_kind != .image) continue;
                _ = self.assets.acquire(name) catch {};
            }
            self.post_load_acquired_assets = assets;

            self.post_load_render_gate = assets;
            self.post_load_render_gate_deadline = self.frame_number + POST_LOAD_GATE_MAX_FRAMES;

            // Settle the gate immediately. `loadGameState` is typically
            // called from a script's `tick`, which runs AFTER the
            // per-frame `updatePostLoadRenderGate` in `tick`. Without
            // this, even a load whose atlases are all already bound (the
            // common case — `resetEcsBackend` preserves GPU textures)
            // would suppress this frame's `render` and only un-gate next
            // frame. Re-running the check here clears the gate in the
            // same frame when there's nothing unbound to hide, so the
            // no-corruption path is truly zero-frame. When a re-decode
            // *is* in flight, the gate stays armed and holds as intended.
            self.updatePostLoadRenderGate();
        }

        /// `true` when at least one entry in `assets` is a registered
        /// `.image` catalog asset — i.e. an atlas that has a `texture_id`
        /// to re-bind after a load.
        fn postLoadGateHasImage(self: *Game, assets: []const []const u8) bool {
            for (assets) |name| {
                const e = self.assets.entries.getPtr(name) orelse continue;
                if (e.loader_kind == .image) return true;
            }
            return false;
        }

        /// Per-tick gate check (#637). While the post-load render gate is
        /// armed, clear it the first frame every gated `.image` atlas has
        /// finished (re-)binding. We require BOTH:
        ///
        ///   1. the catalog entry to be `.ready` (the PNG decode + GPU
        ///      upload landed), and
        ///   2. — when the atlas_manager tracks an atlas under the same
        ///      name (FP and the assembler key both sides identically) —
        ///      that atlas to report `isLoaded()` (its `pending` decode
        ///      slot is cleared, i.e. `markPendingLoaded` has run and a
        ///      real texture handle is installed).
        ///
        /// IMPORTANT — readiness is `isLoaded()`, NOT `texture_id != 0`.
        /// `texture_id == 0` is the *pending* sentinel only while an
        /// atlas is registered-but-not-decoded; once decoded, 0 is a
        /// perfectly valid backend handle. bgfx (and any backend whose
        /// first-allocated texture/slot handle is 0) legitimately binds
        /// an atlas at handle 0 — the FP `characters` atlas renders
        /// correctly at `texture_id == 0` in steady-state play. Gating
        /// on `texture_id != 0` would therefore treat a correctly-bound
        /// atlas as "never ready" and hold the gate open until the
        /// deadline on every load. `isLoaded()` is the cross-backend-safe
        /// predicate: it tracks the decode/upload lifecycle, not the GPU
        /// handle value.
        ///
        /// Wedge-safety — the gate can NEVER hold the world hidden
        /// indefinitely:
        ///   * A `.failed` catalog entry is treated as terminal (the
        ///     scene gate already ships failed assets under
        ///     `asset_failure_policy`; blocking forever on one would be
        ///     worse than the flash this fix removes).
        ///   * An atlas the manager doesn't track by the catalog name is
        ///     satisfied on catalog `.ready` alone — there's no per-atlas
        ///     decode state to wait on, and waiting would wedge.
        ///   * A hard frame deadline force-clears the gate regardless
        ///     (see `post_load_render_gate_deadline`).
        ///
        /// Called from `tick` right after `bridgeAllReadyImageAssets`, so
        /// any atlas that finished binding this frame clears the gate the
        /// same frame (no extra hidden frame). No-op when the gate isn't
        /// armed (the steady-state cost is a single optional check). When
        /// the loaded scene's atlases were never invalidated (the common
        /// case — `resetEcsBackend` preserves GPU textures, and the
        /// assembler eager-loads atlases once at startup), every gated
        /// atlas is already `.ready` + `isLoaded()` on the first
        /// post-load tick, so the gate arms and clears in a single frame
        /// — correct, since there's nothing unbound to hide.
        pub fn updatePostLoadRenderGate(self: *Game) void {
            const gated = self.post_load_render_gate orelse return;

            // Hard deadline — force-clear so a never-binding atlas (a
            // failed decode, a renamed/missing atlas, a stuck re-decode)
            // can't freeze the world.
            if (self.frame_number >= self.post_load_render_gate_deadline) {
                self.post_load_render_gate = null;
                return;
            }

            // Pass 1: wait until EVERY gated image atlas's catalog entry
            // has reached a terminal state (`.ready` or `.failed`). We do
            // NOT bind any atlas until they're ALL ready — that all-at-once
            // bind is what makes this path deterministic (#638). Binding
            // incrementally, atlas-by-atlas as each upload lands (the old
            // per-tick `bridgeAllReadyImageAssets` behaviour for the load
            // path), is the asymmetry that let a menu→Load occasionally
            // show a half-bound manifest; the scene-change gate never does
            // because it bridges the whole manifest in one pass after
            // `allReady`.
            for (gated) |name| {
                const e = self.assets.entries.getPtr(name) orelse continue;
                if (e.loader_kind != .image) continue;
                // `.failed` is terminal — don't block on a broken asset
                // (mirrors the scene gate's `asset_failure_policy` intent).
                if (e.state == .failed) continue;
                // Still decoding/uploading — the (re-)decode is in flight.
                if (e.state != .ready) return;
            }

            // Pass 2: every gated atlas is `.ready`. Bind the WHOLE manifest
            // in a single deterministic pass — the same call the
            // scene-change gate makes (`bridgeManifest` →
            // `bridgeImageAssetsToAtlasManager`). Idempotent + done once
            // (guarded by `post_load_render_gate_bridged`) so a manifest
            // shared with an already-bound scene doesn't re-bind. After
            // this, every atlas the restored sprites sample from points at
            // its own freshly-uploaded handle, atomically.
            if (!self.post_load_render_gate_bridged) {
                self.bridgeManifest(gated);
                self.post_load_render_gate_bridged = true;
            }

            // Pass 3: confirm the manager-tracked atlases actually took the
            // binding (`isLoaded()`, not `texture_id != 0` — see the
            // readiness note above). Normally true the same frame as the
            // bridge; the loop guards against an atlas the manager doesn't
            // track by the catalog name (satisfied on catalog `.ready`).
            for (gated) |name| {
                if (self.atlas_manager.getAtlas(name)) |atlas| {
                    if (!atlas.isLoaded()) return;
                }
            }
            // Every gated atlas is bound — release the gate so `render`
            // shows the fully-textured restored world from this frame on.
            self.post_load_render_gate = null;
        }
    };
}
