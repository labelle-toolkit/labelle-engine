/// Loop mixin — the per-frame `tick` (clock, scheduler, asset pump,
/// always-run sync block, pause gate, scene/state/hot-reload transitions,
/// lifecycle hooks) and `render`.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. The atlas
/// sprite resolve and input-event scans are reached through their own
/// mixins (`AtlasMixin` / `InputEventsMixin`) instantiated against the same
/// `Game`, matching how `game.zig` invoked them.
const atlas_mixin = @import("atlas_mixin.zig");
const input_events_mixin = @import("input_events_mixin.zig");
const tilemap_mixin = @import("tilemap_mixin.zig");

/// Returns the per-frame loop mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Audio = Game.Audio;
    const Input = Game.Input;
    const EcsImpl = Game.EcsBackend;
    const AtlasMixin = atlas_mixin.Mixin(Game);
    const InputEventsMixin = input_events_mixin.Mixin(Game);
    // Same instantiation `game.zig` uses (generic memoization → identical
    // type); reached here to drive the T3 tilemap Z-interleave render split.
    const TilemapMixin = tilemap_mixin.Mixin(Game);

    return struct {
        pub fn tick(self: *Game, dt: f32) void {
            // FPS / frame-time tracking for the debug inspector (#380).
            // Record the REAL (unscaled) dt every frame — including paused
            // frames that early-return below — so the inspector's FPS
            // readout reflects true render cadence, not gameplay time_scale.
            self.frame_profiler.record(dt);

            const scaled_dt = dt * self.time_scale;
            // Freeze the gameplay clock under EITHER pause path — the
            // `paused` flag (#465) doesn't zero `time_scale`, so guarding
            // on `isPaused()` (paused OR time_scale==0) is what makes a
            // Cooldown/Delay hold behind a pause menu (bugbot/gemini #603).
            if (!self.isPaused()) self.clock_s += @as(f64, scaled_dt);

            // Fire any flow `Delay` timers that have come due (#25 Stage 2).
            // Run this every tick AFTER the clock update. `bindScheduler`
            // keeps the type-erased `game_ctx` pointed at our stable address
            // (idempotent). When paused, `elapsedSeconds()` is frozen, so no
            // timer is ever due — pause-freeze falls out of the clock reuse
            // for free, with no separate accumulator. A firing callback may
            // re-entrantly `after()`; the scheduler iterates defensively.
            self.bindScheduler();
            self.scheduler.tick();

            // Drain any worker-decoded asset uploads onto the GPU.
            // Without this no acquired asset ever reaches `.ready`,
            // and the Phase 2 setScene gate (#458) spins forever in
            // its `not_ready` branch. Pump runs every frame even
            // when paused so loading screens keep filling the bar
            // through pause states.
            self.assets.pump();

            // Wire late-uploaded atlases into atlas_manager (#508). The
            // setScene-time bridge is a no-op for any asset that wasn't
            // .ready yet (eager-fallback path completes setScene before
            // assets reach .ready). Without this per-tick walk those
            // atlases keep texture_id=0, every sprite samples from
            // texture 0, and rendering looks wrong. Idempotent — already-
            // bridged atlases are silently skipped.
            self.bridgeAllReadyImageAssets();

            // Post-load render gate (#637). Runs RIGHT AFTER the bridge
            // so any atlas that re-bound this frame clears the gate the
            // same frame — no extra hidden frame. No-op unless a recent
            // `loadGameState` armed the gate. See `render` below for the
            // suppression side, and the `post_load_render_gate` field doc
            // for the full corruption-flash rationale.
            self.updatePostLoadRenderGate();

            // Always run: logging, audio, input, renderer sync, gizmo reconciliation.
            // These must run even when paused so the game remains responsive.
            self.log.update(dt);
            Audio.update();
            Input.updateGestures(dt);
            // Engine-driven sprite animation (opt-in via
            // `drive_sprite_animations`). Advance every `SpriteAnimation`
            // on the time-scaled dt BEFORE `resolveAtlasSprites` so the
            // new frame's `sprite_name` is resolved to a `source_rect` the
            // same frame. Frozen when `sprite_animations_paused` — that's
            // how a pause menu stops sprite cycling without gating a
            // per-frame game script. Lives in the always-run block (not the
            // gameplay-skip section) so it advances on `scaled_dt`, which a
            // `time_scale==0` hard pause already zeroes.
            // `scaled_dt != 0` skips the ECS walk entirely when time is
            // frozen (a `time_scale==0` hard pause, which still runs this
            // always-run block) — no frame can advance on a zero dt anyway.
            // Slow-mo keeps a tiny non-zero dt, so it still animates.
            if (self.drive_sprite_animations and !self.sprite_animations_paused and scaled_dt != 0) {
                @import("../sprite_animation_tick.zig").tick(self, scaled_dt);
            }
            // Particle sims (#750). Step each emitter's pooled ParticleSystem
            // on the time-scaled dt; `scaled_dt != 0` freezes them under a
            // hard pause. Folds to nothing when `drive_particles` is off (no
            // emitter authored) — byte-identical for particle-less games.
            if (self.drive_particles and scaled_dt != 0) {
                @import("../particles_tick.zig").tick(self, scaled_dt);
            }
            AtlasMixin.resolveAtlasSprites(self);
            self.renderer.sync(EcsImpl, self.ecs_backend);

            // Gamepad hotplug + ControllerManager drain (core#18 / #611).
            // Runs in the ALWAYS-RUN section, BEFORE the pause gate below,
            // so a controller reconnect that should lift an opt-in
            // auto-pause is still seen while the game is paused. Folds away
            // entirely when no gamepad/controller event is wanted.
            InputEventsMixin.scanGamepadEvents(self);

            // Reconcile gizmos for runtime-created entities
            if (self.gizmo_reconcile_fn) |reconcile_fn| {
                reconcile_fn(self);
            }

            // State changes must process even when paused (e.g. pause → menu).
            // Clear pending BEFORE setState so hooks can re-queue without being overwritten.
            if (self.pending_state_change) |new_state| {
                self.pending_state_change = null;
                self.setState(new_state);
            }

            // Scene changes must process even when paused (e.g. pause menu → new scene)
            if (self.pending_scene_change) |next_scene| {
                const atomic = self.pending_scene_atomic;
                var failed = false;
                if (atomic) {
                    self.setSceneAtomic(next_scene) catch {
                        failed = true;
                    };
                } else {
                    self.setScene(next_scene) catch {
                        failed = true;
                    };
                }
                // Consume the request only once the swap actually COMMITTED
                // (or hard-errored). `setScene`/`setSceneAtomic` DEFER —
                // returning without swapping — while the target scene's asset
                // manifest is still loading. Previously the request was cleared
                // unconditionally, dropping the scene change forever (there is
                // no separate retry path) — which left a menu→colony transition
                // stuck on the menu rendering only the background (the target's
                // atlases hadn't been acquired yet). Keep it pending across
                // deferrals so a later frame — by which point the gate's
                // acquire has driven the atlases to `.ready` — commits.
                //
                // Commit signal: `pending_scene_assets` is set when the gate
                // defers (acquireBatch) and cleared only when the swap
                // commits, so `== null` means committed. (Using
                // `current_scene_name == target` would falsely read as
                // committed when RELOADING the current scene and the reload
                // defers — the name already matches. See review on #635.)
                // A scene with no declared assets never gates, so it always
                // commits in one shot.
                const has_assets = if (self.scenes.get(next_scene)) |entry|
                    entry.assets.len > 0
                else
                    false;
                const committed = !has_assets or self.pending_scene_assets == null;
                if (failed or committed) {
                    self.allocator.free(next_scene);
                    self.pending_scene_change = null;
                    self.pending_scene_atomic = false;
                }
            }

            // Hot reload: re-trigger the current scene's loader
            if (self.hot_reload_dirty) {
                self.hot_reload_dirty = false;
                if (self.current_scene_name) |name| {
                    if (self.scenes.get(name)) |entry| {
                        self.unloadCurrentScene();
                        self.emitHook(.{ .scene_before_load = .{ .name = name, .allocator = self.allocator } });
                        // Engine `Events` dual-emit (#578).
                        self.emitEngineEvent("engine__scene_loading", .{ .name = name });
                        // Scene-source override resolution (Play mode /
                        // editor_api) — same pattern as `setScene`.
                        self.loading_scene_name = name;
                        // Hot-reload loader failure must NOT vanish (#697).
                        // `tick` returns void, so there's no caller to
                        // propagate to — surface it via the engine log
                        // instead of a bare `catch {}`. Control flow is
                        // otherwise unchanged: `loading_scene_name` is
                        // cleared and the scene-load hooks fire below, just
                        // as they did before, so a partial reload leaves the
                        // game in the same (best-effort) state — only now
                        // the failure is visible in the log.
                        entry.loader_fn(self) catch |err| {
                            self.log.err(
                                "[Scene] hot-reload loader for '{s}' failed: {s}",
                                .{ name, @errorName(err) },
                            );
                        };
                        self.loading_scene_name = null;
                        // Re-seed the gfx camera from the authored `Camera`
                        // component after a hot reload rebuilds the scene
                        // (camera-prefabs #714). Comptime-folds away on
                        // camera-less renderers.
                        self.seedCameraFromComponent();
                        self.emitHook(.{ .scene_load = .{ .name = name } });
                        // Engine `Events` dual-emit (#578).
                        self.emitEngineEvent("engine__scene_loaded", .{ .name = name });
                    }
                }
            }

            // Paused: skip game logic but keep frame counter advancing.
            // Gates on the unified `isPaused()` so an explicit
            // `setPaused(true)` halts the tick even when time_scale is
            // still 1.0 — not just the `scaled_dt == 0` variant below.
            if (self.isPaused()) {
                self.frame_number += 1;
                return;
            }

            self.emitHook(.{ .frame_start = .{ .frame_number = self.frame_number, .dt = scaled_dt } });
            // Engine `Events` dual-emit (#578) — fires every active
            // frame at the top of the tick. Folds away in unit-test
            // games (`GameEvents = void`).
            self.emitEngineEvent("engine__tick", .{ .frame_number = self.frame_number, .dt = scaled_dt });

            // Fixed-timestep phase (#751). Drains whole `fixed_dt` slices out
            // of the accumulator BEFORE the variable-dt update — matching
            // Bevy's `FixedUpdate`-before-`Update` order, so gameplay reads a
            // just-stepped sim. Fully additive: a no-op (zero cost past one
            // bool check) unless `setFixedTimestepEnabled(true)` opted in, so
            // the existing ordering the generated main pins around `tick` is
            // undisturbed for projects without a `fixed/` phase.
            self.advanceFixedTimestep(scaled_dt);

            if (self.active_scene_ptr) |scene_ptr| {
                if (self.active_scene_update_fn) |update_fn| {
                    update_fn(scene_ptr, scaled_dt);
                }
            }

            self.emitHook(.{ .frame_end = .{ .frame_number = self.frame_number, .dt = scaled_dt } });
            // Engine `Events` dual-emit (#578).
            self.emitEngineEvent("engine__post_tick", .{ .frame_number = self.frame_number, .dt = scaled_dt });

            // Input events (labelle-gui#208). Scan the unified
            // `InputInterface` and buffer matching engine events. Placed
            // here, at the tail of the active-frame body, so the events
            // land in `event_buffer` alongside this frame's lifecycle
            // events and drain together on the next `dispatchEvents`
            // (called by the generated main loop right after `tick`) —
            // i.e. they dispatch the SAME frame. Input state is current
            // during `tick` (scripts already read it here). Each scan
            // loop is comptime-gated, so an event-less game runs none of
            // this.
            InputEventsMixin.scanInputEvents(self);

            self.frame_number += 1;
        }

        pub fn render(self: *Game) void {
            // Post-load render gate (#637). A `loadGameState` restored
            // every saved sprite synchronously, but the atlases they
            // sample re-decode/re-upload asynchronously over the next
            // ~1–2 s; during that window some sit at `texture_id == 0`
            // and the restored sprites would flash with an unbound /
            // wrong texture. Hold the world draw until every gated atlas
            // has re-bound (the gate is cleared in `tick` by
            // `updatePostLoadRenderGate` the first frame they're all
            // ready). We still draw gizmos so debug overlays / the
            // generated frame's clear stay live — only the textured world
            // is suppressed, and only for the few frames the re-decode
            // takes. The common path (no gate armed) is unchanged.
            if (self.post_load_render_gate == null) {
                if (comptime Game.tilemap_percamera_background_supported) {
                    // T3 Z-interleave with a PER-CAMERA background (gfx
                    // ≥1.24.0 `renderWithLayerHooks`). One render call carries
                    // both tilemap hooks, so every draw rides gfx's own
                    // per-active-camera loop (viewport scissor included):
                    //   * `tilemapBackgroundHook` (on_before_layers) fires once
                    //     per active camera, inside its transform + scissor,
                    //     BEFORE the first sprite layer → the UNBOUND `.tmx`
                    //     layers draw under everything, culled to THAT camera's
                    //     world rect. So split-screen backgrounds are per
                    //     viewport, not primary-only (closes #709).
                    //   * `tilemapLayerHook` (on_after_layer) draws the BOUND
                    //     `.tmx` layers at their engine layer's z, per camera —
                    //     unchanged.
                    // Reap orphaned side-table runtimes ONCE up front — never
                    // inside the per-camera draw hooks, which would unload
                    // tileset textures mid-render and repeat once per active
                    // camera (codex #712). Both hooks then only draw.
                    TilemapMixin.reapTilemapGhosts(self);
                    self.renderer.renderWithLayerHooks(
                        *Game,
                        self,
                        TilemapMixin.tilemapBackgroundHook,
                        TilemapMixin.tilemapLayerHook,
                    );
                } else if (comptime Game.tilemap_interleave_supported) {
                    // Interleave, but the renderer only has the older
                    // single-callback `renderWithLayerHook` (gfx 1.22–1.23):
                    //   1. Pre-sprite background — UNBOUND `.tmx` layers, drawn
                    //      once through the PRIMARY camera (see
                    //      `renderTilemapBackground`).
                    //   2. `renderWithLayerHook` draws sprite layers + the
                    //      BOUND `.tmx` layers per camera (`tilemapLayerHook`).
                    TilemapMixin.renderTilemapBackground(self);
                    self.renderer.renderWithLayerHook(*Game, self, TilemapMixin.tilemapLayerHook);
                } else {
                    // T2 path (renderer without the per-layer hook): the
                    // whole tilemap stack is a PRE-SPRITE world background —
                    // terrain draws FIRST, under the gameplay sprites, inside
                    // the same world camera transform (see `renderTilemaps`).
                    // No-op when no Tilemap entities exist / the renderer
                    // lacks the seam. All branches are gated by the post-load
                    // render gate so restored tilemaps don't flash before
                    // their tileset textures re-bind.
                    self.renderTilemaps();
                    self.renderer.render();
                }

                // Particles (#750) — composite the live particles OVER the
                // world sprite pass via the `drawMesh` seam (a no-op on a
                // renderer without it). Inside the post-load gate so restored
                // emitters don't flash before their scene's atlases re-bind.
                if (self.drive_particles) {
                    @import("../particles_tick.zig").render(self);
                }
            }
            self.renderGizmos();
            self.clearGizmos();
        }
    };
}
