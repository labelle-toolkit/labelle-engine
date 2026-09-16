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
    var draw_h: [16]f32 = undefined;
    var fullscreen_n: usize = 0;
    var playing: bool = true; // toggled to simulate end-of-stream
    var replay_n: usize = 0;
    /// The next N `openVideo` calls return 0 (failure), as a backend whose
    /// decoder isn't ready — or can never open the clip — does.
    var fail_opens: u32 = 0;

    fn reset() void {
        next_id = 1;
        open_count = 0;
        draw_n = 0;
        fullscreen_n = 0;
        playing = true;
        replay_n = 0;
        fail_opens = 0;
    }

    pub fn openVideo(_: []const u8) u32 {
        open_count += 1;
        if (fail_opens > 0) {
            fail_opens -= 1;
            return 0;
        }
        const id = next_id;
        next_id += 1;
        return id;
    }
    pub fn updateVideo(_: u32, _: f32) void {}
    pub fn drawVideo(_: u32, x: f32, _: f32, w: f32, h: f32) void {
        if (draw_n < 16) {
            draw_x[draw_n] = x;
            draw_w[draw_n] = w;
            draw_h[draw_n] = h;
            draw_n += 1;
        }
    }
    pub fn drawVideoFullscreen(_: u32, _: u8) void {
        fullscreen_n += 1;
    }
    pub fn isVideoPlaying(_: u32) bool {
        return playing;
    }
    pub fn replayVideo(_: u32) void {
        replay_n += 1;
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

test "renderVideos: a looping video restarts at end (no finish)" {
    FakeVideo.reset();
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addVideo(e, core.VideoComponent.init("loop.mp4", 100, 100)); // loop = true default

    FakeVideo.playing = false; // simulate end-of-stream
    game.renderVideos(0.016);

    try testing.expectEqual(@as(usize, 1), FakeVideo.replay_n); // restarted
    const vc = game.getComponent(e, core.VideoComponent).?;
    try testing.expect(!vc.finished); // a loop never "finishes"
}

test "renderVideos: a play-once video finishes once at end (no replay)" {
    FakeVideo.reset();
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    var v = core.VideoComponent.init("intro.mp4", 100, 100);
    v.loop = false;
    game.addVideo(e, v);

    FakeVideo.playing = false; // simulate end-of-stream
    game.renderVideos(0.016);

    const vc = game.getComponent(e, core.VideoComponent).?;
    try testing.expect(vc.finished); // play-once → finished
    try testing.expectEqual(@as(usize, 0), FakeVideo.replay_n); // not restarted

    // Fires once: a second frame doesn't reset the flag.
    game.renderVideos(0.016);
    try testing.expect(vc.finished);
}

test "renderVideos: a zero on one axis takes native only for that axis" {
    FakeVideo.reset();
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    // width fixed at 320, height = 0 → native height (48), width preserved.
    game.addVideo(e, core.VideoComponent.init("x.mp4", 320, 0));

    game.renderVideos(0.016);

    try testing.expectEqual(@as(usize, 1), FakeVideo.draw_n);
    try testing.expectEqual(@as(f32, 320), FakeVideo.draw_w[0]); // not clobbered to native 64
    try testing.expectEqual(@as(f32, 48), FakeVideo.draw_h[0]); // native height
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

test "renderVideos: a video that never opens gives up, finishes, and stops asking" {
    FakeVideo.reset();
    FakeVideo.fail_opens = std.math.maxInt(u32); // the backend can never open it
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    var v = core.VideoComponent.init("broken.mp4", 100, 100);
    v.loop = false;
    game.addVideo(e, v);

    // Up to the limit the system keeps trying — a backend may just be warming up.
    for (0..core.VIDEO_MAX_OPEN_ATTEMPTS - 1) |_| game.renderVideos(0.016);
    const vc = game.getComponent(e, core.VideoComponent).?;
    try testing.expect(!vc.finished);
    try testing.expectEqual(@as(u32, core.VIDEO_MAX_OPEN_ATTEMPTS - 1), FakeVideo.open_count);

    // The attempt that reaches the limit gives up: the clip is finished, so
    // whatever waits on it (an intro handing off to the menu) is released.
    game.renderVideos(0.016);
    try testing.expect(vc.finished);
    try testing.expectEqual(@as(u32, core.VIDEO_MAX_OPEN_ATTEMPTS), FakeVideo.open_count);

    // And it never asks again — this is what stops a decoder being re-created
    // every frame for the rest of the process (#874).
    for (0..10) |_| game.renderVideos(0.016);
    try testing.expectEqual(@as(u32, core.VIDEO_MAX_OPEN_ATTEMPTS), FakeVideo.open_count);
    try testing.expectEqual(@as(usize, 0), FakeVideo.draw_n); // nothing was ever drawn
}

test "renderVideos: a transient open failure still plays" {
    FakeVideo.reset();
    FakeVideo.fail_opens = 3; // not ready for the first three frames
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addVideo(e, core.VideoComponent.init("slow.mp4", 100, 100));

    for (0..4) |_| game.renderVideos(0.016);

    const vc = game.getComponent(e, core.VideoComponent).?;
    try testing.expect(vc.handle != 0); // opened on the fourth try
    try testing.expect(!vc.finished); // a retry that succeeded is not a failure
    try testing.expectEqual(@as(usize, 1), FakeVideo.draw_n); // and it plays
}
