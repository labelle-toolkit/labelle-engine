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
    atlas.texture_id = 42;
    try atlas.addSprite("hero", .{ .x = 0, .y = 0, .width = 64, .height = 64 });

    try testing.expectEqual(1, mgr.atlasCount());
    const found = mgr.findSprite("hero").?;
    try testing.expectEqual(64, found.sprite.width);
    try testing.expectEqual(42, found.texture_id);
    try testing.expect(mgr.findSprite("nonexistent") == null);
}

test "TextureManager: loadAtlasFromJsonContent" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const json =
        \\{
        \\  "frames": {
        \\    "idle": {
        \\      "frame": {"x": 0, "y": 0, "w": 32, "h": 32},
        \\      "rotated": false,
        \\      "trimmed": false,
        \\      "spriteSourceSize": {"x": 0, "y": 0, "w": 32, "h": 32},
        \\      "sourceSize": {"w": 32, "h": 32}
        \\    },
        \\    "walk": {
        \\      "frame": {"x": 32, "y": 0, "w": 24, "h": 48},
        \\      "rotated": true,
        \\      "trimmed": true,
        \\      "spriteSourceSize": {"x": 4, "y": 2, "w": 24, "h": 48},
        \\      "sourceSize": {"w": 32, "h": 64}
        \\    }
        \\  },
        \\  "meta": {
        \\    "image": "atlas.png",
        \\    "size": {"w": 64, "h": 64}
        \\  }
        \\}
    ;

    try mgr.loadAtlasFromJsonContent("test_atlas", json, 7, null);

    try testing.expectEqual(1, mgr.atlasCount());
    try testing.expectEqual(2, mgr.totalSpriteCount());

    const idle = mgr.findSprite("idle").?;
    try testing.expectEqual(0, idle.sprite.x);
    try testing.expectEqual(32, idle.sprite.width);
    try testing.expectEqual(7, idle.texture_id);
    try testing.expect(!idle.sprite.rotated);

    const walk = mgr.findSprite("walk").?;
    try testing.expectEqual(32, walk.sprite.x);
    try testing.expect(walk.sprite.rotated);
    try testing.expect(walk.sprite.trimmed);
    // Rotated: display width = atlas height, display height = atlas width
    try testing.expectEqual(48, walk.sprite.getWidth());
    try testing.expectEqual(24, walk.sprite.getHeight());
    try testing.expectEqual(32, walk.sprite.source_width);
    try testing.expectEqual(64, walk.sprite.source_height);
    try testing.expectEqual(4, walk.sprite.offset_x);
    try testing.expectEqual(2, walk.sprite.offset_y);
}

test "TextureManager: JSON array format" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const json =
        \\{
        \\  "frames": [
        \\    {
        \\      "filename": "sprite_a",
        \\      "frame": {"x": 0, "y": 0, "w": 16, "h": 16},
        \\      "rotated": false,
        \\      "trimmed": false,
        \\      "spriteSourceSize": {"x": 0, "y": 0, "w": 16, "h": 16},
        \\      "sourceSize": {"w": 16, "h": 16}
        \\    },
        \\    {
        \\      "filename": "sprite_b",
        \\      "frame": {"x": 16, "y": 0, "w": 16, "h": 16},
        \\      "rotated": false,
        \\      "trimmed": false,
        \\      "spriteSourceSize": {"x": 0, "y": 0, "w": 16, "h": 16},
        \\      "sourceSize": {"w": 16, "h": 16}
        \\    }
        \\  ],
        \\  "meta": {
        \\    "image": "atlas.png",
        \\    "size": {"w": 32, "h": 16}
        \\  }
        \\}
    ;

    try mgr.loadAtlasFromJsonContent("arr_atlas", json, 3, null);
    try testing.expectEqual(2, mgr.totalSpriteCount());

    const a = mgr.findSprite("sprite_a").?;
    try testing.expectEqual(0, a.sprite.x);
    try testing.expectEqual(3, a.texture_id);

    const b = mgr.findSprite("sprite_b").?;
    try testing.expectEqual(16, b.sprite.x);
}

test "TextureManager: texture_scale defaults to 1.0 when actual_dims is null" {
    // Legacy path: callers that don't track actual texture dims pass
    // null and get scale=1.0, matching pre-fix behavior.
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const json =
        \\{
        \\  "frames": {
        \\    "hero": {
        \\      "frame": {"x": 0, "y": 0, "w": 32, "h": 32},
        \\      "rotated": false,
        \\      "trimmed": false,
        \\      "spriteSourceSize": {"x": 0, "y": 0, "w": 32, "h": 32},
        \\      "sourceSize": {"w": 32, "h": 32}
        \\    }
        \\  },
        \\  "meta": {"image": "atlas.png", "size": {"w": 64, "h": 64}}
        \\}
    ;

    try mgr.loadAtlasFromJsonContent("a", json, 1, null);
    const hero = mgr.findSprite("hero").?;
    try testing.expectEqual(@as(f32, 1.0), hero.texture_scale_x);
    try testing.expectEqual(@as(f32, 1.0), hero.texture_scale_y);
}

test "TextureManager: texture_scale derived from meta.size vs actual dims" {
    // Fix for labelle-toolkit/labelle-gfx#240. When the user resizes
    // the source PNG without re-running TexturePacker, meta.size in
    // the JSON stays at the original logical resolution while the
    // actual texture is smaller. The loader computes the per-axis
    // scale so source-rect coords can be mapped to physical UV pixels
    // at sprite-cache-lookup time, while display dimensions stay at
    // the un-scaled values.
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const json =
        \\{
        \\  "frames": {
        \\    "hero": {
        \\      "frame": {"x": 0, "y": 0, "w": 32, "h": 32},
        \\      "rotated": false,
        \\      "trimmed": false,
        \\      "spriteSourceSize": {"x": 0, "y": 0, "w": 32, "h": 32},
        \\      "sourceSize": {"w": 32, "h": 32}
        \\    }
        \\  },
        \\  "meta": {"image": "atlas.png", "size": {"w": 64, "h": 32}}
        \\}
    ;

    try mgr.loadAtlasFromJsonContent("a", json, 1, .{ .width = 32, .height = 8 });
    const hero = mgr.findSprite("hero").?;
    try testing.expectEqual(@as(f32, 0.5), hero.texture_scale_x);
    try testing.expectEqual(@as(f32, 0.25), hero.texture_scale_y);
}

test "TextureManager: texture_scale stays 1.0 when meta.size matches actual" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const json =
        \\{
        \\  "frames": {
        \\    "hero": {
        \\      "frame": {"x": 0, "y": 0, "w": 32, "h": 32},
        \\      "rotated": false,
        \\      "trimmed": false,
        \\      "spriteSourceSize": {"x": 0, "y": 0, "w": 32, "h": 32},
        \\      "sourceSize": {"w": 32, "h": 32}
        \\    }
        \\  },
        \\  "meta": {"image": "atlas.png", "size": {"w": 64, "h": 64}}
        \\}
    ;

    try mgr.loadAtlasFromJsonContent("a", json, 1, .{ .width = 64, .height = 64 });
    const hero = mgr.findSprite("hero").?;
    try testing.expectEqual(@as(f32, 1.0), hero.texture_scale_x);
    try testing.expectEqual(@as(f32, 1.0), hero.texture_scale_y);
}

test "TextureManager: unload atlas" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const atlas = try mgr.addAtlas("enemies");
    try atlas.addSprite("goblin", .{ .x = 0, .y = 0, .width = 32, .height = 32 });

    try testing.expectEqual(1, mgr.atlasCount());
    const v1 = mgr.getVersion();

    mgr.unloadAtlas("enemies");
    try testing.expectEqual(0, mgr.atlasCount());
    try testing.expect(mgr.findSprite("goblin") == null);
    try testing.expect(mgr.getVersion() > v1);
}

test "TextureManager: unloadAll" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const a1 = try mgr.addAtlas("atlas1");
    try a1.addSprite("s1", .{ .x = 0, .y = 0, .width = 16, .height = 16 });
    const a2 = try mgr.addAtlas("atlas2");
    try a2.addSprite("s2", .{ .x = 0, .y = 0, .width = 16, .height = 16 });

    try testing.expectEqual(2, mgr.atlasCount());
    mgr.unloadAll();
    try testing.expectEqual(0, mgr.atlasCount());
    try testing.expectEqual(0, mgr.totalSpriteCount());
}

test "SpriteCache: cached lookup avoids repeated map searches" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const atlas = try mgr.addAtlas("chars");
    atlas.texture_id = 5;
    try atlas.addSprite("hero", .{ .x = 0, .y = 0, .width = 64, .height = 64 });

    var cache = engine.SpriteCache.init(testing.allocator);
    defer cache.deinit();

    // First lookup — cache miss
    const r1 = cache.lookup(1, "hero", &mgr).?;
    try testing.expectEqual(64, r1.sprite.width);
    try testing.expectEqual(5, r1.texture_id);
    try testing.expectEqual(1, cache.misses);
    try testing.expectEqual(0, cache.hits);

    // Second lookup — cache hit (same entity, same name, same version)
    const r2 = cache.lookup(1, "hero", &mgr).?;
    try testing.expectEqual(64, r2.sprite.width);
    try testing.expectEqual(1, cache.hits);
    try testing.expectEqual(1, cache.misses);
}

test "SpriteCache: invalidates on atlas version change" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const atlas = try mgr.addAtlas("chars");
    atlas.texture_id = 5;
    try atlas.addSprite("hero", .{ .x = 0, .y = 0, .width = 64, .height = 64 });

    var cache = engine.SpriteCache.init(testing.allocator);
    defer cache.deinit();

    _ = cache.lookup(1, "hero", &mgr);
    try testing.expectEqual(1, cache.misses);

    // Load another atlas — version changes, cache should miss
    const a2 = try mgr.addAtlas("enemies");
    try a2.addSprite("goblin", .{ .x = 0, .y = 0, .width = 32, .height = 32 });

    _ = cache.lookup(1, "hero", &mgr);
    try testing.expectEqual(2, cache.misses); // Re-lookup due to version change
}

test "SpriteCache: invalidates on sprite name change" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const atlas = try mgr.addAtlas("chars");
    atlas.texture_id = 5;
    try atlas.addSprite("idle", .{ .x = 0, .y = 0, .width = 32, .height = 32 });
    try atlas.addSprite("walk", .{ .x = 32, .y = 0, .width = 32, .height = 48 });

    var cache = engine.SpriteCache.init(testing.allocator);
    defer cache.deinit();

    const r1 = cache.lookup(1, "idle", &mgr).?;
    try testing.expectEqual(0, r1.sprite.x);

    // Same entity, different sprite name — cache miss
    const r2 = cache.lookup(1, "walk", &mgr).?;
    try testing.expectEqual(32, r2.sprite.x);
    try testing.expectEqual(2, cache.misses);
}

test "SpriteCache: invalidate removes entity entry" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const atlas = try mgr.addAtlas("chars");
    try atlas.addSprite("hero", .{ .x = 0, .y = 0, .width = 64, .height = 64 });

    var cache = engine.SpriteCache.init(testing.allocator);
    defer cache.deinit();

    _ = cache.lookup(1, "hero", &mgr);
    try testing.expectEqual(1, cache.entryCount());

    cache.invalidate(1);
    try testing.expectEqual(0, cache.entryCount());
}

test "SpriteCache: clear removes all entries" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const atlas = try mgr.addAtlas("chars");
    try atlas.addSprite("a", .{ .x = 0, .y = 0, .width = 16, .height = 16 });
    try atlas.addSprite("b", .{ .x = 16, .y = 0, .width = 16, .height = 16 });

    var cache = engine.SpriteCache.init(testing.allocator);
    defer cache.deinit();

    _ = cache.lookup(1, "a", &mgr);
    _ = cache.lookup(2, "b", &mgr);
    try testing.expectEqual(2, cache.entryCount());

    cache.clear();
    try testing.expectEqual(0, cache.entryCount());
}

test "TextureManager: loadAtlasComptime from ComptimeAtlas" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const frames = .{
        .idle = .{ .x = 0, .y = 0, .w = 32, .h = 32, .rotated = false, .trimmed = false, .orig_w = 32, .orig_h = 32, .source_x = 0, .source_y = 0 },
        .walk = .{ .x = 32, .y = 0, .w = 24, .h = 48, .rotated = true, .trimmed = true, .orig_w = 32, .orig_h = 64, .source_x = 4, .source_y = 2 },
    };
    const Atlas = engine.ComptimeAtlas(frames);

    try mgr.loadAtlasComptime("test", &Atlas.sprites, 10);

    try testing.expectEqual(1, mgr.atlasCount());
    try testing.expectEqual(2, mgr.totalSpriteCount());

    const idle = mgr.findSprite("idle").?;
    try testing.expectEqual(0, idle.sprite.x);
    try testing.expectEqual(32, idle.sprite.width);
    try testing.expectEqual(10, idle.texture_id);

    const walk = mgr.findSprite("walk").?;
    try testing.expectEqual(32, walk.sprite.x);
    try testing.expect(walk.sprite.rotated);
    try testing.expectEqual(48, walk.sprite.getWidth()); // rotated
    try testing.expectEqual(24, walk.sprite.getHeight());
}

test "TextureManager: version increments on changes" {
    var mgr = engine.TextureManager.init(testing.allocator);
    defer mgr.deinit();

    const v0 = mgr.getVersion();
    _ = try mgr.addAtlas("a");
    const v1 = mgr.getVersion();
    try testing.expect(v1 > v0);

    mgr.unloadAtlas("a");
    const v2 = mgr.getVersion();
    try testing.expect(v2 > v1);
}

test "SpriteData: rotation swaps dimensions" {
    const s = engine.SpriteData{ .x = 0, .y = 0, .width = 32, .height = 64, .rotated = true };
    try testing.expectEqual(64, s.getWidth());
    try testing.expectEqual(32, s.getHeight());

    const s2 = engine.SpriteData{ .x = 0, .y = 0, .width = 32, .height = 64, .rotated = false };
    try testing.expectEqual(32, s2.getWidth());
    try testing.expectEqual(64, s2.getHeight());
}
