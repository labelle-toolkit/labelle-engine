// Second hook file - demonstrates multiple handlers for same event
const std = @import("std");
const engine = @import("labelle-engine");

pub fn game_init(_: engine.HookPayload) void {
    std.log.info("[analytics] Tracking game start...", .{});
}

pub fn scene_load(payload: engine.HookPayload) void {
    const info = payload.scene_load;
    std.log.info("[analytics] User entered scene: {s}", .{info.name});
}

pub fn game_deinit(_: engine.HookPayload) void {
    std.log.info("[analytics] Session ended, sending metrics...", .{});
}
