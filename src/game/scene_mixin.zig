/// Scene mixin — scene registration, loading, transitions, and lifecycle.
const std = @import("std");

/// Possible outcomes of the asset-manifest gate fired at the start
/// of `setScene`/`setSceneAtomic` (Phase 2 of the Asset Streaming
/// RFC #437). `proceed` lets the swap continue; `not_ready` defers
/// the swap until the next call (the script is expected to poll
/// `setScene` every frame); `failed` aborts the swap with the
/// underlying load error.
const ManifestGate = union(enum) {
    proceed,
    not_ready,
    failed: anyerror,
};

/// Acquire any not-yet-acquired assets in `target_assets`, then
/// classify the current state. Idempotent across frames via
/// `game.pending_scene_assets` — same scene name = same acquire
/// call once, no matter how many frames the caller polls.
fn gateOnManifest(game: anytype, target_name: []const u8, target_assets: []const []const u8) ManifestGate {
    if (target_assets.len == 0) return .proceed;

    const already_acquired = if (game.pending_scene_assets) |p|
        std.mem.eql(u8, p, target_name)
    else
        false;

    if (!already_acquired) {
        for (target_assets) |asset_name| {
            _ = game.assets.acquire(asset_name) catch |err| {
                // Roll back any prior acquires in this batch.
                for (target_assets) |rb| {
                    if (game.assets.entries.getPtr(rb)) |e| {
                        if (e.refcount > 0) game.assets.release(rb);
                    }
                }
                return .{ .failed = err };
            };
        }
        if (game.pending_scene_assets) |old| game.allocator.free(old);
        game.pending_scene_assets = game.allocator.dupe(u8, target_name) catch null;
    }

    if (game.assets.anyFailed(target_assets)) |err| return .{ .failed = err };
    if (!game.assets.allReady(target_assets)) return .not_ready;
    return .proceed;
}

/// Release the previous scene's asset manifest after a successful
/// swap. Called from the success path of both setScene variants.
fn releasePreviousAssets(game: anytype, prev_name: []const u8) void {
    if (game.scenes.get(prev_name)) |entry| {
        for (entry.assets) |asset_name| game.assets.release(asset_name);
    }
}

/// Roll back the acquire batch on failure / abort. Frees the
/// `pending_scene_assets` marker so the next setScene call starts
/// from scratch.
fn rollbackPendingAssets(game: anytype) void {
    const target_name = game.pending_scene_assets orelse return;
    if (game.scenes.get(target_name)) |entry| {
        for (entry.assets) |asset_name| game.assets.release(asset_name);
    }
    game.allocator.free(target_name);
    game.pending_scene_assets = null;
}

/// Returns the scene management mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        pub fn registerScene(
            self: *Game,
            comptime name: []const u8,
            comptime loader_fn: fn (*Game) anyerror!void,
            hooks_val: Game.SceneHooks,
        ) void {
            const wrapper = struct {
                fn load(game: *Game) anyerror!void {
                    return loader_fn(game);
                }
            }.load;
            self.scenes.put(name, .{
                .loader_fn = wrapper,
                .hooks = hooks_val,
            }) catch {};
        }

        pub fn registerSceneSimple(
            self: *Game,
            comptime name: []const u8,
            comptime loader_fn: fn (*Game) anyerror!void,
        ) void {
            self.registerScene(name, loader_fn, .{});
        }

        /// Register a scene together with its declared asset manifest.
        /// Manifest-aware overload emitted by the assembler for scenes with
        /// an `"assets": [...]` block. Delegates to `registerSceneSimple`
        /// so any future change to scene-entry construction only lives in
        /// one place, then attaches the slice via `getPtr`.
        ///
        /// Lifetime: `assets` is stored by reference on the `SceneEntry`
        /// and must outlive the `Game`. The assembler passes a file-scope
        /// slice from `SceneAssetManifests.entries` in the generated
        /// `main.zig`, which is program-lifetime. Runtime callers passing
        /// a stack-allocated slice would leave `SceneEntry.assets`
        /// dangling — prefer an allocator-owned or static slice.
        pub fn registerSceneWithAssets(
            self: *Game,
            comptime name: []const u8,
            comptime loader_fn: fn (*Game) anyerror!void,
            assets: []const []const u8,
        ) void {
            self.registerSceneSimple(name, loader_fn);
            if (self.scenes.getPtr(name)) |entry| {
                entry.assets = assets;
            }
        }

        /// Attach an asset manifest to a previously-registered scene.
        /// Returns `error.SceneNotFound` if `name` was never registered.
        /// Used by the assembler to thread `SceneAssetManifests.entries` into
        /// `SceneEntry.assets` after the normal `registerSceneSimple` loop
        /// (keeps the codegen diff to a single extra inline-for in the
        /// generated `main.zig`). Scripts can then read
        /// `game.scenes.get("main").?.assets` at runtime.
        ///
        /// Lifetime: `assets` is stored by reference and must outlive the
        /// `Game`. See `registerSceneWithAssets` for the usual caller
        /// pattern (file-scope slice from `SceneAssetManifests.entries`).
        pub fn setSceneAssets(
            self: *Game,
            name: []const u8,
            assets: []const []const u8,
        ) error{SceneNotFound}!void {
            const entry = self.scenes.getPtr(name) orelse return error.SceneNotFound;
            entry.assets = assets;
        }

        pub fn setScene(self: *Game, name: []const u8) !void {
            // Phase 2 of the Asset Streaming RFC (#437) — gate the
            // swap on the new scene's `assets:` manifest. Acquires
            // (idempotently across frames) any not-yet-loaded assets,
            // then either proceeds (allReady), defers (still
            // decoding), or aborts (failed). Empty manifests skip
            // the gate entirely. Scenes registered via the legacy
            // `registerSceneSimple` (no manifest) have `assets ==
            // &.{}` and behave identically to before this change.
            const target_assets: []const []const u8 = if (self.scenes.get(name)) |e|
                e.assets
            else
                &.{};
            switch (gateOnManifest(self, name, target_assets)) {
                .proceed => {},
                .not_ready => return,
                .failed => |err| {
                    rollbackPendingAssets(self);
                    return err;
                },
            }

            // Capture the previous scene name BEFORE we wipe
            // `current_scene_name` — we need it to release the
            // outgoing manifest after the swap completes.
            const previous_name = if (self.current_scene_name) |n| self.allocator.dupe(u8, n) catch null else null;
            defer if (previous_name) |p| self.allocator.free(p);

            self.unloadCurrentScene();

            if (self.current_scene_name) |old_name| {
                self.allocator.free(old_name);
                self.current_scene_name = null;
            }

            self.emitHook(.{ .scene_before_load = .{ .name = name, .allocator = self.allocator } });

            if (self.scenes.get(name)) |entry| {
                // Comptime-registered scene
                try entry.loader_fn(self);
                self.current_scene_name = self.allocator.dupe(u8, name) catch null;
                self.emitHook(.{ .scene_load = .{ .name = name } });
                if (entry.hooks.onLoad) |onLoad| {
                    onLoad(self);
                }
            } else if (self.jsonc_scenes.get(name)) |_| {
                // Runtime JSONC scene — loaded at runtime by the game loop
                // The actual loading is deferred: the generated code or game code
                // handles parsing the JSONC file and creating entities.
                self.current_scene_name = self.allocator.dupe(u8, name) catch null;
                self.emitHook(.{ .scene_load = .{ .name = name } });
            } else {
                rollbackPendingAssets(self);
                return error.SceneNotFound;
            }

            // Swap committed — release the OUTGOING manifest and
            // clear the pending marker. Order is acquire-new-then-
            // release-old (RFC §scene transition wiring) so shared
            // assets keep refcount ≥ 1 across the swap and never
            // get freed-then-reloaded.
            if (previous_name) |p| releasePreviousAssets(self, p);
            if (self.pending_scene_assets) |p| {
                self.allocator.free(p);
                self.pending_scene_assets = null;
            }
        }

        /// Load a scene using resetEcsBackend for atomic world reset.
        /// Avoids per-entity teardown and zig-ecs destruction signal issues (#388).
        /// Clears the scene entity list first so Scene.deinit skips entity destruction,
        /// then resets the ECS atomically, then loads the new scene.
        pub fn setSceneAtomic(self: *Game, name: []const u8) !void {
            const entry = self.scenes.get(name) orelse return error.SceneNotFound;

            // Manifest gate — see `setScene` for the full
            // explanation. Both entry points participate in the
            // same idempotent acquire/release cycle so callers can
            // mix `setScene` and `setSceneAtomic` without confusing
            // the gate.
            switch (gateOnManifest(self, name, entry.assets)) {
                .proceed => {},
                .not_ready => return,
                .failed => |err| {
                    rollbackPendingAssets(self);
                    return err;
                },
            }

            const previous_name = if (self.current_scene_name) |n| self.allocator.dupe(u8, n) catch null else null;
            defer if (previous_name) |p| self.allocator.free(p);

            // Clear scene entity list BEFORE deinit so Scene.deinit's entity
            // destruction loop has nothing to iterate (entities will be destroyed
            // atomically by resetEcsBackend instead).
            self.clearActiveSceneEntities();

            // Unload old scene (runs script deinit, fires hooks, frees scene struct)
            self.unloadCurrentScene();

            if (self.current_scene_name) |old_name| {
                self.allocator.free(old_name);
                self.current_scene_name = null;
            }

            // Atomic reset — destroys all entities and visuals without iteration
            self.resetEcsBackend();

            // Load the new scene into the fresh ECS
            self.emitHook(.{ .scene_before_load = .{ .name = name, .allocator = self.allocator } });
            try entry.loader_fn(self);
            self.current_scene_name = self.allocator.dupe(u8, name) catch null;
            self.emitHook(.{ .scene_load = .{ .name = name } });

            if (entry.hooks.onLoad) |onLoad| {
                onLoad(self);
            }

            if (previous_name) |p| releasePreviousAssets(self, p);
            if (self.pending_scene_assets) |p| {
                self.allocator.free(p);
                self.pending_scene_assets = null;
            }
        }

        pub fn queueSceneChange(self: *Game, name: []const u8) void {
            if (self.pending_scene_change) |old| {
                self.allocator.free(old);
            }
            self.pending_scene_change = self.allocator.dupe(u8, name) catch null;
            self.pending_scene_atomic = false;
        }

        /// Queue an atomic scene change for the next frame.
        /// Uses resetEcsBackend to avoid per-entity teardown.
        pub fn queueSceneChangeAtomic(self: *Game, name: []const u8) void {
            if (self.pending_scene_change) |old| {
                self.allocator.free(old);
            }
            self.pending_scene_change = self.allocator.dupe(u8, name) catch null;
            self.pending_scene_atomic = true;
        }

        pub fn getCurrentSceneName(self: *const Game) ?[]const u8 {
            return self.current_scene_name;
        }

        pub fn setActiveScene(
            self: *Game,
            ptr: *anyopaque,
            update_fn: *const fn (*anyopaque, f32) void,
            deinit_fn: *const fn (*anyopaque, std.mem.Allocator) void,
            get_entity_fn: ?*const fn (*anyopaque, []const u8) ?Game.EntityType,
            add_entity_fn: ?*const fn (*anyopaque, Game.EntityType) void,
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
    };
}
