const std = @import("std");
const engine = @import("labelle-engine");

pub fn game_init(payload: engine.HookPayload) void {
    _ = payload;
    std.log.info("WASM Ball Demo initialized!", .{});
}

pub fn scene_load(payload: engine.HookPayload) void {
    const info = payload.scene_load;
    std.log.info("Scene loaded: {s}", .{info.name});
}
