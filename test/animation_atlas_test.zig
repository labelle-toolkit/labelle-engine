const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Animation = engine.Animation;
const AnimConfig = engine.AnimConfig;

const TestAnim = enum {
    idle,
    walk,
    attack,

    pub fn config(self: @This()) AnimConfig {
        return switch (self) {
            .idle => .{ .frames = 4, .frame_duration = 0.2 },
            .walk => .{ .frames = 6, .frame_duration = 0.1 },
            .attack => .{ .frames = 3, .frame_duration = 0.05, .looping = false },
        };
    }
};

// ── Animation ──────────────────────────────────────────────

test "Animation: init and frame advancement" {
    var anim = Animation(TestAnim).init(.idle);
    try testing.expectEqual(0, anim.frame);
    try testing.expect(anim.playing);

    // Advance past one frame duration (0.2)
    anim.update(0.25);
    try testing.expectEqual(1, anim.frame);
}

test "Animation: looping wraps to frame 0" {
    var anim = Animation(TestAnim).init(.idle);
    // 4 frames * 0.2 = 0.8s total, advance 0.9s
    anim.update(0.9);
    try testing.expect(anim.frame < 4);
    try testing.expect(anim.playing);
}

test "Animation: non-looping stops at last frame" {
    var anim = Animation(TestAnim).init(.attack);
    // 3 frames * 0.05 = 0.15s total, advance 0.2s
    anim.update(0.2);
    try testing.expectEqual(2, anim.frame);
    try testing.expect(!anim.playing);
}

test "Animation: play switches animation" {
    var anim = Animation(TestAnim).init(.idle);
    anim.update(0.3);
    try testing.expect(anim.frame > 0);

    anim.play(.walk);
    try testing.expectEqual(0, anim.frame);
    try testing.expect(anim.playing);
}

test "Animation: getSpriteName produces correct format" {
    var anim = Animation(TestAnim).init(.walk);
    anim.frame = 2;
    var buf: [64]u8 = undefined;
    const name = anim.getSpriteName("player", &buf);
    try testing.expectEqualStrings("player/walk_0003", name);
}

test "Animation: getFrameNumber is 1-based" {
    var anim = Animation(TestAnim).init(.idle);
    try testing.expectEqual(1, anim.getFrameNumber());
    anim.frame = 3;
    try testing.expectEqual(4, anim.getFrameNumber());
}

// ── Atlas ──────────────────────────────────────────────────

test "RuntimeAtlas: add and lookup sprites" {
    var atlas = engine.RuntimeAtlas.init(testing.allocator);
    defer atlas.deinit();

    try atlas.addSprite("hero_idle_0001", .{ .x = 0, .y = 0, .width = 32, .height = 32 });
    try atlas.addSprite("hero_idle_0002", .{ .x = 32, .y = 0, .width = 32, .height = 32 });

    try testing.expectEqual(2, atlas.count());
    try testing.expect(atlas.has("hero_idle_0001"));

    const s = atlas.get("hero_idle_0001").?;
    try testing.expectEqual(0, s.x);
    try testing.expectEqual(32, s.width);
}

test "TextureManager: multi-atlas lookup" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const atlas = try mgr.addAtlas("characters");
    try atlas.addSprite("hero", .{ .x = 0, .y = 0, .width = 64, .height = 64 });

    try testing.expectEqual(1, mgr.atlasCount());
    const found = mgr.findSprite("hero").?;
    try testing.expectEqual(64, found.width);
    try testing.expect(mgr.findSprite("nonexistent") == null);
}

test "SpriteData: rotation swaps dimensions" {
    const s = engine.SpriteData{ .x = 0, .y = 0, .width = 32, .height = 64, .rotated = true };
    try testing.expectEqual(64, s.getWidth());
    try testing.expectEqual(32, s.getHeight());

    const s2 = engine.SpriteData{ .x = 0, .y = 0, .width = 32, .height = 64, .rotated = false };
    try testing.expectEqual(32, s2.getWidth());
    try testing.expectEqual(64, s2.getHeight());
}
