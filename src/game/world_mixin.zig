/// World mixin — multi-world management (create / destroy / swap /
/// rename / query), the ECS-backend reset, and active-scene teardown.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. A "world"
/// bundles ECS, renderer, sprite cache, and arena (`Game.World`); the
/// active world is the live one and inactive worlds are shelved in
/// `game.worlds`.
const std = @import("std");
const builtin = @import("builtin");
const atlas_mod = @import("../atlas.zig");
const gizmo_draws_mod = @import("gizmo_draws.zig");

/// Returns the world management mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const EcsImpl = Game.EcsBackend;
    const World = Game.World;
    const TombstoneEntry = Game.TombstoneEntry;
    const tombstone_size = Game.tombstone_size;
    const is_debug = builtin.mode == .Debug;

    return struct {
        /// Create a new named world. The world is inactive (stored in the map).
        /// Returns error.WorldAlreadyExists if the name is taken.
        pub fn createWorld(self: *Game, name: []const u8) !void {
            if (self.worlds.contains(name)) return error.WorldAlreadyExists;
            const duped = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(duped);
            const world = try self.allocator.create(World);
            errdefer {
                world.deinit();
                self.allocator.destroy(world);
            }
            world.* = World.init(self.allocator);
            try self.worlds.put(duped, world);
        }

        /// Destroy a named inactive world. Frees all its entities and visuals.
        pub fn destroyWorld(self: *Game, name: []const u8) void {
            if (self.worlds.fetchRemove(name)) |kv| {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
                self.allocator.free(kv.key);
            }
        }

        /// Swap the active world. The named world becomes active; the current
        /// active world is shelved into the map (if named) or destroyed (if unnamed).
        /// Verifies the target exists BEFORE modifying any state.
        pub fn setActiveWorld(self: *Game, name: []const u8) !void {
            // Remove target first — guarantees a free slot for shelving the current world
            const kv = self.worlds.fetchRemove(name) orelse return error.WorldNotFound;

            // Shelve or destroy current active world
            if (self.active_world_name) |current_name| {
                // Named world — shelve into map (can't fail: we just freed a slot)
                self.worlds.put(current_name, self.active_world) catch @panic("OOM shelving world");
            } else {
                // Unnamed default world — destroy it
                self.active_world.deinit();
                self.allocator.destroy(self.active_world);
            }

            // Activate the named world
            self.active_world = kv.value;
            self.ecs_backend = &kv.value.ecs_backend;
            self.renderer = &kv.value.renderer;
            self.active_world_name = kv.key;
            // Different world → different entity set; invalidate rosters (#653).
            self.bumpRoster();
        }

        /// Rename an inactive world in the map.
        pub fn renameWorld(self: *Game, old_name: []const u8, new_name: []const u8) !void {
            if (self.worlds.contains(new_name)) return error.WorldAlreadyExists;

            // Dupe new name first (before removing) so failure is safe
            const duped = try self.allocator.dupe(u8, new_name);
            errdefer self.allocator.free(duped);

            if (self.worlds.fetchRemove(old_name)) |kv| {
                self.allocator.free(kv.key);
                self.worlds.put(duped, kv.value) catch {
                    // Restore old entry on failure
                    const restored_key = self.allocator.dupe(u8, old_name) catch @panic("OOM restoring world");
                    self.worlds.put(restored_key, kv.value) catch @panic("OOM restoring world");
                    self.allocator.free(duped);
                    return error.OutOfMemory;
                };
            } else {
                self.allocator.free(duped);
                return error.WorldNotFound;
            }
        }

        /// Get a pointer to an inactive world.
        pub fn getWorld(self: *Game, name: []const u8) ?*World {
            return self.worlds.get(name);
        }

        /// Get the name of the active world (null if unnamed/default).
        pub fn getActiveWorldName(self: *const Game) ?[]const u8 {
            return self.active_world_name;
        }

        /// Check if a world exists in the inactive map.
        pub fn worldExists(self: *const Game, name: []const u8) bool {
            return self.worlds.contains(name);
        }

        pub fn resetEcsBackend(self: *Game) void {
            // Tear down active world's fields (reverse of init order)
            self.gizmo_state.deinit(self.allocator);
            self.active_world.sprite_cache.deinit();
            // Clear renderer entity tracking but keep GPU textures loaded.
            // Textures are expensive to reload (embedded atlas data parsed at startup).
            self.active_world.renderer.clear();
            // Free per-entity tilemap runtimes — the ECS is about to be
            // wiped, so every tilemap entity id becomes a dangling handle
            // (T2 Phase 2). Rehydrated by the incoming scene / load path.
            self.clearTilemaps();
            // Free per-entity particle sims for the same reason (#750): the
            // ECS wipe invalidates every emitter entity id in the side-table.
            self.clearParticleSystems();
            self.active_world.ecs_backend.deinit();
            _ = self.active_world.nested_entity_arena.reset(.retain_capacity);

            // Reinitialize ECS + sprite cache (but NOT renderer — textures preserved)
            self.active_world.ecs_backend = EcsImpl.init(self.allocator);
            self.active_world.sprite_cache = atlas_mod.SpriteCache.init(self.allocator);
            self.gizmo_state = gizmo_draws_mod.GizmoState(Entity).init(self.allocator);
            // Re-sync backward-compatible pointers
            self.ecs_backend = &self.active_world.ecs_backend;
            // The ECS was torn down and rebuilt — invalidate rosters (#653).
            self.bumpRoster();
            // Clear tombstones — old entity IDs are meaningless after ECS reset
            if (comptime is_debug) {
                self.tombstones = [_]?TombstoneEntry{null} ** tombstone_size;
                self.tombstone_cursor = 0;
            }

            // Drop the scene-entity tracking lists. The ECS was just
            // wiped, so every ID those lists held is now a dangling
            // handle. Today's callers (`setSceneAtomic`, `loadGameState`)
            // already `clearRetainingCapacity()` these before calling us,
            // so this is normally a no-op — but a *direct* `resetEcsBackend`
            // would otherwise leave stale IDs that a later
            // `unloadCurrentScene` would feed to `destroyEntityOnly` as
            // invalid handles. Clearing here makes the reset
            // self-consistent and idempotent w.r.t. the callers that
            // already clear (clearing an empty list is fine). Mirrors the
            // atomic path, which clears both the Game-level list and the
            // active scene's own list. (#630)
            self.scene_entities.clearRetainingCapacity();
            self.clearActiveSceneEntities();
        }

        pub fn teardownActiveScene(self: *Game) void {
            if (self.active_scene_ptr) |ptr| {
                if (self.active_scene_deinit_fn) |deinit_fn| {
                    deinit_fn(ptr, self.allocator);
                }
                self.active_scene_ptr = null;
                self.active_scene_update_fn = null;
                self.active_scene_deinit_fn = null;
                self.active_scene_get_entity_fn = null;
                self.active_scene_add_entity_fn = null;
                self.active_scene_clear_entities_fn = null;

                self.active_world.sprite_cache.clear();
                // Free nested entity array allocations from the outgoing scene
                _ = self.active_world.nested_entity_arena.reset(.retain_capacity);
            }
        }
    };
}
