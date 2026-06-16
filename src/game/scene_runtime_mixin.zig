/// Scene-runtime mixin — the engine-level pause flag (#465) and the
/// active-scene runtime plumbing: unload-on-swap, the type-erased active
/// scene registration, and the named-entity / add / clear forwarders.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. `setPaused`
/// and `unloadCurrentScene` reach `emitHook` / `emitEngineEvent` /
/// `teardownActiveScene` / `destroyEntityOnly` through the `Game`
/// re-exports.

/// Returns the scene-runtime mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const has_events = Game.GameEvents != void;
    const std = @import("std");

    return struct {
        // ── Pause flag (#465) ───────────────────────────────────────

        /// Set the engine-level pause flag. Emits `pause_changed` when
        /// the value transitions; idempotent if already at `paused`.
        ///
        /// Intended to be called from a game-side sync script that
        /// mirrors a game-owned `GamePaused` component (or equivalent)
        /// into the engine, so plugin-shipped scripts can gate via
        /// `game.isPaused()` without importing game components.
        pub fn setPaused(self: *Game, paused: bool) void {
            if (self.paused == paused) return;
            self.paused = paused;
            self.emitHook(.{ .pause_changed = .{ .paused = paused } });
            // Engine `Events` dual-emit (#578).
            self.emitEngineEvent("engine__pause_changed", .{ .paused = paused });
        }

        /// Read the engine-level pause predicate. Returns true if
        /// *either* the explicit `paused` flag is set OR `time_scale`
        /// is zero — both are valid pause mechanisms and tick gating
        /// should honour both uniformly.
        ///
        /// Plugin scripts should use this instead of reaching for a
        /// game-side `GamePaused` component — the latter would couple
        /// plugin code to the game's component types across module
        /// boundaries.
        pub fn isPaused(self: *const Game) bool {
            return self.paused or self.time_scale == 0;
        }

        // ── Active scene runtime ──────────────────────────────────

        pub fn unloadCurrentScene(self: *Game) void {
            if (has_events) self.event_buffer.clearRetainingCapacity();
            if (self.current_scene_name) |name| {
                self.emitHook(.{ .scene_unload = .{ .name = name } });
                // Engine `Events` dual-emit (#578).
                self.emitEngineEvent("engine__scene_unloaded", .{ .name = name });
                if (self.scenes.get(name)) |entry| {
                    if (entry.hooks.onUnload) |onUnload| {
                        onUnload(self);
                    }
                }
            }
            // Destroy every entity the outgoing scene's loader created.
            // `destroyEntityOnly` skips the children-recursion so a parent
            // destroy doesn't double-free an already-listed child, and it
            // calls `untrackSceneEntity` which would swap-remove from this
            // same list. We `pop()` each entry off the end ourselves, so
            // the per-entity untrack has nothing left to find — its scan
            // would walk the whole remaining list every call, making the
            // drain O(N²). The `tearing_down_scene` guard makes that scan
            // a no-op for the duration of the loop, so the drain is O(N).
            // Behaviour is unchanged: every tracked entity is still popped
            // and passed to `destroyEntityOnly` exactly once, so the
            // `entity_destroyed` hooks fire identically — we only skip a
            // redundant search that was guaranteed to find nothing. The
            // `defer` restores the flag even if a hook panics. (#630)
            self.tearing_down_scene = true;
            defer self.tearing_down_scene = false;
            while (self.scene_entities.pop()) |entity| {
                self.destroyEntityOnly(entity);
            }

            // Scene deinit destroys non-persistent entities (which untracks them
            // from the renderer). Persistent entities remain in ECS + renderer.
            self.teardownActiveScene();
        }

        /// Store a type-erased active scene. Called by sceneLoaderFn to hand
        /// the heap-allocated Scene to the engine for lifecycle management.
        pub fn setActiveScene(
            self: *Game,
            ptr: *anyopaque,
            update_fn: *const fn (*anyopaque, f32) void,
            deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
            get_entity_fn: ?*const fn (*anyopaque, []const u8) ?Entity,
            add_entity_fn: ?*const fn (*anyopaque, Entity) void,
            clear_entities_fn: ?*const fn (*anyopaque) void,
        ) void {
            self.teardownActiveScene();
            self.active_scene_ptr = ptr;
            self.active_scene_update_fn = update_fn;
            self.active_scene_deinit_fn = deinit_fn;
            self.active_scene_get_entity_fn = get_entity_fn;
            self.active_scene_add_entity_fn = add_entity_fn;
            self.active_scene_clear_entities_fn = clear_entities_fn;
        }

        /// Look up a named entity from the active scene.
        pub fn getEntityByName(self: *const Game, name: []const u8) ?Entity {
            if (self.active_scene_ptr) |ptr| {
                if (self.active_scene_get_entity_fn) |get_fn| {
                    return get_fn(ptr, name);
                }
            }
            return null;
        }

        /// Register a runtime-created entity with the active scene.
        pub fn addEntityToActiveScene(self: *Game, entity: Entity) void {
            if (self.active_scene_ptr) |ptr| if (self.active_scene_add_entity_fn) |add_fn| {
                add_fn(ptr, entity);
            };
        }

        /// Remove all entities from the active scene's entity list.
        /// Does NOT destroy ECS entities — caller handles that.
        pub fn clearActiveSceneEntities(self: *Game) void {
            if (self.active_scene_ptr) |ptr| if (self.active_scene_clear_entities_fn) |clear_fn| {
                clear_fn(ptr);
            };
        }
    };
}
