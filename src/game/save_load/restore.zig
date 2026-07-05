//! Load half of the save/load mixin — the two-phase `loadGameState`
//! (+ `releaseLoadAcquired`), split from `save_load_mixin.zig`
//! (>1000-line rule; behavior-preserving). Reaches the render gate via
//! the Game delegation (`self.armPostLoadRenderGate`), same as every
//! external caller.

const shared = @import("shared.zig");
const std = @import("std");
const io_helper = @import("../../io_helper.zig");
const core = @import("labelle-core");
const serde = core.serde;

const SAVE_VERSION: u32 = 2;
const MAX_SAVE_SIZE = 256 * 1024 * 1024; // 256 MB

pub fn Restore(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Reg = Game.ComponentRegistry;
    const Sh = shared.Shared(Game);

    return struct {
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

            const root = parsed.value.object;

            const version = (root.get("version") orelse return error.MissingField).integer;
            if (version != SAVE_VERSION) {
                return error.UnsupportedVersion;
            }

            const entities_json = (root.get("entities") orelse return error.MissingField).array;

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
                const components = Sh.getComponentsObject(entry) orelse continue;
                const pi_obj = Sh.getObjectField(components, "PrefabInstance") orelse continue;
                if (components.get("PrefabChild") != null) continue;
                const path_str = Sh.getStringField(pi_obj, "path") orelse continue;
                // Validate `saved_id` BEFORE spawning. If the entry is
                // missing a valid id, the spawned tree would have no
                // id_map entry — Phase 2 couldn't reconcile it and it
                // would remain as an orphan prefab tree in the world.
                // Reading first turns a silent leak into a skip.
                const saved_id = Sh.getSavedId(entry) orelse continue;

                // Extract spawn Position from saved components, defaulting
                // to (0,0) when absent (the prefab's own Position wins in
                // that case via `spawnPrefab`'s `parent_offset` path).
                var spawn_pos: core.Position = .{ .x = 0, .y = 0 };
                if (Sh.getObjectField(components, "Position")) |pos_obj| {
                    spawn_pos.x = Sh.getNumberField(pos_obj, "x");
                    spawn_pos.y = Sh.getNumberField(pos_obj, "y");
                }

                const new_root = self.spawnFromPrefab(path_str, spawn_pos) orelse {
                    self.log.warn("[SaveLoad] Phase 1: spawnFromPrefab('{s}') failed; falling back to fresh entity", .{path_str});
                    continue;
                };

                try id_map.put(saved_id, Sh.entityToU64(new_root));
                // Mark the root + every descendant as already-tracked
                // so Step 5's trackEntity pass skips them (see the
                // comment on `renderer_already_tracked` above).
                try Sh.markSubtreeRendererTracked(self, new_root, &renderer_already_tracked);
            }

            // Phase 1b: for each saved PrefabChild, walk the spawned
            // tree by `local_path` and map the saved child ID to the
            // already-spawned child entity. Requires Phase 1a to have
            // populated `id_map` with the root mappings first.
            for (entities_json.items) |entry| {
                const components = Sh.getComponentsObject(entry) orelse continue;
                const pc_obj = Sh.getObjectField(components, "PrefabChild") orelse continue;
                const saved_child_id = Sh.getSavedId(entry) orelse continue;
                const saved_root_id = Sh.getU64Field(pc_obj, "root") orelse continue;
                const local_path = Sh.getStringField(pc_obj, "local_path") orelse continue;

                const current_root_id = id_map.get(saved_root_id) orelse {
                    self.log.warn("[SaveLoad] Phase 1b: PrefabChild root {d} not in id_map — root spawn failed or save is inconsistent", .{saved_root_id});
                    continue;
                };
                const root_entity: Entity = @intCast(current_root_id);

                const child_entity = Sh.findChildByLocalPath(self, root_entity, local_path) orelse {
                    self.log.warn("[SaveLoad] Phase 1b: failed to walk local_path '{s}' from root entity {d}", .{ local_path, current_root_id });
                    continue;
                };
                try id_map.put(saved_child_id, Sh.entityToU64(child_entity));
            }

            // Phase 1c (the v2 path): any saved entity whose ID isn't
            // already in the id_map — non-prefab entities, or entities
            // whose prefab resolve failed — gets a fresh `createEntity`
            // so Phase 2 has something to apply components to.
            for (entities_json.items) |entry| {
                const saved_id = Sh.getSavedId(entry) orelse continue;
                if (id_map.contains(saved_id)) continue;
                const new_entity = self.createEntity();
                try id_map.put(saved_id, Sh.entityToU64(new_entity));
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
                const saved_id = Sh.getSavedId(entry) orelse continue;
                const current_id = id_map.get(saved_id) orelse continue;
                const entity: Entity = @intCast(current_id);

                const components = Sh.getComponentsObject(entry) orelse continue;

                // Restore Position (built-in) — only if not in component registry
                const Position_load = core.Position;
                if (comptime !Sh.isRegistered(Position_load)) {
                    if (Sh.getObjectField(components, "Position")) |pos_obj| {
                        self.setPosition(entity, .{
                            .x = Sh.getNumberField(pos_obj, "x"),
                            .y = Sh.getNumberField(pos_obj, "y"),
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
                if (comptime !Sh.isRegistered(Parent_load)) {
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
                        const inherit_rotation = Sh.parentFlag(parent_obj, "inherit_rotation");
                        const inherit_scale = Sh.parentFlag(parent_obj, "inherit_scale");
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
                if (comptime !Sh.isRegistered(PrefabInstance_load)) {
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
                if (comptime !Sh.isRegistered(PrefabChild_load)) {
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
                if (renderer_already_tracked.contains(Sh.entityToU64(entity))) continue;

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
                    var entities = try Sh.collectEntities(T, &self.active_world.ecs_backend, allocator);
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
                    var entities = try Sh.collectEntities(T, &self.active_world.ecs_backend, allocator);
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
    };
}
