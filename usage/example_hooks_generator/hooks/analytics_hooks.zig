// Second hook file - demonstrates multiple handlers for same event
const std = @import("std");
const engine = @import("labelle-engine");

pub fn game_init(_: @This(), _: engine.GameInitInfo) void {
    std.log.info("[analytics] Tracking game start...", .{});
}

pub fn scene_load(_: @This(), info: engine.SceneInfo) void {
    std.log.info("[analytics] User entered scene: {s}", .{info.name});
}

pub fn game_deinit(_: @This(), _: void) void {
    std.log.info("[analytics] Session ended, sending metrics...", .{});
}
