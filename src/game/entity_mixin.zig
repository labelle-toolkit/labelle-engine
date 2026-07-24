/// Entity mixin — entity lifecycle (create / destroy), prefab spawning
/// and save/load Phase-1 tagging, the view-collection helpers (#510),
/// the debug tombstone-record write, and scene-entity tracking.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. Intra-cluster
/// helpers (`tagPrefabChildren`, `untrackSceneEntity`, `recordTombstone`)
/// are called via lexical sibling-function syntax so they resolve inside
/// this struct. Cross-cluster calls (`emitHook`, `emitEngineEvent`,
/// `getChildren`, `hasChildren`, `tagAsPrefabInstance`, `destroyEntity`,
/// `detachFromParent`) route through the `Game` re-exports.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("labelle-core");
const Position = core.Position;
const PrefabInstance = core.PrefabInstance;

/// Returns the entity-lifecycle mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Children = Game.ChildrenComp;
    const PrefabChildT = Game.PrefabChildComp;
    const TombstoneEntry = Game.TombstoneEntry;
    const tombstone_size = Game.tombstone_size;
    const is_debug = builtin.mode == .Debug;

    return struct {
        // ── Debug entity guards (#419, #420) ─────────────────────

        pub fn recordTombstone(self: *Game, entity: Entity) void {
            if (comptime is_debug) {
                self.tombstones[self.tombstone_cursor] = TombstoneEntry{ .entity = entity, .frame = self.frame_number };
                self.tombstone_cursor = (self.tombstone_cursor + 1) % tombstone_size;
            }
        }

        pub fn findTombstone(self: *const Game, entity: Entity) ?TombstoneEntry {
            if (comptime !is_debug) return null;
            // Iterate backwards from cursor to return the most recent match
            // (entity IDs can be reused after resetEcsBackend or ECS recycling)
            var j: usize = 0;
            while (j < tombstone_size) : (j += 1) {
                const i = (self.tombstone_cursor + tombstone_size - 1 - j) % tombstone_size;
                if (self.tombstones[i]) |entry| {
                    if (entry.entity == entity) return entry;
                }
            }
            return null;
        }

        pub fn assertEntityAlive(self: *const Game, entity: Entity, comptime operation: []const u8) void {
            if (comptime is_debug) {
                if (!self.ecs_backend.entityExists(entity)) {
                    if (findTombstone(self, entity)) |tomb| {
                        std.debug.print("{s} on destroyed entity {d} (destroyed in frame {d}, current frame {d})\n", .{
                            operation, entity, tomb.frame, self.frame_number,
                        });
                        @panic(operation ++ " on destroyed entity");
                    } else {
                        std.debug.print("{s} on invalid entity {d} (not in tombstone ring — destroyed long ago or never existed)\n", .{
                            operation, entity,
                        });
                        @panic(operation ++ " on invalid entity");
                    }
                }
            }
        }

        // ── Entity Management ─────────────────────────────────────

        pub fn createEntity(self: *Game) Entity {
            const entity = self.ecs_backend.createEntity();
            self.bumpRoster();
            self.emitHook(.{ .entity_created = .{ .entity_id = entity } });
            // Engine `Events` dual-emit (#578). `entity` is widened to
            // u32 — same convention as box2d's `Events.collision_begin`.
            self.emitEngineEvent("engine__entity_created", .{ .entity = @as(u32, @intCast(entity)) });
            // Preview telemetry: the prefab path tags `PrefabInstance`
            // *after* createEntity returns (see `tagAsPrefabInstance`),
            // so we can't carry the prefab name here. Emit null; a
            // future enhancement can re-emit on tag.
            if (self.preview) |*p| p.emitEntityCreated(@intCast(entity), null) catch {};
            return entity;
        }

        /// Spawn an entity from a named prefab at the given position.
        /// Returns the entity, or null if the prefab was not found.
        /// Requires a JSONC scene to have been loaded (which sets up the prefab directory).
        pub fn spawnPrefab(self: *Game, name: []const u8, pos: Position) ?Entity {
            if (self.spawn_prefab_fn) |func| {
                return func(self, name, pos);
            }
            self.log.err("[Game] spawnPrefab: no prefab loader configured (load a JSONC scene first)", .{});
            return null;
        }

        /// Spawn a prefab *and* tag it for save/load Phase 1 reinstantiation.
        ///
        /// Wraps `spawnPrefab` with two additions from
        /// `RFC-SAVE-LOAD-PREFABS.md`:
        ///
        /// 1. The **root** entity gets `PrefabInstance { path, overrides = "" }`
        ///    so the save mixin's built-in handler (added in #474)
        ///    records its prefab origin.
        /// 2. Each **child** entity (recursively) gets
        ///    `PrefabChild { root, local_path = "children[i]..." }` so
        ///    Phase 1 on load can map saved child IDs back to newly-
        ///    spawned children via `(root, local_path)`.
        ///
        /// `PrefabInstance.path` and every `PrefabChild.local_path` are
        /// duped into `active_world.nested_entity_arena` — lifetime
        /// matches the prefab children (world-scoped), freed on scene
        /// change. Same ownership contract as the save mixin's load-
        /// side allocation. `PrefabInstance.overrides` is the string
        /// literal `""` in this first-cut slice (program lifetime, no
        /// arena allocation needed for a zero-length literal); the
        /// structured-overrides pipeline lands in a follow-up and will
        /// dupe `overrides` into the same arena then.
        ///
        /// **Interaction with the save mixin:** tagged entities
        /// always survive `saveGameState` → `loadGameState` round-
        /// trip. Since the sweep in `saveGameState` auto-collects
        /// entities with `PrefabInstance` / `PrefabChild` (in
        /// addition to the registry-driven saveable / marker pass),
        /// a purely-visual prefab — even one whose root has only
        /// `Sprite` + the engine's auto-attached `PrefabInstance` —
        /// still round-trips cleanly and Phase 1 respawns it from
        /// the `path`. Game authors don't need to sprinkle marker
        /// components solely to placate save/load.
        ///
        /// Caveat: this covers *collection only*. If a prefab root's
        /// components are all non-saveable, Phase 2 has no overrides
        /// to apply, so the respawned entity reflects the prefab's
        /// literal declaration. Game-owned `.saveable` components
        /// override that (per-instance state lives through
        /// round-trips). `.transient` components reset to the
        /// prefab's values.
        pub fn spawnFromPrefab(self: *Game, path: []const u8, pos: Position) ?Entity {
            const entity = spawnPrefab(self, path, pos) orelse return null;
            // Any tagging failure (arena OOM on path dupe, or inside
            // the recursive child walk) leaves the world with an
            // orphan entity tree that has no `PrefabInstance` tag —
            // scene-tracked, component-populated, but invisible to
            // the save mixin's Phase 1. Destroy the whole tree on
            // failure so `spawnFromPrefab`'s null return really
            // means "the world is unchanged."
            //
            // Log the error name before tearing down: `null` return
            // collides with the "unknown prefab" signal from
            // `spawnPrefab`, so without the log an OOM during tagging
            // is indistinguishable from a typo in the prefab path.
            self.tagAsPrefabInstance(entity, path) catch |err| {
                self.log.err("[Game] spawnFromPrefab: tagging failed for '{s}': {s}", .{ path, @errorName(err) });
                self.destroyEntity(entity);
                return null;
            };
            return entity;
        }

        /// Tag `entity` as a prefab root (attach `PrefabInstance`) and
        /// walk its descendants attaching `PrefabChild` markers with
        /// `local_path` relative to the root.
        ///
        /// Used by both `spawnFromPrefab` (runtime spawn path) and
        /// `JsoncSceneBridge::loadEntityInternal` (scene-load path) so
        /// the `(root, local_path)` key the save mixin uses to match
        /// saved children to respawned ones is generated consistently.
        pub fn tagAsPrefabInstance(self: *Game, entity: Entity, path: []const u8) !void {
            const arena = self.active_world.nested_entity_arena.allocator();
            const path_dup = try arena.dupe(u8, path);

            self.ecs_backend.addComponent(entity, PrefabInstance{
                .path = path_dup,
                .overrides = "",
            });

            try tagPrefabChildren(self, entity, entity, "children", arena);
            // PrefabInstance / PrefabChild membership was written through
            // the ecs_backend directly for the whole tree; one bump
            // invalidates every roster (generation-based), so rosters
            // keyed on those tags don't go stale (#653).
            self.bumpRoster();
        }

        /// Recursively tag every descendant of `root` with `PrefabChild`.
        /// `base_path` is the dotted path accumulated so far (e.g.
        /// `"children"` at the top level; `"children[0].children"` one
        /// level in). Each child appends `[i]` to form its unique path
        /// within the prefab tree.
        ///
        /// Propagates allocation errors up instead of silently
        /// `continue`-ing — a partially-tagged tree would have
        /// `PrefabChild` on some descendants and not others, breaking
        /// the `(root, local_path)` lookup the two-phase load relies
        /// on. Atomic: if anything fails, `spawnFromPrefab` destroys
        /// the tree and returns null.
        fn tagPrefabChildren(
            self: *Game,
            root: Entity,
            parent: Entity,
            base_path: []const u8,
            arena: std.mem.Allocator,
        ) !void {
            const children = self.getChildren(parent);
            for (children, 0..) |child, i| {
                const child_path = try std.fmt.allocPrint(
                    arena,
                    "{s}[{d}]",
                    .{ base_path, i },
                );
                self.ecs_backend.addComponent(child, PrefabChildT{
                    .root = root,
                    .local_path = child_path,
                });
                // Skip the `.children` suffix allocation when `child` is
                // a leaf. Two-level prefab trees (hydroponics: root +
                // room + plant overlay) are common; without this gate
                // the leaf gets an unused `"children[i].children"`
                // string arena-allocated every spawn.
                if (self.hasChildren(child)) {
                    const next_base = try std.fmt.allocPrint(
                        arena,
                        "{s}.children",
                        .{child_path},
                    );
                    try tagPrefabChildren(self, root, child, next_base, arena);
                }
            }
        }

        pub fn destroyEntity(self: *Game, entity: Entity) void {
            if (self.ecs_backend.getComponent(entity, Children)) |children_comp| {
                // Cascade over an INDEPENDENT copy of the child ids. Each
                // child's destroy unlinks it from THIS live list via
                // `detachFromParent` (a swap-remove), and the list's backing
                // allocation is freed just below — so iterating the live
                // buffer, or a shallow struct copy that shares it (the list
                // is now a heap-backed `ArrayList`, not an inline buffer),
                // would read shrunk / reordered / freed memory. Copy the ids
                // onto their own allocation first. This also shields the walk
                // from `entity_destroyed` hooks re-parenting into this list
                // and from the component pool reshuffling mid-cascade.
                const kids = self.allocator.dupe(Entity, children_comp.getChildren()) catch @panic("OOM: destroyEntity children snapshot");
                defer self.allocator.free(kids);
                for (kids) |child| {
                    destroyEntity(self, child);
                }
            }
            // Preview telemetry emits BEFORE the actual destroy so any
            // editor-side consumer can still introspect the entity from
            // a `getComponent` style API while reacting to the frame — so the
            // `Children` free below must stay AFTER this: freeing the list
            // first would hand a preview `getChildren` a slice into a freed
            // allocation.
            if (self.preview) |*p| p.emitEntityDestroyed(@intCast(entity)) catch {};
            // #701 — unlink from the parent's `Children` before the
            // backend destroy (after it, the `Parent` component is
            // unreachable). A destroy-while-parented used to leave a
            // permanently stale id in the parent's list; with index-only
            // sparse-set lookups a recycled index later aliases that id
            // onto an unrelated entity. List-unlink only: no renderer
            // transform pokes for the dying entity.
            self.detachFromParent(entity);
            untrackSceneEntity(self, entity);
            self.active_world.sprite_cache.invalidate(@intCast(entity));
            self.renderer.untrackEntity(entity);
            self.releaseTilemap(entity);
            // Free this entity's own `Children` backing allocation just before
            // the backend drops the component by value (the ECS runs no
            // destructor). Kept here — after the preview telemetry above — so
            // a preview `getChildren` never reads a freed list. Re-fetch: the
            // cascade may have relocated the Children pool under an old pointer.
            if (self.ecs_backend.getComponent(entity, Children)) |cc| cc.deinit(self.allocator);
            self.ecs_backend.destroyEntity(entity);
            self.bumpRoster();
            recordTombstone(self, entity);
            self.emitHook(.{ .entity_destroyed = .{ .entity_id = entity } });
            // Engine `Events` dual-emit (#578).
            self.emitEngineEvent("engine__entity_destroyed", .{ .entity = @as(u32, @intCast(entity)) });
        }

        pub fn destroyEntityOnly(self: *Game, entity: Entity) void {
            if (self.preview) |*p| p.emitEntityDestroyed(@intCast(entity)) catch {};
            // #701 — same parent-unlink as `destroyEntity`. This variant
            // deliberately leaves the entity's own children alive (its
            // contract — the scene drain destroys every tracked entity
            // itself), but the destroyed entity must still vanish from
            // its parent's `Children` list. During a drain the parent may
            // already be destroyed — `detachFromParent` guards with
            // `entityExists` before touching the parent's list.
            self.detachFromParent(entity);
            // Free this entity's own `Children` backing allocation. This
            // variant leaves the listed children ALIVE (its contract), but
            // the `Children` component itself dies with the entity, so its
            // ArrayList must be freed or it leaks (the ECS runs no
            // destructor).
            if (self.ecs_backend.getComponent(entity, Children)) |cc| cc.deinit(self.allocator);
            untrackSceneEntity(self, entity);
            self.active_world.sprite_cache.invalidate(@intCast(entity));
            self.renderer.untrackEntity(entity);
            self.releaseTilemap(entity);
            self.ecs_backend.destroyEntity(entity);
            self.bumpRoster();
            recordTombstone(self, entity);
            self.emitHook(.{ .entity_destroyed = .{ .entity_id = entity } });
            // Engine `Events` dual-emit (#578).
            self.emitEngineEvent("engine__entity_destroyed", .{ .entity = @as(u32, @intCast(entity)) });
        }

        // ── View collection helpers (#510) ────────────────────────
        //
        // Iterating an ECS view while mutating the world (adding /
        // removing components, destroying entities) risks
        // invalidating the iterator on backends that don't tolerate
        // concurrent mutation. The helpers below absorb the
        // "collect first, then mutate" boilerplate every dispatcher
        // / hook / tick was hand-rolling.

        /// Heap-allocated collection. Returns an `ArrayList(Entity)`
        /// the caller `deinit`s. Picks the heap path when the
        /// expected size is unknown or large (save / load,
        /// debug-snapshot scans, one-shot batch ops).
        pub fn collectEntities(
            self: *Game,
            comptime include: anytype,
            comptime exclude: anytype,
            allocator: std.mem.Allocator,
        ) !std.ArrayList(Entity) {
            var buf: std.ArrayList(Entity) = .empty;
            errdefer buf.deinit(allocator);
            var view = self.ecs_backend.view(include, exclude);
            defer view.deinit();
            while (view.next()) |ent| {
                try buf.append(allocator, ent);
            }
            return buf;
        }

        /// Stack-allocated collection. Fills `buf` and returns the
        /// number of entities written. Sets `overflowed.*` to true
        /// if the view contained more entities than `buf.len`. Use
        /// for per-tick scans where allocating in the hot loop
        /// would be wasteful and the worst-case set is bounded.
        ///
        /// On overflow the caller decides what to do — typically
        /// `log.warn(...)` + retry next frame (matches the existing
        /// `sleep_hooks.frame_end` convention).
        pub fn collectEntitiesBuf(
            self: *Game,
            comptime include: anytype,
            comptime exclude: anytype,
            buf: []Entity,
            overflowed: *bool,
        ) usize {
            overflowed.* = false;
            var count: usize = 0;
            var view = self.ecs_backend.view(include, exclude);
            defer view.deinit();
            while (view.next()) |ent| {
                if (count < buf.len) {
                    buf[count] = ent;
                    count += 1;
                } else {
                    overflowed.* = true;
                }
            }
            return count;
        }

        /// Same shape as `collectEntities`, with an extra runtime
        /// `predicate(self, entity) bool` filter. Use when the
        /// caller needs to check a component **field value** (or any
        /// derived condition) — the comptime include / exclude
        /// tuple only filters on component existence. The predicate
        /// receives the live `Game` pointer so it can
        /// `getComponent(...)` for whatever runtime state the
        /// filter inspects.
        ///
        /// **Predicate contract: read-only.** The whole point of the
        /// `collect*` helpers is to *avoid* mutating the world
        /// inside the view's iteration. The predicate runs while
        /// the iterator is live; adding / removing components or
        /// destroying entities from inside it risks the same
        /// concurrent-mutation hazard the helpers exist to dodge.
        /// Use the predicate to *inspect* state (via
        /// `getComponent`, etc.); commit mutations in the loop the
        /// caller writes over the returned list.
        pub fn collectEntitiesIf(
            self: *Game,
            comptime include: anytype,
            comptime exclude: anytype,
            allocator: std.mem.Allocator,
            predicate: *const fn (*Game, Entity) bool,
        ) !std.ArrayList(Entity) {
            var buf: std.ArrayList(Entity) = .empty;
            errdefer buf.deinit(allocator);
            var view = self.ecs_backend.view(include, exclude);
            defer view.deinit();
            while (view.next()) |ent| {
                if (predicate(self, ent)) {
                    try buf.append(allocator, ent);
                }
            }
            return buf;
        }

        /// Same shape as `collectEntitiesBuf`, with the runtime
        /// `predicate` filter. Useful for the per-tick scan path
        /// where the worst case is bounded and a heap allocation
        /// per frame would be wasteful — same `overflowed`
        /// out-pointer contract.
        ///
        /// **Predicate contract: read-only** — same rule as
        /// `collectEntitiesIf`. The hot-path stack variant is the
        /// one most likely to be tempted with a per-tick mutation
        /// inside the predicate; resist. Inspect only.
        ///
        /// On overflow the iteration breaks early: once the buffer
        /// is full and we've seen one more predicate-accepted
        /// entity, there's nothing the caller can do with the rest
        /// (they go in next tick's pass), so spending more
        /// predicate calls is wasted work. Predicate-rejected
        /// entities don't count toward the cap — a view full of
        /// rejects never trips the overflow flag.
        pub fn collectEntitiesBufIf(
            self: *Game,
            comptime include: anytype,
            comptime exclude: anytype,
            buf: []Entity,
            overflowed: *bool,
            predicate: *const fn (*Game, Entity) bool,
        ) usize {
            overflowed.* = false;
            var count: usize = 0;
            var view = self.ecs_backend.view(include, exclude);
            defer view.deinit();
            while (view.next()) |ent| {
                if (!predicate(self, ent)) continue;
                if (count < buf.len) {
                    buf[count] = ent;
                    count += 1;
                } else {
                    overflowed.* = true;
                    break;
                }
            }
            return count;
        }

        // ── Scene-entity tracking ─────────────────────────────────

        /// Register an entity as owned by the current scene. Called by
        /// scene loaders (JSONC bridge, comptime registerScene callbacks)
        /// so `unloadCurrentScene` can destroy the entity when the scene
        /// swaps out. Silently no-ops on OOM — the scene still works, we
        /// just lose the auto-cleanup for the un-tracked entity.
        pub fn trackSceneEntity(self: *Game, entity: Entity) void {
            self.scene_entities.append(self.allocator, entity) catch {};
        }

        /// Remove an entity from the scene-tracking list. Called by
        /// `destroyEntity`/`destroyEntityOnly` so (1) a scene's cleanup
        /// loop never double-destroys a tracked-then-manually-destroyed
        /// entity and (2) the list doesn't grow unboundedly across a
        /// scene that churns through short-lived entities. O(N) scan +
        /// swap-remove — fine for scenes with hundreds of entities;
        /// revisit if a project pushes tens of thousands.
        ///
        /// During a full scene-entity drain (`unloadCurrentScene`) the
        /// `tearing_down_scene` guard short-circuits the scan: that path
        /// pops each entity off `scene_entities` itself before calling
        /// `destroyEntityOnly`, so the entity is already gone from the
        /// list and the scan would walk the whole remaining list finding
        /// nothing — N destroys × O(N) = O(N²). Skipping it keeps the
        /// drain O(N) without changing which entities get destroyed (#630).
        pub fn untrackSceneEntity(self: *Game, entity: Entity) void {
            // Skip the scan ONLY for the entity the drain is currently
            // popping (already off the list — scanning is the O(N²) waste
            // #630 fixes). Any OTHER tracked entity (e.g. a sibling
            // destroyed by this one's `entity_destroyed` hook) must still
            // untrack, or the drain would pop it again and double-destroy it.
            if (self.current_teardown_entity) |cur| {
                if (cur == entity) return;
            }
            var i: usize = 0;
            while (i < self.scene_entities.items.len) : (i += 1) {
                if (self.scene_entities.items[i] == entity) {
                    _ = self.scene_entities.swapRemove(i);
                    return;
                }
            }
        }
    };
}
