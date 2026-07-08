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

    // Scene/state/animation/prefab ops report failure (no game to act on).
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_scene("main", 4));
    try testing.expectEqual(@as(i32, -1), editor_api.editor_load_scene("main", 4, "{}", 2));
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_state("playing", 7));
    try testing.expectEqual(@as(i32, -1), editor_api.editor_load_animation_def("worker", 6, ".{}", 3));
    try testing.expectEqual(@as(i32, -1), editor_api.editor_reload_prefab("condenser", 9, "{}", 2));

    // Void setters silently ignore.
    editor_api.editor_set_entity_position(42, 1.0, 2.0);

    // Generic per-component edit (v1.5) reports "not bound" pre-bind.
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_component(42, "Camera", 6, "{\"zoom\":1}", 10));

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
    try testing.expectEqualStrings("running", root.get("state").?.string);
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

    // Resuming flips the reported paused flag; a state switch shows
    // up in the same digest (v1.1).
    editor_api.editor_pause(0);
    try testing.expectEqual(@as(i32, 0), editor_api.editor_set_state("playing", 7));
    const json2 = digestInto(&buf);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, json2, .{});
    defer parsed2.deinit();
    try testing.expectEqual(@as(i64, 0), parsed2.value.object.get("paused").?.integer);
    try testing.expectEqualStrings("playing", parsed2.value.object.get("state").?.string);
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

test "editor_set_state: switches the state machine, copies the name, rejects only empty" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // Happy path: default "running" -> "playing".
    try testing.expectEqualStrings("running", game.getState());
    try testing.expectEqual(@as(i32, 0), editor_api.editor_set_state("playing", 7));
    try testing.expectEqualStrings("playing", game.getState());

    // The name is copied into game-owned memory: hand in a transient
    // buffer (the studio frees its wasm buffer right after the call).
    const buf = try testing.allocator.dupe(u8, "combat");
    try testing.expectEqual(@as(i32, 0), editor_api.editor_set_state(buf.ptr, buf.len));
    testing.allocator.free(buf);
    try testing.expectEqualStrings("combat", game.getState());
    try testing.expect(game.getState().ptr != buf.ptr);

    // Unknown states are VALID by construction — the engine has no
    // state registry (free-form strings scripts gate on), so unlike
    // editor_set_scene there is nothing to pre-validate against and
    // nothing gets torn down; a typo is recoverable in place.
    try testing.expectEqual(@as(i32, 0), editor_api.editor_set_state("no_script_listens_here", 22));
    try testing.expectEqualStrings("no_script_listens_here", game.getState());

    // Empty name: the one rejected input; state unchanged.
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_state("x", 0));
    try testing.expectEqualStrings("no_script_listens_here", game.getState());
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

// ── editor_load_animation_def (contract v1.2, studio issue #24) ─────

/// FP-shaped, ENUM-typed animation component opted into hot reload via
/// the `anim_def_name` decl (see `game/animation_runtime_mixin.zig`).
const TypedAnimState = struct {
    pub const anim_def_name = "worker";

    const Clip = enum(u8) { idle, walk };
    const Variant = enum(u8) { a, b };

    clip: Clip = .idle,
    variant: Variant = .a,
    frame_count: u8 = 1,
    speed: f32 = 1.0,
    mode: engine.AnimMode = .static,
    frame: u8 = 0,
    dirty: bool = false,
};

/// Engine-shaped (raw u8) component bound to the SAME def — both must
/// refresh from one push.
const RawAnimState = struct {
    pub const anim_def_name = "worker";

    clip: u8 = 0,
    variant: u8 = 0,
    frame_count: u8 = 1,
    speed: f32 = 1.0,
    mode: engine.AnimMode = .static,
    frame: u8 = 0,
    dirty: bool = false,
};

/// Bound to a DIFFERENT def — a "worker" push must never touch it.
const OtherAnimState = struct {
    pub const anim_def_name = "bandit";

    clip: u8 = 0,
    variant: u8 = 0,
    frame_count: u8 = 4,
    speed: f32 = 8.0,
    mode: engine.AnimMode = .time,
    frame: u8 = 2,
    dirty: bool = false,
};

const AnimComponents = engine.ComponentRegistry(.{
    .TypedAnimState = TypedAnimState,
    .RawAnimState = RawAnimState,
    .OtherAnimState = OtherAnimState,
});

const AnimMockEcs = core.MockEcsBackend(u32);
const AnimGame = engine.game_mod.GameConfig(
    core.StubRender(AnimMockEcs.Entity),
    AnimMockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    AnimComponents,
    &.{},
    void,
);

const WORKER_V2 =
    \\.{
    \\    .variants = .{ "a", "b" },
    \\    .clips = .{
    \\        .idle = .{ .frames = 1 },
    \\        .walk = .{ .frames = 2, .mode = .distance, .speed = 30.0 },
    \\    },
    \\}
;

test "editor_load_animation_def: parses, installs, and refreshes opted-in components" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = AnimGame.init(testing.allocator);
    defer game.deinit();

    // Live entities mid-walk holding the STALE comptime numbers
    // (4 frames @ 15.0), the shape of FP workers when a studio save
    // lands: frame 3 will be out of range after the reload shrinks
    // walk to 2 frames.
    const typed_ent = game.createEntity();
    game.active_world.ecs_backend.addComponent(typed_ent, TypedAnimState{
        .clip = .walk,
        .variant = .b,
        .frame = 3,
        .frame_count = 4,
        .speed = 15.0,
        .mode = .distance,
    });
    const raw_ent = game.createEntity();
    game.active_world.ecs_backend.addComponent(raw_ent, RawAnimState{
        .clip = 1,
        .frame = 3,
        .frame_count = 4,
        .speed = 15.0,
        .mode = .distance,
    });
    const other_ent = game.createEntity();
    game.active_world.ecs_backend.addComponent(other_ent, OtherAnimState{});

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    try testing.expectEqual(@as(i32, 0), editor_api.editor_load_animation_def("worker", 6, WORKER_V2, WORKER_V2.len));

    // Installed and queryable through the game API (the AnimDefSource
    // seam game code resolves through).
    const def = game.runtimeAnimDef("worker").?;
    try testing.expectEqualStrings("walk", def.clip_names[1]);
    try testing.expectEqual(@as(f32, 30.0), def.clipMeta(1).speed);

    // Enum-typed component: meta re-copied, frame clamped, dirty set.
    const t = game.active_world.ecs_backend.getComponent(typed_ent, TypedAnimState).?;
    try testing.expectEqual(TypedAnimState.Clip.walk, t.clip);
    try testing.expectEqual(TypedAnimState.Variant.b, t.variant);
    try testing.expectEqual(@as(f32, 30.0), t.speed);
    try testing.expectEqual(@as(u8, 2), t.frame_count);
    try testing.expectEqual(@as(u8, 1), t.frame); // 3 clamped to count-1
    try testing.expect(t.dirty);

    // Raw-u8 component refreshed from the same push.
    const r = game.active_world.ecs_backend.getComponent(raw_ent, RawAnimState).?;
    try testing.expectEqual(@as(f32, 30.0), r.speed);
    try testing.expectEqual(@as(u8, 2), r.frame_count);
    try testing.expect(r.dirty);

    // Component bound to another def: byte-for-byte untouched.
    const o = game.active_world.ecs_backend.getComponent(other_ent, OtherAnimState).?;
    try testing.expectEqual(@as(f32, 8.0), o.speed);
    try testing.expectEqual(@as(u8, 4), o.frame_count);
    try testing.expect(!o.dirty);
}

test "editor_load_animation_def: malformed source is rejected and the old def stays live" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = AnimGame.init(testing.allocator);
    defer game.deinit();
    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    try testing.expectEqual(@as(i32, 0), editor_api.editor_load_animation_def("worker", 6, WORKER_V2, WORKER_V2.len));

    // Half-saved file mid-edit: parse failure → -2, nothing changes.
    const garbage = ".{ .variants = .{ \"a\" }, .clips = ";
    try testing.expectEqual(@as(i32, -2), editor_api.editor_load_animation_def("worker", 6, garbage, garbage.len));
    // Structurally valid ZON that fails def validation → also -2.
    const no_clips = ".{ .variants = .{ \"a\" } }";
    try testing.expectEqual(@as(i32, -2), editor_api.editor_load_animation_def("worker", 6, no_clips, no_clips.len));

    // The previous generation is still the live one.
    try testing.expectEqual(@as(f32, 30.0), game.runtimeAnimDef("worker").?.clipMeta(1).speed);

    // Empty name: host-side length bug — rejected without touching the game.
    try testing.expectEqual(@as(i32, -1), editor_api.editor_load_animation_def("x", 0, WORKER_V2, WORKER_V2.len));
}

// ── editor_reload_prefab (contract v1.3, studio issue #24) ──────────
//
// The prefab half of #24: replace-or-insert the prefab REGISTRY entry
// so future spawns use the new source. Existing instances keep their
// components — including `[]const u8` fields aliasing the replaced
// (retired, never freed) parse tree, which the tests read back after
// the swap to pin the graveyard contract.

/// Carries a string field on purpose: deserialized `text` is a slice
/// into the prefab's parsed source tree, so an instance spawned from v1
/// still reading "v1-overlay" after a v2 push proves the old tree
/// survives the registry swap.
const PipeOverlay = struct {
    text: []const u8 = "",
    fps: f32 = 0,
};

const PrefabComponents = engine.ComponentRegistry(.{
    .PipeOverlay = PipeOverlay,
});

const PrefabBridge = engine.JsoncSceneBridge(engine.Game, PrefabComponents);

const CONDENSER_V1 =
    \\{ "components": { "PipeOverlay": { "text": "v1-overlay", "fps": 6.0 } } }
;
const CONDENSER_V2 =
    \\{ "components": { "PipeOverlay": { "text": "v2-overlay", "fps": 24.0 } } }
;

/// Boot the assembler's wasm sequence: embedded prefab registration,
/// then a scene load (which attaches the prefab cache to the game and
/// enables `spawnPrefab`).
fn bootPrefabGame(game: *engine.Game) !void {
    try PrefabBridge.addEmbeddedPrefab(game, "condenser", CONDENSER_V1, "prefabs");
    try PrefabBridge.loadSceneFromSource(game,
        \\{ "entities": [] }
    , "prefabs");
}

test "editor_reload_prefab: future spawns use the pushed source; existing instances keep the retired data" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try bootPrefabGame(&game);

    // A live instance spawned from v1 — the shape of a condenser
    // overlay already in the world when a studio save lands.
    const before = game.spawnPrefab("condenser", .{ .x = 10, .y = 20 }).?;
    {
        const c = game.ecs_backend.getComponent(before, PipeOverlay).?;
        try testing.expectEqualStrings("v1-overlay", c.text);
        try testing.expectEqual(@as(f32, 6.0), c.fps);
    }

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // Push v2 from a TRANSIENT buffer (the studio frees its wasm buffer
    // right after the call — the engine must have copied what it keeps).
    const src = try testing.allocator.dupe(u8, CONDENSER_V2);
    try testing.expectEqual(@as(i32, 0), editor_api.editor_reload_prefab("condenser", 9, src.ptr, src.len));
    testing.allocator.free(src);

    // Future spawn: the new definition.
    const after = game.spawnPrefab("condenser", .{ .x = 30, .y = 40 }).?;
    const c2 = game.ecs_backend.getComponent(after, PipeOverlay).?;
    try testing.expectEqualStrings("v2-overlay", c2.text);
    try testing.expectEqual(@as(f32, 24.0), c2.fps);

    // Existing instance: untouched, and its string still reads the OLD
    // tree byte-for-byte — the replaced generation was retired, not
    // freed (the sim may be paused; nothing will re-resolve the slice).
    const c1 = game.ecs_backend.getComponent(before, PipeOverlay).?;
    try testing.expectEqualStrings("v1-overlay", c1.text);
    try testing.expectEqual(@as(f32, 6.0), c1.fps);
}

test "editor_reload_prefab: malformed/invalid sources are rejected and the old definition stays live" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try bootPrefabGame(&game);

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // Half-saved file mid-edit: parse failure → -2.
    const garbage = "{ \"components\": { \"PipeOverlay\": ";
    try testing.expectEqual(@as(i32, -2), editor_api.editor_reload_prefab("condenser", 9, garbage, garbage.len));

    // Parses, but a prefab must be a single entity OBJECT (an array top
    // level is a scene-bundle shape) → -2.
    const bundle = "[ { \"components\": {} } ]";
    try testing.expectEqual(@as(i32, -2), editor_api.editor_reload_prefab("condenser", 9, bundle, bundle.len));

    // RFC #560 §B2: a prefab REFERENCE root cannot also author
    // children → -2 at push time (spawn would only fail later).
    const b2 = "{ \"prefab\": \"other\", \"children\": [] }";
    try testing.expectEqual(@as(i32, -2), editor_api.editor_reload_prefab("condenser", 9, b2, b2.len));

    // Empty name: host-side length bug — rejected up front.
    try testing.expectEqual(@as(i32, -1), editor_api.editor_reload_prefab("x", 0, CONDENSER_V2, CONDENSER_V2.len));

    // After every rejection the registry still serves v1.
    const e = game.spawnPrefab("condenser", .{ .x = 0, .y = 0 }).?;
    const c = game.ecs_backend.getComponent(e, PipeOverlay).?;
    try testing.expectEqualStrings("v1-overlay", c.text);
    try testing.expectEqual(@as(f32, 6.0), c.fps);
}

test "editor_reload_prefab: inserts brand-new prefabs, keyed by the source's effective name" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try bootPrefabGame(&game);

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // A prefab file created while Play mode runs: no previous entry —
    // the push INSERTS and the name becomes spawnable immediately.
    const vent =
        \\{ "components": { "PipeOverlay": { "text": "vent", "fps": 12.0 } } }
    ;
    try testing.expectEqual(@as(i32, 0), editor_api.editor_reload_prefab("steam_vent", 10, vent, vent.len));
    const e = game.spawnPrefab("steam_vent", .{ .x = 0, .y = 0 }).?;
    try testing.expectEqualStrings("vent", game.ecs_backend.getComponent(e, PipeOverlay).?.text);

    // Keying matches addEmbeddedPrefab/scanDir: an explicit `"name"`
    // field outranks the pushed name (RFC #561 flat registry) — the
    // entry registers under the EFFECTIVE name.
    const named =
        \\{ "name": "renamed_vent", "components": { "PipeOverlay": { "text": "renamed" } } }
    ;
    try testing.expectEqual(@as(i32, 0), editor_api.editor_reload_prefab("whatever", 8, named, named.len));
    const r = game.spawnPrefab("renamed_vent", .{ .x = 0, .y = 0 }).?;
    try testing.expectEqualStrings("renamed", game.ecs_backend.getComponent(r, PipeOverlay).?.text);
}

test "reloadPrefabSource: a push BEFORE any scene load creates the cache the boot then reuses" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    // No scene, no cache yet — the push must not require one (the
    // studio parks pushes until boot, but the ENGINE side stays safe
    // regardless of host ordering).
    try game.reloadPrefabSource("early_bird", CONDENSER_V2);

    // The boot sequence reuses the already-attached cache
    // (`getOrCreatePrefabCache` contract), so both the pre-push prefab
    // and the embedded one resolve.
    try bootPrefabGame(&game);
    const e = game.spawnPrefab("early_bird", .{ .x = 0, .y = 0 }).?;
    try testing.expectEqualStrings("v2-overlay", game.ecs_backend.getComponent(e, PipeOverlay).?.text);
    const c = game.spawnPrefab("condenser", .{ .x = 0, .y = 0 }).?;
    try testing.expectEqualStrings("v1-overlay", game.ecs_backend.getComponent(c, PipeOverlay).?.text);
}

// ── Camera prefabs (contract v1.5, #714) ────────────────────────────
//
// A camera-CAPABLE game: a stub renderer that additionally exposes the
// camera seam (`CameraType` with setPosition/setZoom/getViewport +
// getCamera), configured with a MockEcs so it can hold `Camera` entities.
// This is the shape the seed / apply-while-paused / digest / set-component
// paths need — the default `engine.Game` (StubRender) has no camera and
// folds them all away at comptime.

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn getType(comptime _: []const u8) type {
        return void;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

/// Camera stand-in exposing the full seam the camera-prefabs paths touch:
/// setPosition/setZoom (the `gameHasCamera` gate) + getViewport (the digest
/// `view`). `getViewport` returns the world rect centered on the camera,
/// sized by an 800×600 design surface over `zoom` — the same math gfx's
/// `CameraWith.getViewport` uses.
const CamCamera = struct {
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 1,

    const ViewRect = struct { x: f32, y: f32, width: f32, height: f32 };

    pub fn setPosition(self: *CamCamera, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
    }
    pub fn setZoom(self: *CamCamera, level: f32) void {
        self.zoom = level;
    }
    pub fn getViewport(self: *const CamCamera) ViewRect {
        const w = 800.0 / self.zoom;
        const h = 600.0 / self.zoom;
        return .{ .x = self.x - w / 2.0, .y = self.y - h / 2.0, .width = w, .height = h };
    }
};

/// Stub renderer mirroring `core.StubRender`'s no-op surface plus the camera
/// seam (as `GfxRendererWith` exposes it: `CameraType`/`CameraManagerType` +
/// `getCamera`/`getCameraManager`).
fn CamRender(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            shape: union(enum) {
                rectangle: struct { width: f32 = 10, height: f32 = 10 },
                circle: struct { radius: f32 = 10 },
            } = .{ .rectangle = .{} },
            color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Text = struct {
            text: [:0]const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
        };
        pub const Icon = struct {
            name: []const u8 = "",
            visible: bool = true,
        };

        pub const CameraType = CamCamera;
        pub const CameraManagerType = struct {};

        camera: CamCamera = .{},
        tracked_count: usize = 0,
        render_count: usize = 0,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(self: *Self, _: Entity, _: core.render.VisualType) void {
            self.tracked_count += 1;
        }
        pub fn untrackEntity(self: *Self, _: Entity) void {
            if (self.tracked_count > 0) self.tracked_count -= 1;
        }
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(_: *Self, _: Entity) void {}
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(self: *Self) void {
            self.render_count += 1;
        }
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(self: *Self) void {
            self.tracked_count = 0;
        }
        pub fn renderGizmoDraws(_: *Self, _: []const core.gizmos.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
        pub fn getCamera(self: *Self) *CamCamera {
            return &self.camera;
        }
        pub fn getCameraManager(self: *Self) *CameraManagerType {
            _ = self;
            return undefined;
        }
    };
}

const CamMockEcs = core.MockEcsBackend(u32);
const CameraTestGame = engine.GameConfig(
    CamRender(CamMockEcs.Entity),
    CamMockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

/// A project that registers its OWN `Camera` in its ComponentRegistry — the
/// engine built-in Camera feature must DEFER to it (finding #1).
const ProjectCamera = struct { zoom: f32 = 1.0, mode: u8 = 0 };
const RegisteredCameraComponents = engine.ComponentRegistry(.{ .Camera = ProjectCamera });
const RegisteredCameraGame = engine.GameConfig(
    CamRender(CamMockEcs.Entity),
    CamMockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    RegisteredCameraComponents,
    &.{},
    void,
);

/// Read a JSON number as f64 regardless of whether it serialized as an
/// integer (`{d}` on a whole f32 drops the fraction, e.g. `400`) or a float
/// (`533.333…`).
fn jsonNum(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => unreachable,
    };
}

test "camera seed: reads the WORLD position of the (parented) camera entity, not the raw local" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();

    const rig = game.createEntity();
    game.setPosition(rig, .{ .x = 100, .y = 200 });
    const cam_ent = game.createEntity();
    game.setPosition(cam_ent, .{ .x = 10, .y = 20 }); // local to rig
    game.setParent(cam_ent, rig, .{});
    game.addComponent(cam_ent, engine.Camera{ .zoom = 2.0 });

    // FLAG A: the seed reads getWorldPosition (100+10, 200+20), matching the
    // digest / editor_set_entity_position — NOT the raw local Position.
    game.seedCameraFromComponent();
    const cam = game.getCamera();
    try testing.expectEqual(@as(f32, 110), cam.x);
    try testing.expectEqual(@as(f32, 220), cam.y);
    try testing.expectEqual(@as(f32, 2.0), cam.zoom);
}

test "camera seed-on-load: setScene seeds the camera from a scene-loaded Camera entity" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();

    const loader = struct {
        fn load(g: *CameraTestGame) anyerror!void {
            const e = g.createEntity();
            g.setPosition(e, .{ .x = 640, .y = 360 });
            g.addComponent(e, engine.Camera{ .zoom = 2.5 });
            g.trackSceneEntity(e);
        }
    }.load;
    game.registerSceneSimple("cam_scene", loader);
    try game.setScene("cam_scene");

    // setScene ran seedCameraFromComponent after the loader instantiated
    // the entities — the authored camera is live without a manual call.
    try testing.expectEqual(@as(f32, 640), game.getCamera().x);
    try testing.expectEqual(@as(f32, 360), game.getCamera().y);
    try testing.expectEqual(@as(f32, 2.5), game.getCamera().zoom);
}

test "scene loader: a scene-authored \"Camera\" component attaches as the built-in and seeds" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();

    const Bridge = engine.JsoncSceneBridge(CameraTestGame, EmptyComponents);
    try Bridge.loadSceneFromSource(&game,
        \\{ "entities": [
        \\   { "components": { "Position": { "x": 512, "y": 384 }, "Camera": { "zoom": 3.0 } } }
        \\ ] }
    , "prefabs");

    // component_apply's built-in "Camera" branch attached the POD (rather
    // than warning it as an unknown component).
    var found: ?*engine.Camera = null;
    var v = game.ecs_backend.view(.{ core.Position, engine.Camera }, .{});
    defer v.deinit();
    while (v.next()) |e| found = game.getComponent(e, engine.Camera);
    try testing.expect(found != null);
    try testing.expectEqual(@as(f32, 3.0), found.?.zoom);

    // …and the built-in seed applies its world position + zoom.
    game.seedCameraFromComponent();
    try testing.expectEqual(@as(f32, 512), game.getCamera().x);
    try testing.expectEqual(@as(f32, 3.0), game.getCamera().zoom);
}

test "camera apply-while-paused: paused frame re-seeds from the component; override wins; unpaused leaves it" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();

    const cam_ent = game.createEntity();
    game.setPosition(cam_ent, .{ .x = 400, .y = 300 });
    game.addComponent(cam_ent, engine.Camera{ .zoom = 1.5 });

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // UNPAUSED: frame does NOT apply the component — the gameplay script owns
    // the camera on resume. A "script" write survives the frame.
    game.getCamera().setPosition(0, 0);
    game.getCamera().setZoom(1.0);
    editor_api.frame(&game);
    try testing.expectEqual(@as(f32, 0), game.getCamera().x);
    try testing.expectEqual(@as(f32, 1.0), game.getCamera().zoom);

    // PAUSED: frame re-seeds the camera from the authored component every
    // frame, so a script write between frames is overwritten by the seed.
    editor_api.editor_pause(1);
    game.getCamera().setPosition(0, 0);
    game.getCamera().setZoom(1.0);
    editor_api.frame(&game);
    try testing.expectEqual(@as(f32, 400), game.getCamera().x);
    try testing.expectEqual(@as(f32, 300), game.getCamera().y);
    try testing.expectEqual(@as(f32, 1.5), game.getCamera().zoom);

    // A live inspector edit (component mutated in place) shows on the next
    // paused frame — this is what makes editing feel live.
    game.getComponent(cam_ent, engine.Camera).?.zoom = 2.0;
    editor_api.frame(&game);
    try testing.expectEqual(@as(f32, 2.0), game.getCamera().zoom);

    // The look-around override still wins on top, applied last by frame().
    editor_api.editor_set_camera(-50, 60, 0.5);
    editor_api.frame(&game);
    try testing.expectEqual(@as(f32, -50), game.getCamera().x);
    try testing.expectEqual(@as(f32, 0.5), game.getCamera().zoom);

    // Release → the paused frame hands back to the authored component.
    editor_api.editor_release_camera();
    editor_api.frame(&game);
    try testing.expectEqual(@as(f32, 400), game.getCamera().x);
    try testing.expectEqual(@as(f32, 2.0), game.getCamera().zoom);
}

test "camera apply-while-paused: comptime-folds away on a camera-less (stub) renderer" {
    editor_api.unbind();
    defer editor_api.unbind();

    // Default engine.Game is StubRender — CameraType == void.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 1, .y = 2 });
    // A Camera component can still attach (inert POD); the seed/apply path
    // that would consume it folds to nothing at comptime.
    game.addComponent(e, engine.Camera{ .zoom = 3.0 });

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // Paused frame with a Camera present: nothing to apply, no crash, no
    // getCamera() (which is `void` here) ever touched.
    editor_api.editor_pause(1);
    editor_api.frame(&game);
    game.seedCameraFromComponent(); // also a comptime no-op
}

test "digest: camera entity publishes zoom, optional viewport, and the derived world view-rect" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();

    // Camera A — no authored viewport: digest emits zoom + derived view only.
    const cam_a = game.createEntity();
    game.setPosition(cam_a, .{ .x = 400, .y = 300 });
    game.addComponent(cam_a, engine.Camera{ .zoom = 1.5 });
    game.seedCameraFromComponent(); // so getCamera() (→ `view`) reflects it

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    var buf: [4096]u8 = undefined;
    {
        const json = digestInto(&buf);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();

        var saw = false;
        for (parsed.value.object.get("entities").?.array.items) |item| {
            const obj = item.object;
            if (obj.get("id").?.integer != @as(i64, @intCast(cam_a))) continue;
            const cam = obj.get("camera").?.object;
            try testing.expectEqual(@as(f64, 1.5), jsonNum(cam.get("zoom").?));
            try testing.expect(cam.get("viewport") == null); // not authored
            // Derived world view-rect from getViewport(): 800/1.5 × 600/1.5,
            // centered on (400, 300).
            const view = cam.get("view").?.object;
            try testing.expectApproxEqAbs(@as(f64, 800.0 / 1.5), jsonNum(view.get("width").?), 0.01);
            try testing.expectApproxEqAbs(@as(f64, 600.0 / 1.5), jsonNum(view.get("height").?), 0.01);
            try testing.expectApproxEqAbs(@as(f64, 400.0 - (800.0 / 1.5) / 2.0), jsonNum(view.get("x").?), 0.01);
            saw = true;
        }
        try testing.expect(saw);
    }

    // Camera B — authored viewport round-trips in the digest (FLAG C).
    const cam_b = game.createEntity();
    game.setPosition(cam_b, .{ .x = 0, .y = 0 });
    game.addComponent(cam_b, engine.Camera{ .zoom = 1.0, .viewport = .{ .x = 10, .y = 20, .width = 30, .height = 40 } });
    {
        const json = digestInto(&buf);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        var saw_vp = false;
        for (parsed.value.object.get("entities").?.array.items) |item| {
            const obj = item.object;
            if (obj.get("id").?.integer != @as(i64, @intCast(cam_b))) continue;
            const vp = obj.get("camera").?.object.get("viewport").?.object;
            try testing.expectEqual(@as(i64, 10), vp.get("x").?.integer);
            try testing.expectEqual(@as(i64, 20), vp.get("y").?.integer);
            try testing.expectEqual(@as(i64, 30), vp.get("width").?.integer);
            try testing.expectEqual(@as(i64, 40), vp.get("height").?.integer);
            saw_vp = true;
        }
        try testing.expect(saw_vp);
    }
}

test "editor_set_component: Camera MERGES (a prior viewport survives a zoom-only patch), reseeds, and guards" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();

    const cam_ent = game.createEntity();
    game.setPosition(cam_ent, .{ .x = 400, .y = 300 });
    game.addComponent(cam_ent, engine.Camera{
        .zoom = 1.0,
        .viewport = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
    });

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);
    editor_api.editor_pause(1);

    // Patch ONLY zoom, from a transient buffer (the studio frees its wasm
    // buffer immediately after the call).
    const patch = try testing.allocator.dupe(u8, "{\"zoom\":2.0}");
    try testing.expectEqual(@as(i32, 0), editor_api.editor_set_component(@intCast(cam_ent), "Camera", 6, patch.ptr, patch.len));
    testing.allocator.free(patch);

    // MERGE (FLAG C): zoom updated, the prior viewport SURVIVED — the patch
    // did not whole-replace the component.
    const comp = game.getComponent(cam_ent, engine.Camera).?;
    try testing.expectEqual(@as(f32, 2.0), comp.zoom);
    try testing.expect(comp.viewport != null);
    try testing.expectEqual(@as(i32, 3), comp.viewport.?.width);
    try testing.expectEqual(@as(i32, 4), comp.viewport.?.height);

    // Re-seed on success → the live camera reflects the patched zoom.
    try testing.expectEqual(@as(f32, 2.0), game.getCamera().zoom);

    // Allowlist (FLAG B): a non-"Camera" name is refused with -1 (no blanket
    // apply-any-component path), entity untouched.
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_component(@intCast(cam_ent), "Sprite", 6, "{}", 2));
    try testing.expectEqual(@as(f32, 2.0), game.getComponent(cam_ent, engine.Camera).?.zoom);

    // Unknown/dead id → -1 (distinct from a parse failure).
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_component(999_999, "Camera", 6, "{\"zoom\":9}", 10));

    // Parse failure → -2, entity untouched (parse precedes any mutation).
    try testing.expectEqual(@as(i32, -2), editor_api.editor_set_component(@intCast(cam_ent), "Camera", 6, "{\"zoom\":", 8));
    try testing.expectEqual(@as(f32, 2.0), game.getComponent(cam_ent, engine.Camera).?.zoom);

    // A subsequent viewport-only patch also merges: zoom (2.0) survives.
    const vp_patch = try testing.allocator.dupe(u8, "{\"viewport\":{\"width\":99}}");
    try testing.expectEqual(@as(i32, 0), editor_api.editor_set_component(@intCast(cam_ent), "Camera", 6, vp_patch.ptr, vp_patch.len));
    testing.allocator.free(vp_patch);
    const comp2 = game.getComponent(cam_ent, engine.Camera).?;
    try testing.expectEqual(@as(f32, 2.0), comp2.zoom); // untouched by a viewport patch
    try testing.expectEqual(@as(i32, 99), comp2.viewport.?.width);
    try testing.expectEqual(@as(i32, 2), comp2.viewport.?.y); // prior sub-field survives

    // Out-of-range viewport int → -2 (bounds-checked i32 narrowing, NOT a
    // raw @intCast panic — gemini HIGH on #719); entity untouched.
    // 3_000_000_000 parses as i64 but exceeds i32 max.
    const oor = try testing.allocator.dupe(u8, "{\"viewport\":{\"width\":3000000000}}");
    try testing.expectEqual(@as(i32, -2), editor_api.editor_set_component(@intCast(cam_ent), "Camera", 6, oor.ptr, oor.len));
    testing.allocator.free(oor);
    try testing.expectEqual(@as(i32, 99), game.getComponent(cam_ent, engine.Camera).?.viewport.?.width); // unchanged by the rejected patch

    // An explicit `{"viewport":null}` CLEARS the viewport back to fullscreen —
    // distinct from an ABSENT key, which leaves it alone (finding #4).
    const null_patch = try testing.allocator.dupe(u8, "{\"viewport\":null}");
    try testing.expectEqual(@as(i32, 0), editor_api.editor_set_component(@intCast(cam_ent), "Camera", 6, null_patch.ptr, null_patch.len));
    testing.allocator.free(null_patch);
    const comp3 = game.getComponent(cam_ent, engine.Camera).?;
    try testing.expect(comp3.viewport == null);
    try testing.expectEqual(@as(f32, 2.0), comp3.zoom); // an absent zoom key leaves zoom alone

    // A present-but-wrong-TYPE `zoom` (`"2"` string) → -2, not a silent skip
    // that would author a default zoom (codex on #719); entity untouched.
    try testing.expectEqual(@as(i32, -2), editor_api.editor_set_component(@intCast(cam_ent), "Camera", 6, "{\"zoom\":\"2\"}", 12));
    try testing.expectEqual(@as(f32, 2.0), game.getComponent(cam_ent, engine.Camera).?.zoom);

    // Trailing junk after a valid object (`{...}garbage`) → -2 (parse must
    // reach EOF), not a partial-parse success (codex on #719).
    try testing.expectEqual(@as(i32, -2), editor_api.editor_set_component(@intCast(cam_ent), "Camera", 6, "{\"zoom\":5}garbage", 17));
    try testing.expectEqual(@as(f32, 2.0), game.getComponent(cam_ent, engine.Camera).?.zoom);
}

test "camera built-in DEFERS to a project's own registered Camera (finding #1)" {
    editor_api.unbind();
    defer editor_api.unbind();

    // The comptime gate flips off exactly when a project registers "Camera".
    try testing.expect(CameraTestGame.camera_is_builtin);
    try testing.expect(!RegisteredCameraGame.camera_is_builtin);

    var game = RegisteredCameraGame.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);

    // `editor_set_component("Camera", …)` REFUSES with -1 on such a project —
    // the built-in bridge is off, so it won't materialize a conflicting second
    // component (rather than silently corrupting the authoring model).
    try testing.expectEqual(@as(i32, -1), editor_api.editor_set_component(@intCast(e), "Camera", 6, "{\"zoom\":2}", 10));
    // The built-in Camera component was never attached.
    try testing.expect(game.getComponent(e, engine.Camera) == null);
}

test "camera apply-while-paused: a STEPPED frame keeps the ticked camera (single-step debug, finding #2)" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();
    const cam_ent = game.createEntity();
    game.setPosition(cam_ent, .{ .x = 400, .y = 300 });
    game.addComponent(cam_ent, engine.Camera{ .zoom = 1.5 });

    var runner = DummyRunner{};
    editor_api.bind(&game, &runner);
    editor_api.editor_pause(1);
    editor_api.editor_step(1);

    // The generated loop is `if (shouldTick()) g.tick(dt); frame();`. This frame
    // TICKS (consumes the step): shouldTick returns true, a camera script moves
    // the camera during the "tick", and frame() must NOT re-seed — single-step
    // debugging must render the just-ticked camera, not the authored seed.
    try testing.expect(editor_api.shouldTick());
    game.getCamera().setPosition(999, 888); // "script" moved it during the tick
    game.getCamera().setZoom(0.9);
    editor_api.frame(&game);
    try testing.expectEqual(@as(f32, 999), game.getCamera().x);
    try testing.expectEqual(@as(f32, 0.9), game.getCamera().zoom);

    // The next PAUSED frame does NOT tick (no pending step): shouldTick returns
    // false and frame() re-seeds from the authored component again.
    try testing.expect(!editor_api.shouldTick());
    editor_api.frame(&game);
    try testing.expectEqual(@as(f32, 400), game.getCamera().x);
    try testing.expectEqual(@as(f32, 1.5), game.getCamera().zoom);
}

test "camera seed-on-load: seeds AFTER onLoad, reflecting a camera the hook finalizes (finding #3)" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();

    const loader = struct {
        fn load(g: *CameraTestGame) anyerror!void {
            const e = g.createEntity();
            g.setPosition(e, .{ .x = 100, .y = 100 });
            g.addComponent(e, engine.Camera{ .zoom = 1.0 });
            g.trackSceneEntity(e);
        }
    }.load;
    const hooks = struct {
        fn onLoad(g: *CameraTestGame) void {
            // The scene finalizes the camera in its onLoad hook.
            var v = g.ecs_backend.view(.{ core.Position, engine.Camera }, .{});
            defer v.deinit();
            while (v.next()) |e| {
                g.setPosition(e, .{ .x = 700, .y = 500 });
                g.getComponent(e, engine.Camera).?.zoom = 3.0;
            }
        }
    };
    game.registerScene("cam_hook", loader, .{ .onLoad = hooks.onLoad });
    try game.setScene("cam_hook");

    // The seed ran AFTER onLoad → the live camera reflects the hook's values,
    // not the loader's initial (100,100)/1.0.
    try testing.expectEqual(@as(f32, 700), game.getCamera().x);
    try testing.expectEqual(@as(f32, 500), game.getCamera().y);
    try testing.expectEqual(@as(f32, 3.0), game.getCamera().zoom);
}

test "save/load: the built-in Camera round-trips zoom + viewport (finding #5)" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = CameraTestGame.init(testing.allocator);
    defer game.deinit();

    const cam_ent = game.createEntity();
    game.setPosition(cam_ent, .{ .x = 640, .y = 360 });
    game.addComponent(cam_ent, engine.Camera{
        .zoom = 2.5,
        .viewport = .{ .x = 5, .y = 6, .width = 320, .height = 240 },
    });

    const save_path = "test_save_camera_714.json";
    try game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    // Wipe the ECS and reload from disk.
    game.resetEcsBackend();
    try game.loadGameState(save_path);

    // The built-in Camera save/load channel restored zoom + viewport (Position
    // persists via its own channel).
    var restored: ?*engine.Camera = null;
    var v = game.active_world.ecs_backend.view(.{ core.Position, engine.Camera }, .{});
    defer v.deinit();
    while (v.next()) |e| restored = game.active_world.ecs_backend.getComponent(e, engine.Camera);
    try testing.expect(restored != null);
    try testing.expectEqual(@as(f32, 2.5), restored.?.zoom);
    try testing.expect(restored.?.viewport != null);
    try testing.expectEqual(@as(i32, 320), restored.?.viewport.?.width);
    try testing.expectEqual(@as(i32, 6), restored.?.viewport.?.y);
}
