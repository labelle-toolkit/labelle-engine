//! VideoComponent + renderVideos system (FP#549): proves multiple videos play
//! at multiple entity positions — the prefab-placeable layer.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const MockEcs = core.MockEcsBackend(u32);

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

/// Recording video backend — counts opens and captures every draw so the test
/// can assert each video lands at its entity's position.
const FakeVideo = struct {
    var next_id: u32 = 1;
    var open_count: u32 = 0;
    var draw_n: usize = 0;
    var draw_x: [16]f32 = undefined;
    var draw_w: [16]f32 = undefined;
    var fullscreen_n: usize = 0;

    fn reset() void {
        next_id = 1;
        open_count = 0;
        draw_n = 0;
        fullscreen_n = 0;
    }

    pub fn openVideo(_: []const u8) u32 {
        open_count += 1;
        const id = next_id;
        next_id += 1;
        return id;
    }
    pub fn updateVideo(_: u32, _: f32) void {}
    pub fn drawVideo(_: u32, x: f32, _: f32, w: f32, _: f32) void {
        if (draw_n < 16) {
            draw_x[draw_n] = x;
            draw_w[draw_n] = w;
            draw_n += 1;
        }
    }
    pub fn drawVideoFullscreen(_: u32) void {
        fullscreen_n += 1;
    }
    pub fn isVideoPlaying(_: u32) bool {
        return true;
    }
    pub fn videoDimensions(_: u32) struct { w: u32, h: u32 } {
        return .{ .w = 64, .h = 48 };
    }
};

const TestGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    FakeVideo,
    engine.StubGui,
    void,
    engine.StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

test "renderVideos: multiple videos play at their entity positions" {
    FakeVideo.reset();
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.videoSupported());

    const e1 = game.createEntity();
    game.setPosition(e1, .{ .x = 100, .y = 200 });
    game.addVideo(e1, core.VideoComponent.init("a.mp4", 320, 240));

    const e2 = game.createEntity();
    game.setPosition(e2, .{ .x = 500, .y = 50 });
    game.addVideo(e2, core.VideoComponent.init("b.mp4", 0, 0)); // 0 → native 64×48

    game.renderVideos(0.016);

    // Both opened (lazily) and drawn — multiple concurrent videos.
    try testing.expectEqual(@as(u32, 2), FakeVideo.open_count);
    try testing.expectEqual(@as(usize, 2), FakeVideo.draw_n);

    // Each drew at its entity's X; e2's width=0 fell back to the native 64.
    var at_100 = false;
    var at_500 = false;
    for (0..FakeVideo.draw_n) |i| {
        if (FakeVideo.draw_x[i] == 100) {
            at_100 = true;
            try testing.expectEqual(@as(f32, 320), FakeVideo.draw_w[i]);
        }
        if (FakeVideo.draw_x[i] == 500) {
            at_500 = true;
            try testing.expectEqual(@as(f32, 64), FakeVideo.draw_w[i]);
        }
    }
    try testing.expect(at_100 and at_500);

    // Handles cache: a second frame opens nothing new.
    game.renderVideos(0.016);
    try testing.expectEqual(@as(u32, 2), FakeVideo.open_count);
}

test "renderVideos: fullscreen background uses the fill path, not positioned draw" {
    FakeVideo.reset();
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 123, .y = 456 }); // ignored for a background
    game.addVideo(e, core.VideoComponent.background("bg"));

    game.renderVideos(0.016);

    try testing.expectEqual(@as(usize, 1), FakeVideo.fullscreen_n);
    try testing.expectEqual(@as(usize, 0), FakeVideo.draw_n); // not the positioned path
}

test "removeVideo: detaches the component" {
    FakeVideo.reset();
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 10, .y = 10 });
    game.addVideo(e, core.VideoComponent.init("x.mp4", 100, 100));
    game.renderVideos(0.016);
    try testing.expectEqual(@as(usize, 1), FakeVideo.draw_n);

    game.removeVideo(e);
    game.renderVideos(0.016);
    // No new draw — the component is gone.
    try testing.expectEqual(@as(usize, 1), FakeVideo.draw_n);
}
