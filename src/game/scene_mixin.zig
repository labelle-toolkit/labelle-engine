/// Scene mixin — scene registration, loading, transitions, and lifecycle.
const std = @import("std");
const builtin = @import("builtin");

/// Collect every asset name currently registered in the catalog into a
/// fresh allocator-owned slice. The returned slice borrows the name
/// pointers from the catalog — they're string literals from the
/// assembler-emitted `register` calls (program-lifetime), so the caller
/// only needs to free the slice itself.
///
/// Used by `setScene` / `setSceneAtomic`'s dev-mode eager-fallback
/// (issue #502): when a scene declares no `assets:`, in Debug builds we
/// load every project resource so the scene renders without forcing
/// the developer to author a manifest just to peek at it. Production
/// builds keep the strict explicit-declaration behavior.
fn collectAllRegisteredAssetNames(allocator: std.mem.Allocator, catalog: anytype) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.ensureTotalCapacityPrecise(allocator, catalog.entries.count());
    var iter = catalog.entries.keyIterator();
    while (iter.next()) |key| {
        try list.append(allocator, key.*);
    }
    return list.toOwnedSlice(allocator);
}

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

/// Acquire any not-yet-acquired assets in `target_assets`. Idempotent
/// across frames via `game.pending_scene_assets`. Used by both the
/// readiness gate (`gateOnManifest`) and the dev-mode eager-fallback
/// (`acquireImmediately`) — separates the acquire batch from the
/// classify step so the eager-fallback can skip the `allReady` wait
/// without duplicating the rollback logic. See issue #506.
fn acquireBatch(game: anytype, target_name: []const u8, target_assets: []const []const u8) !void {
    const already_acquired = if (game.pending_scene_assets) |p|
        std.mem.eql(u8, p, target_name)
    else
        false;
    if (already_acquired) return;

    for (target_assets) |asset_name| {
        _ = game.assets.acquire(asset_name) catch |err| {
            // Roll back any prior acquires in this batch.
            for (target_assets) |rb| {
                if (game.assets.entries.getPtr(rb)) |e| {
                    if (e.refcount > 0) game.assets.release(rb);
                }
            }
            return err;
        };
    }
    if (game.pending_scene_assets) |old| game.allocator.free(old);
    game.pending_scene_assets = game.allocator.dupe(u8, target_name) catch null;
}

/// Acquire any not-yet-acquired assets in `target_assets`, then
/// classify the current state. Idempotent across frames via
/// `game.pending_scene_assets` — same scene name = same acquire
/// call once, no matter how many frames the caller polls.
fn gateOnManifest(game: anytype, target_name: []const u8, target_assets: []const []const u8) ManifestGate {
    if (target_assets.len == 0) return .proceed;

    acquireBatch(game, target_name, target_assets) catch |err| {
        return .{ .acquire_error = err };
    };

    if (game.assets.anyFailed(target_assets)) |err| return .{ .asset_error = err };
    if (!game.assets.allReady(target_assets)) return .not_ready;
    return .proceed;
}

/// Acquire-and-proceed counterpart to `gateOnManifest`. Used by the
/// dev-mode eager-fallback (#502/#503) to skip the `allReady` wait —
/// no retrier exists for non-`main` scenes (issue #506) and pop-in is
/// acceptable in Debug. Production-path scenes with declared
/// manifests still go through `gateOnManifest` and its readiness
/// gate. The acquire-batch error path remains the same.
fn acquireImmediately(game: anytype, target_name: []const u8, target_assets: []const []const u8) !void {
    if (target_assets.len == 0) return;
    try acquireBatch(game, target_name, target_assets);
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

/// Walks every `.image` asset currently in `.ready` state and bridges
/// it into `atlas_manager`. Idempotent via `markPendingLoaded` (already-
/// bridged atlases return `AtlasNotPending`, silently skipped).
///
/// Called every tick after the catalog pump (`Game.tick`'s pump call)
/// so atlases that finish uploading AFTER the manifest-gate path's
/// `bridgeImageAssetsToAtlasManager` call still get their texture_id
/// wired before `resolveAtlasSprites` runs in the same frame.
///
/// Without this per-tick walk, the eager-fallback path (#502/#503/#506)
/// — which intentionally completes setScene before assets reach
/// `.ready` — leaves every atlas's texture_id at 0. `findSprite`
/// returns 0, every sprite samples from texture 0, and the world
/// renders with all-wrong UVs (issue #508).
///
/// For the production manifest-gated path this walk is redundant
/// (assets are already `.ready` at setScene time, the bridge ran
/// once and succeeded) — every per-tick call is a no-op. Cost is
/// one HashMap iteration per frame; the catalog typically holds
/// <20 entries.
fn bridgeAllReadyImageAssets_impl(game: anytype) void {
    var iter = game.assets.entries.iterator();
    while (iter.next()) |kv| {
        const entry = kv.value_ptr;
        if (entry.loader_kind != .image) continue;
        if (entry.state != .ready) continue;
        const resource = entry.resource orelse continue;
        const handle = switch (resource) {
            .image => |t| t,
            else => continue,
        };
        game.atlas_manager.markPendingLoaded(kv.key_ptr.*, handle, null) catch {};
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

        /// Bridge late-uploaded atlases on every tick (issue #508).
        /// Game.tick should call this after `self.assets.pump()` so
        /// atlases finishing upload this frame are wired before
        /// `resolveAtlasSprites` runs. See the free fn for details.
        pub fn bridgeAllReadyImageAssets(self: *Game) void {
            bridgeAllReadyImageAssets_impl(self);
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

        /// Attach a declared `initial_state` to a previously-registered scene.
        /// `setScene` will call `setState(state)` after the scene loads.
        ///
        /// Returns `error.SceneNotFound` if `name` was never registered.
        ///
        /// Used by the assembler to thread each scene's `"initial_state": "<name>"`
        /// JSONC field into `SceneEntry.initial_state` (issue #500). Same setter
        /// pattern as `setSceneAssets` so the assembler can call both after the
        /// `registerSceneSimple` loop.
        ///
        /// Lifetime: `state` is stored by reference and must outlive the `Game`.
        /// The assembler emits a string-literal slice (program-lifetime). Runtime
        /// callers passing a stack-allocated slice would leave
        /// `SceneEntry.initial_state` dangling — prefer an allocator-owned or
        /// static slice.
        pub fn setSceneInitialState(
            self: *Game,
            name: []const u8,
            state: []const u8,
        ) error{SceneNotFound}!void {
            const entry = self.scenes.getPtr(name) orelse return error.SceneNotFound;
            entry.initial_state = state;
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
            const declared_assets: []const []const u8 = if (self.scenes.get(name)) |e|
                e.assets
            else
                &.{};

            // Dev-mode eager-load fallback (issue #502) — if the scene
            // declared no assets and we're a Debug build, load every
            // registered project resource so the scene renders without
            // forcing the developer to author a manifest just to peek
            // at it. Production builds keep the silent-black behavior:
            // a missing manifest there is a real bug that should be
            // caught during smoke tests, not papered over.
            //
            // The collected slice is freed at end-of-function. Names
            // inside it are borrows of the catalog's keys (string
            // literals from the assembler-emitted register calls), so
            // they outlive this call comfortably.
            var eager_buf: ?[][]const u8 = null;
            defer if (eager_buf) |b| self.allocator.free(b);
            const target_assets: []const []const u8 = if (declared_assets.len == 0 and comptime builtin.mode == .Debug) blk: {
                const all = collectAllRegisteredAssetNames(self.allocator, &self.assets) catch break :blk declared_assets;
                if (all.len == 0) {
                    self.allocator.free(all);
                    break :blk declared_assets;
                }
                std.log.info("[Scene] '{s}' has no manifest, eager-loaded {d} resources (Debug build)", .{ name, all.len });
                eager_buf = all;
                break :blk @as([]const []const u8, all);
            } else declared_assets;

            // Manifest gate: eager-fallback skips the allReady wait
            // and proceeds with whatever's currently loaded, accepting
            // progressive atlas pop-in. The assembler-emitted main.zig
            // calls setScene exactly once at startup, and there's no
            // retrier for non-main scenes — without this branch, an
            // eager-fallback that defers stays pending forever (issue
            // #506). Production scenes with declared manifests still
            // go through the full gate.
            if (eager_buf != null) {
                try acquireImmediately(self, name, target_assets);
            } else if (!try gateOrDefer(self, "setScene", name, target_assets)) return;

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

            // Honor the scene's declared `initial_state` (issue #500).
            // This runs LAST so all the scene's entities + scripts are
            // in place when state-gated scripts start ticking on the
            // next frame. Logging the transition makes scene-driven
            // state changes visible — anyone debugging the state
            // machine can grep for `[Scene] '<name>' set state`.
            if (self.scenes.get(name)) |entry| {
                if (entry.initial_state) |state| {
                    if (!std.mem.eql(u8, self.game_state, state)) {
                        std.log.info("[Scene] '{s}' set state '{s}' → '{s}'", .{ name, self.game_state, state });
                    }
                    self.setState(state);
                }
            }
        }

        /// Load a scene using resetEcsBackend for atomic world reset.
        /// Avoids per-entity teardown and zig-ecs destruction signal issues (#388).
        /// Clears the scene entity list first so Scene.deinit skips entity destruction,
        /// then resets the ECS atomically, then loads the new scene.
        pub fn setSceneAtomic(self: *Game, name: []const u8) !void {
            const entry = self.scenes.get(name) orelse return error.SceneNotFound;

            // Dev-mode eager-load fallback (issue #502) — same logic as
            // setScene, kept in sync. See setScene for the full rationale.
            var eager_buf: ?[][]const u8 = null;
            defer if (eager_buf) |b| self.allocator.free(b);
            const target_assets: []const []const u8 = if (entry.assets.len == 0 and comptime builtin.mode == .Debug) blk: {
                const all = collectAllRegisteredAssetNames(self.allocator, &self.assets) catch break :blk entry.assets;
                if (all.len == 0) {
                    self.allocator.free(all);
                    break :blk entry.assets;
                }
                std.log.info("[Scene] '{s}' has no manifest, eager-loaded {d} resources (Debug build)", .{ name, all.len });
                eager_buf = all;
                break :blk @as([]const []const u8, all);
            } else entry.assets;

            // Manifest gate — see `setScene` for the full
            // explanation. Both entry points participate in the
            // same idempotent acquire/release cycle so callers can
            // mix `setScene` and `setSceneAtomic` without confusing
            // the gate.
            //
            // Eager-fallback skips allReady (issue #506); see setScene
            // for the rationale.
            if (eager_buf != null) {
                try acquireImmediately(self, name, target_assets);
            } else if (!try gateOrDefer(self, "setSceneAtomic", name, target_assets)) return;

            bridgeImageAssetsToAtlasManager(self, target_assets);

            const previous_name = if (self.current_scene_name) |n| self.allocator.dupe(u8, n) catch null else null;
            defer if (previous_name) |p| self.allocator.free(p);

            self.emitHook(.{ .scene_assets_acquire = .{ .name = name, .assets = target_assets } });

            // `scene_before_reset` fires BEFORE any entity
            // destruction — plugin controllers with per-world heap
            // state (pointed at by a singleton `state_ptr`
            // component) MUST be able to locate their singleton
            // entity at this point to free the heap allocation.
            // Once `unloadCurrentScene` / `resetEcsBackend` runs
            // the pointer is orphaned forever, causing every
            // downstream `.apply` call to either leak or panic on
            // a null `findState` (flying-platform-labelle #290).
            //
            // Only emit if there's an outgoing scene — a first
            // `setSceneAtomic` call from a fresh Game has nothing
            // to tear down, and firing with an empty name payload
            // would force listeners to handle a sentinel.
            //
            // Read from `self.current_scene_name` directly rather
            // than the `previous_name` dupe allocated at line 337:
            // that dupe's `catch null` fallback silently swallows
            // OOM, and if OOM did hit there, using `previous_name`
            // would skip the cleanup hook at exactly the moment
            // cleanup matters most (the caller is already under
            // memory pressure, so plugin-controller heap state
            // MUST be freed to make room). `current_scene_name`
            // is still intact here and survives OOM elsewhere.
            //
            // This fires BEFORE the tracking-list clears + the
            // `unloadCurrentScene` iteration below so listeners
            // see the full pre-teardown world. Mirrors the
            // ordering in `save_load_mixin.zig::loadGameState`.
            if (self.current_scene_name) |outgoing| {
                self.emitHook(.{ .scene_before_reset = .{ .name = outgoing } });
            }

            // Clear both entity-tracking lists BEFORE
            // `unloadCurrentScene` so its iteration loop has
            // nothing to destroy individually — `resetEcsBackend`
            // wipes everything atomically a few lines down. Same
            // reason `loadGameState` clears `scene_entities` up
            // front: if we let `unloadCurrentScene` destroy
            // entities one-by-one, a listener that freed heap
            // state on `scene_before_reset` would have already
            // done its work, but the per-entity `entity_destroyed`
            // hooks would still fire against the torn-down ECS.
            // Clearing the lists up front keeps the contract
            // clean: `scene_before_reset` ↔ full world, then a
            // single atomic reset, then fresh load.
            self.scene_entities.clearRetainingCapacity();
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

            if (previous_name) |p| {
                const prev_assets: []const []const u8 = if (self.scenes.get(p)) |e| e.assets else &.{};
                self.emitHook(.{ .scene_assets_release = .{ .name = p, .assets = prev_assets } });
                releasePreviousAssets(self, prev_assets);
            }
            if (self.pending_scene_assets) |p| {
                self.allocator.free(p);
                self.pending_scene_assets = null;
            }

            // Honor the scene's declared `initial_state` (issue #500).
            // Mirrors `setScene` — keep the two paths in sync so a scene
            // loaded via `setSceneAtomic` (or `queueSceneChangeAtomic`)
            // gets the same state-transition treatment as `setScene`.
            // `entry` is already in scope (line 365) so no re-lookup.
            if (entry.initial_state) |state| {
                if (!std.mem.eql(u8, self.game_state, state)) {
                    std.log.info("[Scene] '{s}' set state '{s}' → '{s}'", .{ name, self.game_state, state });
                }
                self.setState(state);
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

        /// Returns the name of the scene currently being loaded — i.e. the
        /// `setScene`/`setSceneAtomic` target whose asset-manifest gate
        /// is still deferring (atlases decoding, etc.). Returns `null`
        /// when no swap is in flight.
        ///
        /// Distinct from `getCurrentSceneName()`, which returns the
        /// COMMITTED scene (the one whose entities + scripts are
        /// active). During the asset-loading deferral period:
        ///   - `getCurrentSceneName()` returns the previous scene
        ///     (or `null` on initial boot)
        ///   - `pendingSceneName()` returns the requested scene
        ///
        /// Consumers writing scene-aware recovery code (e.g. "if no
        /// scene is loaded, set this default scene") should check both:
        ///
        ///   const intended = game.getCurrentSceneName() orelse
        ///       game.pendingSceneName() orelse return;
        ///
        /// Otherwise their recovery races with the deferred swap and
        /// can hijack the user's requested scene before it lands —
        /// see issue #504 for the surfaced case.
        pub fn pendingSceneName(self: *const Game) ?[]const u8 {
            return self.pending_scene_assets;
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
