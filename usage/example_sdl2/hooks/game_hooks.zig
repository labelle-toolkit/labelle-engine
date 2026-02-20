// Example: SDL2 backend hooks
//
// This file demonstrates the hook system with the SDL2 backend.
// All hooks work the same as with raylib and sokol backends.
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
    std.log.info("[SDL2] Game initialized!", .{});
    frame_count = 0;
}

pub fn game_deinit(_: @This(), _: void) void {
    std.log.info("[SDL2] Game shutting down after {d} frames", .{frame_count});
}

pub fn frame_start(_: @This(), info: engine.FrameInfo) void {
    frame_count = info.frame_number;

    // Log every 60 frames
    if (info.frame_number % 60 == 0 and info.frame_number > 0) {
        std.log.info("[SDL2] Frame {d} (dt: {d:.1}ms)", .{
            info.frame_number,
            info.dt * 1000,
        });
    }
}

pub fn scene_before_load(_: @This(), info: engine.SceneBeforeLoadInfo) void {
    std.log.info("[SDL2] Scene '{s}' is about to load", .{info.name});
}

pub fn scene_load(_: @This(), info: engine.SceneInfo) void {
    std.log.info("[SDL2] Scene loaded: {s}", .{info.name});
}

pub fn scene_unload(_: @This(), info: engine.SceneInfo) void {
    std.log.info("[SDL2] Scene unloading: {s}", .{info.name});
}

pub fn entity_created(_: @This(), info: engine.EntityInfo) void {
    if (info.prefab_name) |name| {
        std.log.info("[SDL2] Entity created from prefab: {s}", .{name});
    }
}
