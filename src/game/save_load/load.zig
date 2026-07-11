//! Load direction — reconstructs game state from a save file.
//!
//! Extracted verbatim from `save_load_mixin.zig`; behaviour is identical.
//! Provides `loadGameState` (with its Phase 1a/1b/1c → Phase 2 sequence
//! kept together here — the phases are load-bearing for understanding the
//! load-path symmetry) plus the two `Game`-aware tree helpers
//! (`findChildByLocalPath`, `markSubtreeRendererTracked`). The pure,
//! tag-checked JSON accessors now live in `json_read.zig` (they're
//! `std.json`-only, so extracting them leaves this file focused on the
//! rehydration walk); they're re-aliased at mixin scope below so the call
//! sites read unchanged. The transient post-load render gate
//! (`armPostLoadRenderGate`, `updatePostLoadRenderGate`,
//! `releaseLoadAcquired`) is a distinct concern with its own per-frame
//! lifecycle, so it lives in `render_gate.zig`; `loadGameState`'s final
//! step reaches it through `self.armPostLoadRenderGate(...)` (aliased onto
//! `Game`). Shared helpers (`entityToU64`, `isRegistered`,
//! `collectEntities`, `SAVE_VERSION`) live in `common.zig` and are reached
//! through `Common.<fn>` — this mixin instantiates the common mixin against
//! the same `Game`, the idiom `loop_mixin` uses.

const std = @import("std");
const io_helper = @import("../../io_helper.zig");
const core = @import("labelle-core");
const serde = core.serde;
const common = @import("common.zig");
const json_read = @import("json_read.zig");

const SAVE_VERSION = common.SAVE_VERSION;
const MAX_SAVE_SIZE = 256 * 1024 * 1024; // 256 MB

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Reg = Game.ComponentRegistry;
    const Common = common.Mixin(Game);

    return struct {
        // Pure, tag-checked JSON accessors — extracted to `json_read.zig`
        // (they're `std.json`-only) and re-aliased here so the load-path
        // call sites below (`getComponentsObject(entry)`, `getObjectField(...)`,
        // …) read exactly as they did when these were local `fn`s. See that
        // module's doc for the "return null on tag mismatch, never panic"
        // contract every one of these upholds.
        const parentFlag = json_read.parentFlag;
        const getComponentsObject = json_read.getComponentsObject;
        const getObjectField = json_read.getObjectField;
        const getStringField = json_read.getStringField;
        const getU64Field = json_read.getU64Field;
        const getSavedId = json_read.getSavedId;
        const getNumberField = json_read.getNumberField;

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

                // Restore Tilemap (built-in, T2 Phase 2) — counterpart to
                // the save block. `addTilemap` re-attaches the component AND
                // rebuilds the decoded-map runtime from the (still-embedded)
                // `.tmx` asset; runtime state itself is never saved.
                // `asset_name` is duped into the world arena to outlive the
                // parsed JSON deinit.
                const TilemapT_load = Game.TilemapComp;
                if (comptime !Common.isRegistered(TilemapT_load)) {
                    if (components.get("Tilemap")) |tm_val| blk: {
                        const tm_obj = switch (tm_val) {
                            .object => |o| o,
                            else => break :blk,
                        };
                        const name_str = switch (tm_obj.get("asset_name") orelse break :blk) {
                            .string => |s| s,
                            else => break :blk,
                        };
                        const tm_arena = self.active_world.nested_entity_arena.allocator();
                        const name_dup = try tm_arena.dupe(u8, name_str);

                        // Restore explicit `layer_bindings` (T3), if the save
                        // carried them. Absent → `null` (implicit-by-name),
                        // matching a T2 save. Strings + the slice are duped
                        // into the world arena to outlive the parsed JSON.
                        const LayerBinding = @import("../../tilemap.zig").LayerBinding;
                        var bindings: ?[]const LayerBinding = null;
                        if (tm_obj.get("layer_bindings")) |lb_val| {
                            if (lb_val == .array) {
                                const arr = lb_val.array;
                                const buf = try tm_arena.alloc(LayerBinding, arr.items.len);
                                var n: usize = 0;
                                for (arr.items) |item| {
                                    const obj = switch (item) {
                                        .object => |o| o,
                                        else => continue,
                                    };
                                    const tmx = switch (obj.get("tmx_layer") orelse continue) {
                                        .string => |s| s,
                                        else => continue,
                                    };
                                    const eng = switch (obj.get("engine_layer") orelse continue) {
                                        .string => |s| s,
                                        else => continue,
                                    };
                                    buf[n] = .{
                                        .tmx_layer = try tm_arena.dupe(u8, tmx),
                                        .engine_layer = try tm_arena.dupe(u8, eng),
                                    };
                                    n += 1;
                                }
                                bindings = buf[0..n];
                            }
                        }
                        self.addTilemap(entity, .{ .asset_name = name_dup, .layer_bindings = bindings });
                    }
                }

                // Restore Camera (built-in, camera-prefabs #714) — counterpart
                // to the save block. Plain POD (no strings / no runtime), so a
                // straight `addComponent` re-attaches it; the seed re-applies to
                // the live camera on the next scene bind / paused frame. Gated
                // on `camera_is_builtin` like the save side.
                if (comptime Game.camera_is_builtin) {
                    if (components.get("Camera")) |cam_val| blk: {
                        const cam_obj = switch (cam_val) {
                            .object => |o| o,
                            else => break :blk,
                        };
                        var cam: Game.CameraComp = .{};
                        // Preserve the 1.0 default if a (malformed) save omits
                        // zoom — `getNumberField` would otherwise yield 0.
                        if (cam_obj.get("zoom") != null) cam.zoom = getNumberField(cam_obj, "zoom");
                        // Camera tag (camera-bound layers, #723/#724). Absent in
                        // pre-#724 saves → the `"main"` default is kept.
                        if (getStringField(cam_obj, "tag")) |t| cam.setTagSlice(t);
                        if (cam_obj.get("viewport")) |vp_val| {
                            if (vp_val == .object) {
                                const vp = vp_val.object;
                                cam.viewport = .{
                                    .x = @intFromFloat(getNumberField(vp, "x")),
                                    .y = @intFromFloat(getNumberField(vp, "y")),
                                    .width = @intFromFloat(getNumberField(vp, "width")),
                                    .height = @intFromFloat(getNumberField(vp, "height")),
                                };
                            }
                        }
                        self.addComponent(entity, cam);
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

            // Re-seed the gfx cameras from the just-restored `Camera`
            // components (camera-bound layers, #723/#724). Without this a save
            // that authored a tagged secondary camera comes back with its
            // component reattached but no live camera slot bound — the layers
            // it drives would fall back to the main camera. `reset-then-seed`
            // also clears any stale secondary slot the pre-load scene left
            // active. Comptime no-op on camera-less / project-Camera builds.
            self.seedCameraFromComponent();
        }
    };
}
