/// Lifecycle / runtime-control mixin — the small field-accessor clusters
/// that drive the game loop's runtime knobs: quit flag, fullscreen
/// request, engine-driven sprite-animation toggles, time scale, and the
/// gameplay clock readout.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. Each method
/// just reads or writes a `Game` field — the actual platform effects
/// (window fullscreen, animation advance) happen elsewhere, driven off
/// these flags.

const std = @import("std");
const core = @import("labelle-core");

/// Returns the lifecycle/runtime-control mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const has_events = Game.has_events_export;
    const has_hooks = Game.has_hooks_export;
    const HooksIsMerged = Game.HooksIsMergedExport;
    const Hooks = Game.HooksParam;
    const uses_os_gamepad_source = Game.uses_os_gamepad_source;

    return struct {
        // ── Teardown / hook wiring ────────────────────────────────

        pub fn deinit(self: *Game) void {
            self.emitHook(.{ .game_deinit = {} });
            // Engine `Events` dual-emit (#578). Fires before the actual
            // teardown so flow listeners that read game state from a
            // `game_deinit` handler still see the live world. Folds
            // away when `GameEvents` doesn't carry the variant.
            self.emitEngineEvent("engine__game_deinit", .{});
            // Drain the buffered event so a `game_deinit` listener
            // actually receives it before the event-buffer arena tears
            // down below. The normal frame loop does this at
            // `dispatchEvents`; on shutdown there is no next frame.
            if (has_events) self.dispatchEvents();
            // `Game` owns the preview channel by value when set, so we
            // release it here. The generated `main.zig` is expected to
            // call `game.preview.?.sendBye(...)` before `game.deinit()`
            // for a graceful shutdown; the socket close + arena tear-down
            // happens here regardless.
            if (self.preview) |*p| p.deinit();
            // Tear down the per-OS gamepad source iff we initialized it
            // (core#18). Symmetric with the `init` call above and gated by
            // the same comptime flag.
            if (comptime uses_os_gamepad_source) core.gamepad_source.deinit();
            // Drop any timers still in flight (#25 Stage 2). A game can
            // exit mid-Delay; this frees each entry's owned `ctx` and the
            // pending list without firing — no leaks under testing.allocator.
            self.scheduler.deinit();
            // Tear down the active scene FIRST. Scene teardown runs
            // user-provided `deinit_fn`s that may call `game.assets.*`
            // (release on unload is the natural pattern for the very
            // API this PR is exposing), so the catalog MUST still be
            // alive through it. Worker-thread safety is handled inside
            // `AssetCatalog.deinit` — it stops the worker and drains
            // the result ring before touching the hashmap, and its
            // allocator is the Game's allocator which stays live
            // through this whole call.
            if (has_events) self.event_buffer.deinit(self.allocator);
            self.teardownActiveScene();
            self.scene_entities.deinit(self.allocator);
            self.assets.deinit();
            if (self.current_scene_name) |name| {
                self.allocator.free(name);
            }
            if (self.pending_scene_change) |name| {
                self.allocator.free(name);
            }
            if (self.pending_scene_assets) |name| {
                self.allocator.free(name);
            }
            if (self.owned_initial_state) |name| {
                self.allocator.free(name);
            }
            // Clean up inactive worlds
            var world_iter = self.worlds.iterator();
            while (world_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.worlds.deinit();
            if (self.active_world_name) |name| {
                self.allocator.free(name);
            }
            // Clean up active world
            self.active_world.deinit();
            self.allocator.destroy(self.active_world);
            self.gizmo_state.deinit(self.allocator);
            self.scenes.deinit();
            self.jsonc_scenes.deinit();
            // Free duplicated keys; values are program-lifetime @embedFile
            // borrows so they aren't owned by this map.
            var emb_iter = self.embedded_scene_sources.iterator();
            while (emb_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.embedded_scene_sources.deinit();
            self.atlas_manager.deinit();
        }

        pub fn setHooks(self: *Game, receiver: Hooks) void {
            // `self` is at its final, stable address by the time the game
            // wires hooks (see generated main: `init` then `setHooks`), so
            // pin the scheduler's type-erased game pointer here too — covers
            // any `game.scheduler.after(...)` issued before the first tick.
            self.bindScheduler();
            if (has_hooks) {
                if (HooksIsMerged) {
                    self.hooks = receiver;
                    // Inject game pointer into hook structs that declare game_ptr
                    const merged = receiver.*;
                    inline for (std.meta.fields(@TypeOf(merged.receivers))) |field| {
                        const hook_ptr = @field(merged.receivers, field.name);
                        const HookType = @typeInfo(@TypeOf(hook_ptr)).pointer.child;
                        if (@hasField(HookType, "game_ptr")) {
                            hook_ptr.game_ptr = @ptrCast(self);
                        }
                    }
                } else {
                    self.hooks = .{ .receiver = receiver };
                    // Inject game pointer for single hook
                    const HookType = @typeInfo(Hooks).pointer.child;
                    if (@hasField(HookType, "game_ptr")) {
                        receiver.game_ptr = @ptrCast(self);
                    }
                }
                self.emitHook(.{ .game_init = .{ .allocator = self.allocator } });
                // Engine `Events` dual-emit (#578). `engine.game_init`
                // is empty by design — the on-disk Event-node form
                // doesn't carry `Allocator`. Listeners that need an
                // allocator should reach `game.allocator` directly.
                self.emitEngineEvent("engine__game_init", .{});
            }
        }

        // ── Game Loop ─────────────────────────────────────────────

        pub fn quit(self: *Game) void {
            self.running = false;
        }

        pub fn isRunning(self: *const Game) bool {
            return self.running;
        }

        // ── Fullscreen ──
        //
        // The engine owns the *desired* fullscreen flag; the actual
        // platform window call (sokol `sapp.toggleFullscreen`, raylib
        // `ToggleFullscreen`, …) lives in the generated `main.zig` frame
        // loop, which polls `takeFullscreenRequest()` and forwards the
        // value to `window.setFullscreen`. Keeping the call out of the
        // library is what lets the engine stay backend-agnostic — the
        // same reason `quit()` only flips `running` and lets the frame
        // loop call `window.requestQuit()`.

        /// Request a fullscreen / windowed switch. No-op if already in the
        /// requested mode. Takes effect on the next frame, when the
        /// generated main drains `takeFullscreenRequest()`.
        pub fn setFullscreen(self: *Game, on: bool) void {
            if (self.fullscreen == on) return;
            self.fullscreen = on;
            self.fullscreen_dirty = true;
        }

        /// Flip between fullscreen and windowed.
        pub fn toggleFullscreen(self: *Game) void {
            setFullscreen(self, !self.fullscreen);
        }

        /// The engine's desired fullscreen state. This is the value a
        /// settings UI should bind a checkbox to — it reflects the latest
        /// `setFullscreen`/`toggleFullscreen` call, not a backend query.
        pub fn isFullscreen(self: *const Game) bool {
            return self.fullscreen;
        }

        /// Frame-loop drain (generated main only): returns the new
        /// fullscreen value exactly once after it changes, else `null`.
        /// The caller forwards a non-null result to the window backend.
        pub fn takeFullscreenRequest(self: *Game) ?bool {
            if (!self.fullscreen_dirty) return null;
            self.fullscreen_dirty = false;
            return self.fullscreen;
        }

        // ── Vsync ──
        //
        // Mirrors the Fullscreen split: the engine owns the *desired* vsync
        // flag; the actual swap-interval change (bgfx `reset` with/without
        // `BGFX_RESET_VSYNC`, sokol's per-platform swap-interval call, …)
        // lives in the generated `main.zig` frame loop, which polls
        // `takeVsyncRequest()` and forwards the value to `window.setVsync`.
        // Defaults ON — every backend previously hardcoded vsync on.

        /// Request a vsync on/off switch. No-op if already in the requested
        /// mode. Takes effect on the next frame, when the generated main
        /// drains `takeVsyncRequest()`.
        pub fn setVsync(self: *Game, on: bool) void {
            if (self.vsync == on) return;
            self.vsync = on;
            self.vsync_dirty = true;
        }

        /// Flip vsync on/off.
        pub fn toggleVsync(self: *Game) void {
            setVsync(self, !self.vsync);
        }

        /// The engine's desired vsync state. This is the value a settings UI
        /// should bind a checkbox to — it reflects the latest
        /// `setVsync`/`toggleVsync` call, not a backend query.
        pub fn isVsync(self: *const Game) bool {
            return self.vsync;
        }

        /// Frame-loop drain (generated main only): returns the new vsync
        /// value exactly once after it changes, else `null`. The caller
        /// forwards a non-null result to the window backend.
        pub fn takeVsyncRequest(self: *Game) ?bool {
            if (!self.vsync_dirty) return null;
            self.vsync_dirty = false;
            return self.vsync;
        }

        // ── Engine-driven sprite animation ──
        //
        // Opt-in: instead of the game shipping a `sprite_animation_tick`
        // script that calls `spriteAnimationTick(game, dt)`, the engine
        // can advance every `SpriteAnimation` itself in `tick()` on the
        // time-scaled clock (see the always-run block). A game enables it
        // once at startup and deletes its script; a pause menu freezes
        // sprite cycling via `setSpriteAnimationsPaused` without having to
        // gate a per-frame script.

        /// Turn engine-driven sprite-animation advancement on/off. When on,
        /// the game must NOT also run a `sprite_animation_tick` script, or
        /// animations advance twice per frame.
        pub fn setDriveSpriteAnimations(self: *Game, on: bool) void {
            self.drive_sprite_animations = on;
        }

        /// Freeze (`true`) or resume (`false`) the engine-driven sprite
        /// animation advance. No-op unless `drive_sprite_animations` is on.
        pub fn setSpriteAnimationsPaused(self: *Game, paused: bool) void {
            self.sprite_animations_paused = paused;
        }

        /// Whether engine-driven sprite animation is currently frozen.
        pub fn spriteAnimationsPaused(self: *const Game) bool {
            return self.sprite_animations_paused;
        }

        // ── Time scale ──

        pub fn setTimeScale(self: *Game, scale: f32) void {
            self.time_scale = @max(0, scale);
        }

        pub fn getTimeScale(self: *const Game) f32 {
            return self.time_scale;
        }

        pub fn pause(self: *Game) void {
            self.time_scale = 0;
            self.setPaused(true);
        }

        pub fn resume_(self: *Game) void {
            self.time_scale = 1.0;
            self.setPaused(false);
        }

        /// Seconds of gameplay time elapsed (time-scaled, pause-aware) —
        /// the clock flow `Cooldown`/`Delay` nodes (#25) measure against.
        pub fn elapsedSeconds(self: *const Game) f64 {
            return self.clock_s;
        }
    };
}
