const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

// ── Shared vocabulary (#667) ──────────────────────────────

test "anim_timing: the two axes carry the expected tags" {
    // AdvanceMode — the timer driver.
    try testing.expectEqual(@as(u2, 0), @intFromEnum(engine.AdvanceMode.time));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(engine.AdvanceMode.distance));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(engine.AdvanceMode.static));
    // BoundaryMode — boundary behavior.
    try testing.expectEqual(@as(u2, 0), @intFromEnum(engine.BoundaryMode.loop));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(engine.BoundaryMode.once));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(engine.BoundaryMode.ping_pong));
}

test "anim_timing: old names still resolve to the shared types (deprecated aliases)" {
    // The old enum names are now aliases — same TYPE, so old code compiles.
    try testing.expectEqual(engine.AdvanceMode, engine.AnimMode);
    try testing.expectEqual(engine.BoundaryMode, engine.SpriteAnimationMode);
    // ClipMeta.mode is the shared AdvanceMode.
    try testing.expectEqual(engine.AdvanceMode, @TypeOf(@as(engine.AnimClipMeta, undefined).mode));
}

// ── advanceAny dedup (#667) ───────────────────────────────

// A game-wrapper-shaped struct: the required advance fields PLUS extra
// typed enum fields the engine advance must not touch. This mirrors
// flying-platform's components/animation_state.zig, whose enum-vs-u8
// mismatch motivated the copied advance math advanceAny now replaces.
const Clip = enum { idle, walk };
const Variant = enum { hero, robot };
const GameState = struct {
    clip: Clip = .walk, // extra typed field — untouched by advanceAny
    variant: Variant = .robot, // extra typed field — untouched
    mode: engine.AdvanceMode = .time,
    speed: f32 = 4.0,
    timer: f32 = 0,
    frame: u8 = 0,
    frame_count: u8 = 8,
};

test "advanceAny: drives a duck-typed game struct, leaving enum fields alone (#667)" {
    var st = GameState{};
    engine.advanceAny(&st, 0.5); // timer = 0.5*4 = 2.0 → frame = mod(2,8) = 2
    try testing.expectEqual(@as(u8, 2), st.frame);
    // The wrapper's own typed fields are untouched.
    try testing.expectEqual(Clip.walk, st.clip);
    try testing.expectEqual(Variant.robot, st.variant);
}

test "advanceAny: matches AnimationState.advance exactly (one implementation) (#667)" {
    // Engine AnimationState now delegates to advanceAny; a hand-rolled
    // struct fed the same inputs must land on the same frame.
    var engine_state = engine.AnimationState{ .frame_count = 8, .speed = 4.0, .mode = .time };
    engine_state.advance(0.5);

    var duck = GameState{ .mode = .time, .speed = 4.0, .frame_count = 8 };
    engine.advanceAny(&duck, 0.5);

    try testing.expectEqual(engine_state.frame, duck.frame);
    try testing.expectEqual(engine_state.timer, duck.timer);
}

test "advanceAny: static holds frame 0, distance uses the external timer (#667)" {
    var stat = GameState{ .mode = .static, .frame = 5 };
    engine.advanceAny(&stat, 1.0);
    try testing.expectEqual(@as(u8, 0), stat.frame);

    var dist = GameState{ .mode = .distance, .frame_count = 4 };
    dist.timer = 2.5; // game sets timer from distance
    engine.advanceAny(&dist, 0.0);
    try testing.expectEqual(@as(u8, 2), dist.frame); // mod(2.5,4) = 2.5 → 2
}
