//! Game construction — `init` + the scheduler's type-erased glue,
//! extracted from `game.zig` (facade split; same Mixin idiom as the
//! sibling files, with the two backend impls threaded as explicit
//! comptime params because they are `GameConfig` function parameters,
//! not `Game` decls).
//!
//! `deinit` intentionally does NOT live here — teardown belongs to
//! the lifecycle mixin (`game/lifecycle_mixin.zig`), which owns the
//! shutdown ordering contract.

const std = @import("std");
const core = @import("labelle-core");
const atlas_mod = @import("../atlas.zig");
const assets_mod = @import("../assets/mod.zig");
const animation_def_runtime = @import("../animation_def_runtime.zig");
const gizmo_draws_mod = @import("gizmo_draws.zig");
const roster_mod = @import("roster.zig");

/// Returns the construction mixin for a given Game type.
/// `VideoImpl`/`AudioImpl` are the raw backend impls (`Game.Video` /
/// `Game.Audio` are their INTERFACE wrappers, which is why they must
/// be passed alongside `Game` rather than read off it).
pub fn Mixin(comptime Game: type, comptime VideoImpl: type, comptime AudioImpl: type) type {
    const Entity = Game.EntityType;

    return struct {
        // ── Scheduler trampolines (#25 Stage 2) ──────────────────
        // Type-erased shims so `Scheduler` reads the gameplay clock and
        // checks entity liveness without importing `*Game` (which would be
        // a circular comptime dependency). `game_ctx` is `@ptrCast(self)`,
        // re-cast back to `*Game` here.

        fn schedulerNow(game_ctx: *anyopaque) f64 {
            const self: *Game = @ptrCast(@alignCast(game_ctx));
            return self.elapsedSeconds();
        }

        fn schedulerIsAlive(game_ctx: *anyopaque, entity: Entity) bool {
            const self: *Game = @ptrCast(@alignCast(game_ctx));
            return self.ecs_backend.entityExists(entity);
        }

        /// Point the scheduler's type-erased `game_ctx` at this game's stable
        /// address. `Game.init` returns by value, so `game_ctx` can only be
        /// fixed once the game lands at its final location. Idempotent — safe
        /// to call from `setHooks` and at the top of every `tick`, and the
        /// codegen-generated main can call it explicitly after `init`.
        pub fn bindScheduler(self: *Game) void {
            self.scheduler.game_ctx = @ptrCast(self);
        }

        pub fn init(allocator: std.mem.Allocator) Game {
            const world = allocator.create(Game.World) catch @panic("failed to allocate default world");
            world.* = Game.World.init(allocator);
            // One-time setup for the per-OS gamepad hotplug source on the
            // fallback path (core#18). No-op when a backend polls natively
            // or no flow listens (`uses_os_gamepad_source` folds it away),
            // and the source's own `init` is `@hasDecl`-guarded per platform.
            if (comptime Game.uses_os_gamepad_source) core.gamepad_source.init();
            // Wire the audio backend into a video backend that supports it (e.g.
            // the bgfx VideoBackend), so opened videos play their audio track in
            // A/V sync — the player's master clock is the audio position
            // (#549/#306). Comptime-gated: stub video, or an audio backend
            // without the mixer API, folds this away. The VideoBackend can't
            // import the audio module (one mixer), so the engine — which holds
            // both impls — injects the raw audio fns as function pointers.
            if (comptime @hasDecl(VideoImpl, "setAudioBackend") and @hasDecl(AudioImpl, "loadMusicFromPcm")) {
                VideoImpl.setAudioBackend(.{
                    .loadPcm = &AudioImpl.loadMusicFromPcm,
                    .play = &AudioImpl.playMusic,
                    .update = &AudioImpl.updateMusic,
                    .stop = &AudioImpl.stopMusic,
                    .clock = &AudioImpl.musicPositionSeconds,
                    .unload = &AudioImpl.unloadMusic,
                });
            }
            return .{
                .allocator = allocator,
                .active_world = world,
                .ecs_backend = &world.ecs_backend,
                .renderer = &world.renderer,
                .worlds = std.StringHashMap(*Game.World).init(allocator),
                .roster_cache = std.AutoHashMap(u64, roster_mod.Slot(Entity)).init(allocator),
                .atlas_manager = atlas_mod.TextureManager.init(allocator),
                .assets = assets_mod.AssetCatalog.init(allocator),
                .scenes = std.StringHashMap(Game.SceneEntry).init(allocator),
                .jsonc_scenes = std.StringHashMap(Game.JsoncSceneInfo).init(allocator),
                .embedded_scene_sources = std.StringHashMap([]const u8).init(allocator),
                .embedded_tilemap_sources = std.StringHashMap([]const u8).init(allocator),
                .tilemaps = if (Game.tilemap_supported)
                    std.AutoHashMap(Entity, *Game.TilemapRuntimeType).init(allocator)
                else {},
                .scene_source_overrides = std.StringHashMap([]const u8).init(allocator),
                .runtime_anim_defs = animation_def_runtime.RuntimeAnimDefs.init(allocator),
                .gizmo_state = gizmo_draws_mod.GizmoState(Entity).init(allocator),
                // `game_ctx` is a placeholder here (the not-yet-stable world
                // pointer); `bindScheduler` fixes it once `self` is stable.
                // The trampolines are address-stable comptime fn pointers.
                .scheduler = Game.SchedulerType.init(allocator, world, schedulerNow, schedulerIsAlive),
            };
        }
    };
}
