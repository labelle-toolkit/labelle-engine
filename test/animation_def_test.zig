const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const AnimationDef = engine.AnimationDef;
const AnimationState = engine.AnimationState;

// Test .zon data (inline struct matching the expected format)
const test_zon = .{
    .variants = .{ "m_bald", "m_beard", "w_india" },
    .clips = .{
        .idle = .{ .frames = 1, .mode = .static },
        .walk = .{ .frames = 4, .mode = .distance, .speed = 15.0 },
        .carry = .{ .frames = 4, .mode = .distance, .speed = 15.0, .folder = "take" },
        .job1 = .{ .frames = 8, .mode = .time, .speed = 4.0 },
    },
};

const TestAnim = AnimationDef(test_zon);

// ── AnimationDef ──────────────────────────────────────────

test "AnimationDef: generates Clip enum" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(TestAnim.clips.idle));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(TestAnim.clips.walk));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(TestAnim.clips.carry));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(TestAnim.clips.job1));
}

test "AnimationDef: generates Variant enum" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(TestAnim.variants.m_bald));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(TestAnim.variants.m_beard));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(TestAnim.variants.w_india));
}

test "AnimationDef: clipMeta returns correct metadata" {
    const walk_meta = TestAnim.clipMeta(.walk);
    try testing.expectEqual(@as(u8, 4), walk_meta.frame_count);
    try testing.expectEqual(@as(f32, 15.0), walk_meta.speed);
    try testing.expectEqual(engine.AnimMode.distance, walk_meta.mode);
    try testing.expectEqualStrings("walk", walk_meta.folder);

    const carry_meta = TestAnim.clipMeta(.carry);
    try testing.expectEqualStrings("take", carry_meta.folder);

    const idle_meta = TestAnim.clipMeta(.idle);
    try testing.expectEqual(@as(u8, 1), idle_meta.frame_count);
    try testing.expectEqual(engine.AnimMode.static, idle_meta.mode);
}

test "AnimationDef: spriteName produces correct names" {
    try testing.expectEqualStrings("idle/m_bald_0001.png", TestAnim.spriteName(.idle, .m_bald, 0));
    try testing.expectEqualStrings("walk/m_beard_0003.png", TestAnim.spriteName(.walk, .m_beard, 2));
    try testing.expectEqualStrings("take/w_india_0001.png", TestAnim.spriteName(.carry, .w_india, 0));
    try testing.expectEqualStrings("job1/m_bald_0008.png", TestAnim.spriteName(.job1, .m_bald, 7));
}

test "AnimationDef: folder override only affects carry" {
    try testing.expectEqualStrings("walk/m_bald_0001.png", TestAnim.spriteName(.walk, .m_bald, 0));
    try testing.expectEqualStrings("take/m_bald_0001.png", TestAnim.spriteName(.carry, .m_bald, 0));
}

test "AnimationDef: variantFromIndex with valid and out-of-range" {
    try testing.expectEqual(TestAnim.variants.m_bald, TestAnim.variantFromIndex(0));
    try testing.expectEqual(TestAnim.variants.w_india, TestAnim.variantFromIndex(2));
    // Out of range falls back to last variant
    try testing.expectEqual(TestAnim.variants.w_india, TestAnim.variantFromIndex(99));
}

test "AnimationDef: variantFromName hit, miss, round-trip (#665)" {
    const V = TestAnim.variants;
    // Hit — resolves each name to its variant regardless of position.
    try testing.expectEqual(@as(?V, V.m_bald), TestAnim.variantFromName("m_bald"));
    try testing.expectEqual(@as(?V, V.m_beard), TestAnim.variantFromName("m_beard"));
    try testing.expectEqual(@as(?V, V.w_india), TestAnim.variantFromName("w_india"));
    // Miss — a renamed/deleted variant resolves to null (caller falls back).
    try testing.expectEqual(@as(?V, null), TestAnim.variantFromName("does_not_exist"));
    try testing.expectEqual(@as(?V, null), TestAnim.variantFromName(""));
    // Round-trip: name → variant → name is the identity for every variant.
    inline for (.{ "m_bald", "m_beard", "w_india" }) |nm| {
        const v = TestAnim.variantFromName(nm).?;
        try testing.expectEqualStrings(nm, TestAnim.variantName(v));
    }
}

test "AnimationDef: clipName and variantName" {
    try testing.expectEqualStrings("walk", TestAnim.clipName(.walk));
    try testing.expectEqualStrings("m_beard", TestAnim.variantName(.m_beard));
}

// ── AnimationState ────────────────────────────────────────

test "AnimationState: advance in time mode" {
    var state = AnimationState{
        .clip = @intFromEnum(TestAnim.clips.job1),
        .frame_count = 8,
        .speed = 4.0,
        .mode = .time,
    };

    try testing.expectEqual(@as(u8, 0), state.frame);
    state.advance(0.5);
    // timer = 0.5 * 4.0 = 2.0, frame = mod(2.0, 8.0) = 2
    try testing.expectEqual(@as(u8, 2), state.frame);
}

test "AnimationState: advance in static mode stays at 0" {
    var state = AnimationState{
        .clip = 0,
        .frame_count = 1,
        .mode = .static,
    };
    state.advance(1.0);
    try testing.expectEqual(@as(u8, 0), state.frame);
}

test "AnimationState: transition resets state" {
    var state = AnimationState{
        .clip = 0,
        .frame = 5,
        .timer = 10.0,
        .dirty = false,
    };

    state.transition(1, 4, 15.0, .distance);
    try testing.expectEqual(@as(u8, 1), state.clip);
    try testing.expectEqual(@as(u8, 4), state.frame_count);
    try testing.expectEqual(@as(f32, 15.0), state.speed);
    try testing.expectEqual(engine.AnimMode.distance, state.mode);
    try testing.expectEqual(@as(u8, 0), state.frame);
    try testing.expectEqual(@as(f32, 0.0), state.timer);
    try testing.expect(state.dirty);
}

test "AnimationState: transitionFromMeta uses clip metadata" {
    var state = AnimationState{};
    const meta = TestAnim.clipMeta(.walk);
    state.transitionFromMeta(@intFromEnum(TestAnim.clips.walk), meta);

    try testing.expectEqual(@intFromEnum(TestAnim.clips.walk), state.clip);
    try testing.expectEqual(@as(u8, 4), state.frame_count);
    try testing.expectEqual(@as(f32, 15.0), state.speed);
    try testing.expectEqual(engine.AnimMode.distance, state.mode);
}

test "AnimationState: advance in distance mode uses timer directly" {
    var state = AnimationState{
        .frame_count = 4,
        .speed = 10.0,
        .mode = .distance,
    };

    // Game sets timer from distance traveled
    state.timer = 2.5;
    state.advance(0.0); // dt unused in distance mode
    // mod(2.5, 4.0) = 2.5, frame = min(2, 3) = 2
    try testing.expectEqual(@as(u8, 2), state.frame);
}

// ── Explicit frame entries (#664) ─────────────────────────

// Exercises all three `.frames` forms: bare count, explicit index list
// (reorder + reuse), and per-slot runs (holds).
const frames_zon = .{
    .variants = .{"hero"},
    .clips = .{
        // Count shorthand — every slot runs one beat, so beat_count ==
        // entry_count and playback is bit-identical to pre-#664.
        .plain = .{ .frames = 4, .mode = .time, .speed = 1.0 },
        // Explicit list — reorders and REUSES a file: slot 3 points back
        // at file 2 (a 1-2-3-2 ping-pong).
        .bounce = .{ .frames = .{ 1, 2, 3, 2 }, .mode = .time, .speed = 1.0 },
        // Per-slot holds — slot 0 (file 1) shows for 2 beats, then slot 1
        // (bare int → file 2, run 1) for 1 beat. beat_count 3, entry_count 2.
        .hold = .{ .frames = .{ .{ .f = 1, .run = 2 }, 2 }, .mode = .time, .speed = 1.0 },
    },
};

const FramesAnim = AnimationDef(frames_zon);

test "AnimationDef: count shorthand yields unit-run beats (#664)" {
    const m = FramesAnim.clipMeta(.plain);
    try testing.expectEqual(@as(u8, 4), m.entry_count);
    try testing.expectEqual(@as(u16, 4), m.beat_count);
    // frame_count stays a back-compat alias of entry_count.
    try testing.expectEqual(@as(u8, 4), m.frame_count);
    // Slot i resolves to file i+1, exactly as the old count path did.
    try testing.expectEqualStrings("plain/hero_0001.png", FramesAnim.spriteName(.plain, .hero, 0));
    try testing.expectEqualStrings("plain/hero_0004.png", FramesAnim.spriteName(.plain, .hero, 3));
    // Identity beat→slot mapping.
    try testing.expectEqual(@as(u8, 0), FramesAnim.slotForBeat(.plain, 0));
    try testing.expectEqual(@as(u8, 3), FramesAnim.slotForBeat(.plain, 3));
}

test "AnimationDef: explicit list reorders and reuses files (#664)" {
    const m = FramesAnim.clipMeta(.bounce);
    try testing.expectEqual(@as(u8, 4), m.entry_count);
    try testing.expectEqual(@as(u16, 4), m.beat_count);
    // .{ 1, 2, 3, 2 } — the name for each slot uses that slot's `f`, so
    // slot 3 renders file 2 again (not file 4).
    try testing.expectEqualStrings("bounce/hero_0001.png", FramesAnim.spriteName(.bounce, .hero, 0));
    try testing.expectEqualStrings("bounce/hero_0002.png", FramesAnim.spriteName(.bounce, .hero, 1));
    try testing.expectEqualStrings("bounce/hero_0003.png", FramesAnim.spriteName(.bounce, .hero, 2));
    try testing.expectEqualStrings("bounce/hero_0002.png", FramesAnim.spriteName(.bounce, .hero, 3));
}

test "AnimationDef: per-slot runs expand the beat table (#664)" {
    const m = FramesAnim.clipMeta(.hold);
    try testing.expectEqual(@as(u8, 2), m.entry_count);
    try testing.expectEqual(@as(u16, 3), m.beat_count);
    // beat_to_slot == { 0, 0, 1 }: slot 0 held two beats, then slot 1.
    try testing.expectEqual(@as(u8, 0), FramesAnim.slotForBeat(.hold, 0));
    try testing.expectEqual(@as(u8, 0), FramesAnim.slotForBeat(.hold, 1));
    try testing.expectEqual(@as(u8, 1), FramesAnim.slotForBeat(.hold, 2));
    // slotForBeat wraps past beat_count.
    try testing.expectEqual(@as(u8, 0), FramesAnim.slotForBeat(.hold, 3));
    // The bare int 2 became slot 1 pointing at file 2.
    try testing.expectEqualStrings("hold/hero_0001.png", FramesAnim.spriteName(.hold, .hero, 0));
    try testing.expectEqualStrings("hold/hero_0002.png", FramesAnim.spriteName(.hold, .hero, 1));
}

test "AnimationDef: advanceState maps beats to held slots (#664)" {
    var state = AnimationState{};
    state.transitionFromMeta(@intFromEnum(FramesAnim.clips.hold), FramesAnim.clipMeta(.hold));

    // beat_count 3, speed 1 → timer accumulates beats; the held slot 0
    // spans beats 0 and 1, slot 1 is beat 2, then it wraps.
    try testing.expectEqual(@as(u8, 0), state.frame);
    FramesAnim.advanceState(&state, 0.5); // timer 0.5 → beat 0 → slot 0
    try testing.expectEqual(@as(u8, 0), state.frame);
    FramesAnim.advanceState(&state, 0.7); // timer 1.2 → beat 1 → slot 0 (still held)
    try testing.expectEqual(@as(u8, 0), state.frame);
    FramesAnim.advanceState(&state, 1.0); // timer 2.2 → beat 2 → slot 1
    try testing.expectEqual(@as(u8, 1), state.frame);
    FramesAnim.advanceState(&state, 1.0); // timer 3.2 → mod 3 = 0.2 → beat 0 → slot 0 (wrap)
    try testing.expectEqual(@as(u8, 0), state.frame);
}
