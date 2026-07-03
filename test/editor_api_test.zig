//! labelle-studio Play mode (Phase 3) — editor_api contract tests.
//!
//! The module keeps its dispatch state (vtable, pause/step counters,
//! camera override) in module-scope vars, so every test starts and ends
//! with `editor_api.unbind()` to stay isolated.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const editor_api = engine.editor_api;
const Game = engine.Game;

/// Dummy stand-in for the generated main's ScriptRunner pointer — the
/// v1 contract stores it but dispatches nothing through it.
const DummyRunner = struct { ticks: u32 = 0 };

fn digestInto(buf: []u8) []const u8 {
    const n = editor_api.editor_scene_digest(buf.ptr, buf.len);
    return buf[0..n];
}

// ── Pause / step tick gating ────────────────────────────────────────

test "shouldTick: unpaused always ticks; paused freezes; steps advance N ticks" {
    editor_api.unbind();
    defer editor_api.unbind();

    // Unpaused: always tick.
    try testing.expect(editor_api.shouldTick());
    try testing.expect(editor_api.shouldTick());

    // Paused: frozen.
    editor_api.editor_pause(1);
    try testing.expect(editor_api.isPaused());
    try testing.expect(!editor_api.shouldTick());
    try testing.expect(!editor_api.shouldTick());

    // Step 3: exactly three ticks, then frozen again.
    editor_api.editor_step(3);
    try testing.expect(editor_api.shouldTick());
    try testing.expect(editor_api.shouldTick());
    try testing.expect(editor_api.shouldTick());
    try testing.expect(!editor_api.shouldTick());

    // Resume: ticking again.
    editor_api.editor_pause(0);
    try testing.expect(editor_api.shouldTick());
}

test "shouldTick: resume discards pending steps; step while unpaused is ignored" {
    editor_api.unbind();
    defer editor_api.unbind();

    // Steps while unpaused don't accumulate.
    editor_api.editor_step(5);
    editor_api.editor_pause(1);
    try testing.expect(!editor_api.shouldTick());

    // Pending steps are cleared by resume.
    editor_api.editor_step(5);
    editor_api.editor_pause(0);
    editor_api.editor_pause(1);
    try testing.expect(!editor_api.shouldTick());
}

// ── Pre-bind no-op safety ───────────────────────────────────────────

test "pre-bind: every export is a safe no-op" {
    editor_api.unbind();
    defer editor_api.unbind();

    // Scene ops report failure (no game to act on).
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_scene("main", 4));
    try testing.expectEqual(@as(i32, -1), editor_api.editor_load_scene("main", 4, "{}", 2));

    // Void setters silently ignore.
    editor_api.editor_set_entity_position(42, 1.0, 2.0);

    // Pick is the documented v1 stub.
    try testing.expectEqual(@as(i64, -1), editor_api.editor_pick(10.0, 20.0));

    // Digest degrades to the empty object…
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{}", digestInto(&buf));
    // …and to zero bytes when even that doesn't fit.
    var tiny: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), editor_api.editor_scene_digest(&tiny, 1));

    // Camera override state machine works without a bound game.
    editor_api.editor_set_camera(5.0, 6.0, 2.0);
    try testing.expect(editor_api.cameraOverride() != null);
    editor_api.editor_release_camera();
    try testing.expect(editor_api.cameraOverride() == null);
}

test "editor_alloc / editor_free round-trip" {
    const ptr = editor_api.editor_alloc(128) orelse return error.TestUnexpectedResult;
    ptr[0] = 0xAB;
    ptr[127] = 0xCD;
    editor_api.editor_free(ptr, 128);

    // Zero-length requests are no-ops, not crashes.
    try testing.expect(editor_api.editor_alloc(0) == null);
}

// ── Digest JSON shape ───────────────────────────────────────────────

test "digest: JSON shape with scene name, paused flag, sprites, and positions" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const loader = struct {
        fn load(_: *Game) anyerror!void {}
    }.load;
    game.registerSceneSimple("arena", loader);
    try game.setScene("arena");

    const e1 = game.createEntity();
    game.setPosition(e1, .{ .x = 100, .y = 200 });
    game.addSprite(e1, .{ .sprite_name = "player" });

    const e2 = game.createEntity();
    game.setPosition(e2, .{ .x = -3.5, .y = 0 });

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);
    editor_api.editor_pause(1);

    var buf: [4096]u8 = undefined;
    const json = digestInto(&buf);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try testing.expectEqualStrings("arena", root.get("scene").?.string);
    try testing.expectEqual(@as(i64, 1), root.get("paused").?.integer);
    try testing.expectEqual(@as(i64, 2), root.get("entity_count").?.integer);

    const entities = root.get("entities").?.array;
    try testing.expectEqual(@as(usize, 2), entities.items.len);

    var saw_sprite = false;
    var saw_bare = false;
    for (entities.items) |item| {
        const obj = item.object;
        try testing.expect(obj.get("id") != null);
        try testing.expect(obj.get("x") != null);
        try testing.expect(obj.get("y") != null);
        if (obj.get("sprite")) |sprite| {
            try testing.expectEqualStrings("player", sprite.string);
            try testing.expectEqual(@as(i64, 100), obj.get("x").?.integer);
            try testing.expectEqual(@as(i64, 200), obj.get("y").?.integer);
            saw_sprite = true;
        } else {
            try testing.expectEqual(@as(f64, -3.5), obj.get("x").?.float);
            saw_bare = true;
        }
    }
    try testing.expect(saw_sprite);
    try testing.expect(saw_bare);

    // Resuming flips the reported paused flag.
    editor_api.editor_pause(0);
    const json2 = digestInto(&buf);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, json2, .{});
    defer parsed2.deinit();
    try testing.expectEqual(@as(i64, 0), parsed2.value.object.get("paused").?.integer);
}

test "digest: truncation keeps valid JSON and the full entity_count" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const e = game.createEntity();
        game.setPosition(e, .{ .x = @floatFromInt(i), .y = @floatFromInt(i * 2) });
    }

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // Small cap: entity list must truncate, JSON must stay parseable.
    var small: [160]u8 = undefined;
    const json = digestInto(&small);
    try testing.expect(json.len <= small.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 50), root.get("entity_count").?.integer);
    const listed = root.get("entities").?.array.items.len;
    try testing.expect(listed < 50);

    // Caps too small for even the prefix degrade to "{}" — still JSON.
    var minimal: [8]u8 = undefined;
    try testing.expectEqualStrings("{}", digestInto(&minimal));

    // cap < 2: nothing written.
    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), editor_api.editor_scene_digest(&one, 1));

    // Every cap in between must yield valid JSON (never a torn tail).
    var cap: usize = 2;
    var sweep: [512]u8 = undefined;
    while (cap <= 400) : (cap += 7) {
        const n = editor_api.editor_scene_digest(&sweep, cap);
        var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, sweep[0..n], .{});
        p.deinit();
    }
}

test "digest: parented entities report WORLD positions (the space editor_set_entity_position consumes)" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 100, .y = 200 });
    const child = game.createEntity();
    game.setPosition(child, .{ .x = 10, .y = 20 }); // local to parent
    game.setParent(child, parent, .{});

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    var buf: [1024]u8 = undefined;
    const json = digestInto(&buf);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var saw_child = false;
    for (parsed.value.object.get("entities").?.array.items) |item| {
        const obj = item.object;
        if (obj.get("id").?.integer == @as(i64, @intCast(child))) {
            // 100+10 / 200+20 — world, not the raw local Position.
            try testing.expectEqual(@as(i64, 110), obj.get("x").?.integer);
            try testing.expectEqual(@as(i64, 220), obj.get("y").?.integer);
            saw_child = true;
        }
    }
    try testing.expect(saw_child);

    // Round-trip: what the digest reports is exactly what
    // editor_set_entity_position accepts back.
    editor_api.editor_set_entity_position(@intCast(child), 110, 220);
    const local = game.getComponent(child, core.Position).?;
    try testing.expectEqual(@as(f32, 10), local.x);
    try testing.expectEqual(@as(f32, 20), local.y);
}

// ── Entity ops through the bound vtable ─────────────────────────────

test "editor_set_entity_position: moves the entity and ignores bad ids" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 1, .y = 2 });
    const bare = game.createEntity(); // alive but positionless

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    editor_api.editor_set_entity_position(@intCast(e), 320.0, 240.0);
    const pos = game.getComponent(e, core.Position).?;
    try testing.expectEqual(@as(f32, 320.0), pos.x);
    try testing.expectEqual(@as(f32, 240.0), pos.y);

    // Positionless and unknown ids are ignored, not crashes.
    editor_api.editor_set_entity_position(@intCast(bare), 9.0, 9.0);
    try testing.expect(game.getComponent(bare, core.Position) == null);
    editor_api.editor_set_entity_position(999_999, 1.0, 1.0);
    editor_api.editor_set_entity_position(std.math.maxInt(u64), 1.0, 1.0);
}

test "editor_set_scene: 0 on known scene, -1 on unknown" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const loader = struct {
        fn load(g: *Game) anyerror!void {
            const e = g.createEntity();
            g.setPosition(e, .{ .x = 0, .y = 0 });
            g.trackSceneEntity(e);
        }
    }.load;
    game.registerSceneSimple("level1", loader);

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    try testing.expectEqual(@as(i32, 0), editor_api.editor_set_scene("level1", 6));
    try testing.expectEqualStrings("level1", game.getCurrentSceneName().?);
    try testing.expectEqual(@as(usize, 1), game.entityCount());

    // Unknown scene: rejected up front — the running scene survives
    // (a raw setScene would have torn it down before erroring).
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_scene("nope", 4));
    try testing.expectEqualStrings("level1", game.getCurrentSceneName().?);
    try testing.expectEqual(@as(usize, 1), game.entityCount());
}

// ── Camera override state machine ───────────────────────────────────

const FakeCamera = struct {
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 1,

    pub fn setPosition(self: *FakeCamera, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
    }
    pub fn setZoom(self: *FakeCamera, level: f32) void {
        self.zoom = level;
    }
};

/// Minimal Game-shaped stand-in for `editor_api.frame` — only the
/// camera surface (`CameraType` + `getCamera`) is duck-typed there.
const CameraGame = struct {
    pub const CameraType = FakeCamera;
    cam: FakeCamera = .{},

    pub fn getCamera(self: *CameraGame) *FakeCamera {
        return &self.cam;
    }
};

test "camera override: engage → re-assert after tick → release" {
    editor_api.unbind();
    defer editor_api.unbind();

    var cg = CameraGame{};

    // No override: frame leaves the gameplay camera alone.
    cg.cam.setPosition(10, 10);
    editor_api.frame(&cg);
    try testing.expectEqual(@as(f32, 10), cg.cam.x);

    // Engage: frame asserts the editor camera.
    editor_api.editor_set_camera(100, 200, 2.5);
    editor_api.frame(&cg);
    try testing.expectEqual(@as(f32, 100), cg.cam.x);
    try testing.expectEqual(@as(f32, 200), cg.cam.y);
    try testing.expectEqual(@as(f32, 2.5), cg.cam.zoom);

    // A camera_control-style script fights back during the tick; the
    // post-tick frame() must win by writing last.
    cg.cam.setPosition(0, 0);
    cg.cam.setZoom(1);
    editor_api.frame(&cg);
    try testing.expectEqual(@as(f32, 100), cg.cam.x);
    try testing.expectEqual(@as(f32, 2.5), cg.cam.zoom);

    // Re-engaging with new values updates the override in place.
    editor_api.editor_set_camera(-50, 60, 0.5);
    editor_api.frame(&cg);
    try testing.expectEqual(@as(f32, -50), cg.cam.x);

    // Release: the game camera is left wherever its scripts put it.
    editor_api.editor_release_camera();
    cg.cam.setPosition(7, 8);
    editor_api.frame(&cg);
    try testing.expectEqual(@as(f32, 7), cg.cam.x);
    try testing.expectEqual(@as(f32, 8), cg.cam.y);
}

test "camera override: documented loop order (tick → frame → render) shows the override on every rendered frame" {
    editor_api.unbind();
    defer editor_api.unbind();

    var cg = CameraGame{};
    editor_api.editor_set_camera(100, 200, 2.0);

    // Simulate the generated main's UNPAUSED loop: each tick a
    // camera_control-style script re-asserts the gameplay camera, then
    // editor_api.frame runs, then render reads the camera. Because
    // frame() runs after the tick but BEFORE render, the override must
    // be what every rendered frame observes — not just while paused.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try testing.expect(editor_api.shouldTick());
        // tick: the script writes the gameplay camera.
        cg.cam.setPosition(0, 0);
        cg.cam.setZoom(1);
        // frame: the editor writes last…
        editor_api.frame(&cg);
        // render: …so this is what reaches the screen.
        try testing.expectEqual(@as(f32, 100), cg.cam.x);
        try testing.expectEqual(@as(f32, 200), cg.cam.y);
        try testing.expectEqual(@as(f32, 2.0), cg.cam.zoom);
    }
}

test "camera override: comptime no-op for camera-less games (StubRender)" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // StubRender has no CameraType — both the immediate apply and the
    // per-frame re-assert must fold away without touching anything.
    editor_api.editor_set_camera(1, 2, 3);
    editor_api.frame(&game);
    editor_api.editor_release_camera();
}
