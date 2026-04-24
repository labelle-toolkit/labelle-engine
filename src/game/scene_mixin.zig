/// Scene mixin — scene registration, loading, transitions, and lifecycle.
const std = @import("std");

/// Possible outcomes of the asset-manifest gate fired at the start
/// of `setScene`/`setSceneAtomic` (Phase 2 of the Asset Streaming
/// RFC #437). `proceed` lets the swap continue; `not_ready` defers
/// the swap until the next call (the script is expected to poll
/// `setScene` every frame). The two failure variants are kept
/// separate because they carry different severity:
///   - `acquire_error` — `catalog.acquire` itself failed (e.g. the
///     asset wasn't registered, or the worker couldn't be spawned).
///     Always a bug in the caller or platform layer; bypasses
///     `asset_failure_policy` and is always fatal.
///   - `asset_error` — `catalog.anyFailed` reports a manifest entry
///     in `.failed` state. Subject to `asset_failure_policy`
///     (fatal / warn / silent).
const ManifestGate = union(enum) {
    proceed,
    not_ready,
    acquire_error: anyerror,
    asset_error: anyerror,
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
                return .{ .acquire_error = err };
            };
        }
        if (game.pending_scene_assets) |old| game.allocator.free(old);
        game.pending_scene_assets = game.allocator.dupe(u8, target_name) catch null;
    }

    if (game.assets.anyFailed(target_assets)) |err| return .{ .asset_error = err };
    if (!game.assets.allReady(target_assets)) return .not_ready;
    return .proceed;
}

/// Run the gate and interpret the result. Returns `true` iff the
/// caller should proceed with the swap. Returns `false` when the
/// swap must be deferred (manifest still decoding, or a `.warn` /
/// `.silent` policy swallowed an asset failure but other assets
/// in the manifest are not yet `.ready`). `acquire_error` always
/// bubbles — it signals a bug upstream, not an expected load
/// failure, so `asset_failure_policy` does not apply.
fn gateOrDefer(
    game: anytype,
    caller_tag: []const u8,
    target_name: []const u8,
    target_assets: []const []const u8,
) !bool {
    switch (gateOnManifest(game, target_name, target_assets)) {
        .proceed => return true,
        .not_ready => return false,
        .acquire_error => |err| {
            rollbackPendingAssets(game);
            return err;
        },
        .asset_error => |err| {
            try handleAssetFailure(game, caller_tag, target_name, err);
            // Policy was `.warn` or `.silent` — the failed asset is
            // OK to ship with, but other entries in the manifest
            // might still be in flight (`.queued` / `.decoding`).
            // Proceeding now would pop the scene up with half-loaded
            // assets. Defer until every manifest entry reaches a
            // terminal state — `.ready` (usable) or `.failed`
            // (policy already said this is OK).
            for (target_assets) |n| {
                if (game.assets.entries.getPtr(n)) |e| {
                    if (e.state != .ready and e.state != .failed) return false;
                }
            }
            return true;
        },
    }
}

/// Release every asset in `assets`. Called from the success path
/// of both `setScene` variants with the outgoing scene's manifest
/// slice (looked up once by the caller — no second `scenes.get`).
fn releasePreviousAssets(game: anytype, assets: []const []const u8) void {
    for (assets) |asset_name| game.assets.release(asset_name);
}

/// Consults `game.asset_failure_policy` when the manifest gate
/// reports an asset in `.failed` state (the `anyFailed` path —
/// `acquire` errors are routed separately and bypass this helper).
/// `.fatal` rolls back and bubbles the error; `.warn` logs and
/// swallows; `.silent` swallows without logging. `caller_tag`
/// distinguishes the log message between `setScene` and
/// `setSceneAtomic` entry points.
fn handleAssetFailure(game: anytype, caller_tag: []const u8, target_name: []const u8, err: anyerror) !void {
    switch (game.asset_failure_policy) {
        .fatal => {
            rollbackPendingAssets(game);
            return err;
        },
        .warn => {
            game.log.warn(
                "{s}('{s}'): asset load failure ({s}) — proceeding under .warn policy",
                .{ caller_tag, target_name, @errorName(err) },
            );
        },
        .silent => {},
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

/// Bridge catalog-uploaded image assets into `atlas_manager` so
/// the renderer's `findSprite` lookup returns the right texture
/// id. Without this the catalog owns the texture (and the renderer
/// has it via labelle-gfx#248's `registerCatalogTexture`), but
/// `atlas.texture_id` stays at 0 — `findSprite` returns 0,
/// `resolveAtlasSprites` writes 0 into every sprite, and all
/// non-first atlases render with the wrong UVs (the jumper sprite
/// would sample from sprites.png because its atlas's texture_id
/// is the same default 0 as sprites.png's).
///
/// Idempotent — `markPendingLoaded` errors with `AtlasNotPending`
/// for already-bridged atlases; we silently ignore.
fn bridgeImageAssetsToAtlasManager(game: anytype, assets: []const []const u8) void {
    for (assets) |asset_name| {
        const entry = game.assets.entries.getPtr(asset_name) orelse continue;
        if (entry.loader_kind != .image) continue;
        const resource = entry.resource orelse continue;
        const handle = switch (resource) {
            .image => |t| t,
            else => continue,
        };
        // Bridge is best-effort — already-loaded atlases return
        // AtlasNotPending, missing atlases return AtlasNotFound.
        // Both are normal: the first means we already bridged on
        // an earlier setScene; the second means the asset name
        // doesn't correspond to a registered atlas (e.g. audio).
        game.atlas_manager.markPendingLoaded(asset_name, handle, null) catch {};
    }
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
            if (!try gateOrDefer(self, "setScene", name, target_assets)) return;

            // Bridge catalog-uploaded image handles into
            // atlas_manager so findSprite can return the right
            // texture id. See `bridgeImageAssetsToAtlasManager`
            // for the full failure mode this prevents.
            bridgeImageAssetsToAtlasManager(self, target_assets);

            // Capture the previous scene name BEFORE we wipe
            // `current_scene_name` — we need it to release the
            // outgoing manifest after the swap completes.
            const previous_name = if (self.current_scene_name) |n| self.allocator.dupe(u8, n) catch null else null;
            defer if (previous_name) |p| self.allocator.free(p);

            // Fire `scene_assets_acquire` at the "we own the new
            // manifest and are about to swap" moment — after the
            // gate proved allReady, before any scene teardown. This
            // gives listeners a chance to cache the manifest and
            // react before `scene_before_load` fires.
            self.emitHook(.{ .scene_assets_acquire = .{ .name = name, .assets = target_assets } });

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
            // get freed-then-reloaded. The scene-entry lookup
            // happens once here and the resulting slice is shared
            // between the release hook (which lets listeners read
            // the final refcount state) and the release loop.
            if (previous_name) |p| {
                const prev_assets: []const []const u8 = if (self.scenes.get(p)) |e| e.assets else &.{};
                self.emitHook(.{ .scene_assets_release = .{ .name = p, .assets = prev_assets } });
                releasePreviousAssets(self, prev_assets);
            }
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
            if (!try gateOrDefer(self, "setSceneAtomic", name, entry.assets)) return;

            bridgeImageAssetsToAtlasManager(self, entry.assets);

            const previous_name = if (self.current_scene_name) |n| self.allocator.dupe(u8, n) catch null else null;
            defer if (previous_name) |p| self.allocator.free(p);

            self.emitHook(.{ .scene_assets_acquire = .{ .name = name, .assets = entry.assets } });

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

            // `scene_before_reset` fires right before the ECS is
            // wiped. Plugin controllers with per-world heap state
            // (pointed at by a singleton `state_ptr` component) MUST
            // free it here — once `resetEcsBackend` runs, the
            // singleton entity is destroyed and the pointer is
            // orphaned forever, causing every downstream `.apply`
            // call to either leak allocations across loads or
            // panic on a null `findState` (flying-platform-labelle
            // #290). Fires on both the F8 scene-restart path and
            // the F9 save/load path (the latter also emits this
            // before its own reset in `save_load_mixin.zig`).
            const outgoing = previous_name orelse "";
            self.emitHook(.{ .scene_before_reset = .{ .name = outgoing } });

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

            if (previous_name) |p| {
                const prev_assets: []const []const u8 = if (self.scenes.get(p)) |e| e.assets else &.{};
                self.emitHook(.{ .scene_assets_release = .{ .name = p, .assets = prev_assets } });
                releasePreviousAssets(self, prev_assets);
            }
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
