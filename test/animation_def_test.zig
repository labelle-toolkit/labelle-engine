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
