//! Post-load render gate — the transient re-bind machinery (#637/#638).
//!
//! Extracted verbatim from `save_load/load.zig`; behaviour is identical.
//! This is the "transient" half of the load path: `loadGameState` restores
//! every saved entity synchronously, but a prefab re-spawned in Phase 1a
//! re-registers its atlas through the streaming catalog and re-queues an
//! async decode/upload. Until those atlases re-bind, the restored sprites
//! would sample an unbound texture — the corruption flash this machinery
//! suppresses. It holds the world render for the (short) window between a
//! load and the atlases' re-bind, then releases in the same frame nothing
//! is unbound.
//!
//! Split out of the reader because it's a distinct concern with its own
//! lifecycle (armed at the end of a load, ticked per-frame from `tick`,
//! released on the next load / on teardown) and touches none of the
//! reader's rehydration seams — only `Game`'s gate fields, the asset
//! catalog, and the atlas manager. `loadGameState` reaches back into it
//! through `self.armPostLoadRenderGate(...)` (aliased onto `Game` in
//! `game.zig`), so no reader ↔ gate import edge is needed.
//!
//! Public surface (3 fns), re-exported unchanged by `save_load_mixin.zig`:
//!   * `armPostLoadRenderGate`    — arm the gate from a scene manifest.
//!   * `updatePostLoadRenderGate` — per-tick settle check.
//!   * `releaseLoadAcquired`      — drop the manifest a load pinned.

pub fn Mixin(comptime Game: type) type {
    return struct {
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
