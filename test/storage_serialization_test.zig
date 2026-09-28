const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");
const Health = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    current: f32 = 100,
};
const Ecs = core.MockEcsBackend(u32);
const TestGame = engine.game_mod.GameConfig(
    core.StubRender(Ecs.Entity),
    Ecs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    engine.scene_mod.ComponentRegistry(.{ .Health = Health }),
    &.{},
    void,
);

test "engine JSON travels through blob storage and invalid bytes preserve live state" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Health{ .current = 37 });
    const json = try game.serializeGameState();
    defer testing.allocator.free(json);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &buffer);
    var files = try engine.storage.Files.init(testing.io, buffer[0..length]);
    var write = try files.store().begin(testing.allocator, .{ .write = .{ .name = "world.json", .bytes = json } });
    defer write.deinit();
    try testing.expectEqual(engine.storage.Result.written, (try write.poll()).?);
    game.resetEcsBackend();
    var read = try files.store().begin(testing.allocator, .{ .read = .{ .name = "world.json", .max_bytes = 1024 * 1024 } });
    defer read.deinit();
    const result = (try read.poll()).?;
    defer result.deinit(testing.allocator);
    try game.deserializeGameState(result.read);
    try testing.expectError(error.UnsupportedVersion, game.deserializeGameState("{\"version\":999,\"entities\":[]}"));
    var view = game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    const restored = view.next().?;
    try testing.expectEqual(@as(f32, 37), game.active_world.ecs_backend.getComponent(restored, Health).?.current);
    try testing.expectEqual(null, view.next());
}
