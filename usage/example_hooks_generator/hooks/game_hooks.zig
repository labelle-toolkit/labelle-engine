// Example: Hooks loaded from hooks/ folder
//
// This file is automatically discovered by the generator when scanning
// the hooks/ folder. All public functions matching hook names are wired
// up using MergeEngineHooks.
//
// Available hooks:
// - game_init / game_deinit
// - frame_start / frame_end
// - scene_load / scene_unload
// - entity_created / entity_destroyed

const std = @import("std");
const engine = @import("labelle-engine");

var frame_count: u64 = 0;

pub fn game_init(_: engine.HookPayload) void {
    std.log.info("[hooks] Game initialized!", .{});
    frame_count = 0;
}

pub fn game_deinit(_: engine.HookPayload) void {
    std.log.info("[hooks] Game shutting down after {d} frames", .{frame_count});
}

pub fn frame_start(payload: engine.HookPayload) void {
    const info = payload.frame_start;
    frame_count = info.frame_number;

    // Log every 60 frames
    if (info.frame_number % 60 == 0 and info.frame_number > 0) {
        std.log.info("[hooks] Frame {d} (dt: {d:.1}ms)", .{
            info.frame_number,
            info.dt * 1000,
        });
    }
}

pub fn scene_load(payload: engine.HookPayload) void {
    const info = payload.scene_load;
    std.log.info("[hooks] Scene loaded: {s}", .{info.name});
}

pub fn entity_created(payload: engine.HookPayload) void {
    const info = payload.entity_created;
    if (info.prefab_name) |name| {
        std.log.info("[hooks] Entity created from prefab: {s}", .{name});
    }
}
