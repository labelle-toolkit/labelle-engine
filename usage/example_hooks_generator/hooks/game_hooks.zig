// Example: Hooks loaded from hooks/ folder
//
// This file is automatically discovered by the generator when scanning
// the hooks/ folder. All public functions matching hook names are wired
// up using MergeEngineHooks.
//
// Available hooks:
// - game_init / game_deinit
// - frame_start / frame_end
// - scene_before_load / scene_load / scene_unload
// - entity_created / entity_destroyed

const std = @import("std");
const engine = @import("labelle-engine");

var frame_count: u64 = 0;

pub fn game_init(_: @This(), _: engine.GameInitInfo) void {
    std.log.info("[hooks] Game initialized!", .{});
    frame_count = 0;
}

pub fn game_deinit(_: @This(), _: void) void {
    std.log.info("[hooks] Game shutting down after {d} frames", .{frame_count});
}

pub fn frame_start(_: @This(), info: engine.FrameInfo) void {
    frame_count = info.frame_number;

    // Log every 60 frames
    if (info.frame_number % 60 == 0 and info.frame_number > 0) {
        std.log.info("[hooks] Frame {d} (dt: {d:.1}ms)", .{
            info.frame_number,
            info.dt * 1000,
        });
    }
}

/// Called before a scene starts loading - use for pre-load initialization
pub fn scene_before_load(_: @This(), info: engine.SceneBeforeLoadInfo) void {
    std.log.info("[hooks] Scene '{s}' is about to load (allocator available for setup)", .{info.name});
    // The allocator (info.allocator) can be used to initialize scene-scoped subsystems
    // before entities are created
}

/// Called after a scene finishes loading
pub fn scene_load(_: @This(), info: engine.SceneInfo) void {
    std.log.info("[hooks] Scene loaded: {s}", .{info.name});
}

/// Called when a scene is about to unload - use for cleanup
pub fn scene_unload(_: @This(), info: engine.SceneInfo) void {
    std.log.info("[hooks] Scene unloading: {s}", .{info.name});
    // Use this hook to clean up scene-scoped resources, save state, etc.
}

pub fn entity_created(_: @This(), info: engine.EntityInfo) void {
    if (info.prefab_name) |name| {
        std.log.info("[hooks] Entity created from prefab: {s}", .{name});
    }
}
