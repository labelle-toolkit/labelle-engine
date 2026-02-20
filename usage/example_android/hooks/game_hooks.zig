const std = @import("std");
const engine = @import("labelle-engine");

pub fn game_init(_: @This(), _: engine.GameInitInfo) void {
    std.log.info("Android Ball Demo initialized!", .{});
}

pub fn scene_load(_: @This(), info: engine.SceneInfo) void {
    std.log.info("Scene loaded: {s}", .{info.name});
}
