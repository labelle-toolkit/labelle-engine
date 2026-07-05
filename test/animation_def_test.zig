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
    try testing.expectEqual(@as(u8, 0), FramesAnim.slotForBeat(.plain, .hero, 0));
    try testing.expectEqual(@as(u8, 3), FramesAnim.slotForBeat(.plain, .hero, 3));
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
    try testing.expectEqual(@as(u8, 0), FramesAnim.slotForBeat(.hold, .hero, 0));
    try testing.expectEqual(@as(u8, 0), FramesAnim.slotForBeat(.hold, .hero, 1));
    try testing.expectEqual(@as(u8, 1), FramesAnim.slotForBeat(.hold, .hero, 2));
    // slotForBeat wraps past beat_count.
    try testing.expectEqual(@as(u8, 0), FramesAnim.slotForBeat(.hold, .hero, 3));
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

// ── Per-variant clip overrides (#666) ─────────────────────

const override_zon = .{
    .variants = .{
        "m_bald",
        "m_beard",
        .{ .name = "w_ginger", .overrides = .{
            .drink = .{ .frames = 8, .speed = 4.0 }, // fewer frames, slower
            .carry = .{ .folder = "take_ginger" }, // different sprite folder
        } },
    },
    .clips = .{
        .idle = .{ .frames = 1, .mode = .static },
        .drink = .{ .frames = 10, .mode = .time, .speed = 5.0 },
        .carry = .{ .frames = 4, .mode = .distance, .speed = 15.0, .folder = "take" },
    },
};
const OverrideAnim = AnimationDef(override_zon);

test "AnimationDef: mixed string/struct variants keep enum order and names (#666)" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(OverrideAnim.variants.m_bald));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(OverrideAnim.variants.m_beard));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(OverrideAnim.variants.w_ginger));
    try testing.expectEqualStrings("w_ginger", OverrideAnim.variantName(.w_ginger));
    // #665 name resolution still works for a struct-declared variant.
    const V = OverrideAnim.variants;
    try testing.expectEqual(@as(?V, V.w_ginger), OverrideAnim.variantFromName("w_ginger"));
}

test "AnimationDef: clipMetaFor patches overridden variants, base for others (#666)" {
    // Base row (what clipMeta and non-overriding variants see).
    const base = OverrideAnim.clipMeta(.drink);
    try testing.expectEqual(@as(u8, 10), base.frame_count);
    try testing.expectEqual(@as(f32, 5.0), base.speed);
    try testing.expectEqual(@as(u8, 10), OverrideAnim.clipMetaFor(.drink, .m_bald).frame_count);

    // w_ginger overrides drink: 8 frames @ speed 4.
    const ginger = OverrideAnim.clipMetaFor(.drink, .w_ginger);
    try testing.expectEqual(@as(u8, 8), ginger.frame_count);
    try testing.expectEqual(@as(f32, 4.0), ginger.speed);

    // A clip w_ginger does NOT override inherits the base.
    try testing.expectEqual(@as(u8, 1), OverrideAnim.clipMetaFor(.idle, .w_ginger).frame_count);
}

test "AnimationDef: spriteName honors overridden folder and frame count (#666)" {
    // carry base folder is "take"; w_ginger overrides it to "take_ginger".
    try testing.expectEqualStrings("take/m_bald_0001.png", OverrideAnim.spriteName(.carry, .m_bald, 0));
    try testing.expectEqualStrings("take_ginger/w_ginger_0001.png", OverrideAnim.spriteName(.carry, .w_ginger, 0));

    // drink base has 10 frames (m_bald frame 9 valid); w_ginger has 8.
    try testing.expectEqualStrings("drink/m_bald_0010.png", OverrideAnim.spriteName(.drink, .m_bald, 9));
    try testing.expectEqualStrings("drink/w_ginger_0008.png", OverrideAnim.spriteName(.drink, .w_ginger, 7));
    // Beyond the override's frame count → empty (even though < base max).
    try testing.expectEqualStrings("", OverrideAnim.spriteName(.drink, .w_ginger, 8));
}

// ── Per-variant frame-ENTRY overrides (#684) ──────────────

const entry_override_zon = .{
    .variants = .{
        "base_gal",
        // Entry-list override on a count-form base clip: hold + reorder
        // + a marker the base doesn't have.
        .{ .name = "heavy", .overrides = .{
            .swing = .{ .frames = .{ .{ .f = 1, .run = 2 }, .{ .f = 3, .marker = "impact" }, 2 } },
        } },
        // Count-form override on an entry-list base clip (the "vice
        // versa" direction): flattens holds/markers/reuse away.
        .{ .name = "swift", .overrides = .{
            .combo = .{ .frames = 2, .speed = 9.0 },
        } },
    },
    .clips = .{
        // Count-form base; `heavy` replaces it with an entry list.
        .swing = .{ .frames = 4, .mode = .time, .speed = 1.0 },
        // Entry-list base (hold + marker + file reuse); `swift` replaces
        // it with a bare count.
        .combo = .{ .frames = .{ .{ .f = 1, .run = 3, .marker = "windup" }, 2, .{ .f = 1 } }, .mode = .time, .speed = 1.0 },
    },
};
const EntryOverrideAnim = AnimationDef(entry_override_zon);

test "AnimationDef: entry-list override on a count-form base (#684)" {
    // Base variant keeps the count-form identity row.
    const base = EntryOverrideAnim.clipMetaFor(.swing, .base_gal);
    try testing.expectEqual(@as(u8, 4), base.entry_count);
    try testing.expectEqual(@as(u16, 4), base.beat_count);
    try testing.expectEqual(@as(u8, 2), EntryOverrideAnim.slotForBeat(.swing, .base_gal, 2));
    try testing.expectEqualStrings("", EntryOverrideAnim.markerAtBeat(.swing, .base_gal, 2));
    try testing.expectEqualStrings("swing/base_gal_0003.png", EntryOverrideAnim.spriteName(.swing, .base_gal, 2));

    // heavy's row: 3 slots over 4 beats (per-variant RUNS), marker on slot 1.
    const heavy = EntryOverrideAnim.clipMetaFor(.swing, .heavy);
    try testing.expectEqual(@as(u8, 3), heavy.entry_count);
    try testing.expectEqual(@as(u8, 3), heavy.frame_count);
    try testing.expectEqual(@as(u16, 4), heavy.beat_count);
    // beat_to_slot row: { 0, 0, 1, 2 } — slot 0 held two beats.
    try testing.expectEqual(@as(u8, 0), EntryOverrideAnim.slotForBeat(.swing, .heavy, 0));
    try testing.expectEqual(@as(u8, 0), EntryOverrideAnim.slotForBeat(.swing, .heavy, 1));
    try testing.expectEqual(@as(u8, 1), EntryOverrideAnim.slotForBeat(.swing, .heavy, 2));
    try testing.expectEqual(@as(u8, 2), EntryOverrideAnim.slotForBeat(.swing, .heavy, 3));
    // The marker sits on slot 1's first beat (beat 2) — heavy only.
    try testing.expectEqualStrings("impact", EntryOverrideAnim.markerAtBeat(.swing, .heavy, 2));
    try testing.expectEqualStrings("", EntryOverrideAnim.markerAtBeat(.swing, .heavy, 0));
    // Names use the override's file indices (reorder: slot 2 → file 2).
    try testing.expectEqualStrings("swing/heavy_0001.png", EntryOverrideAnim.spriteName(.swing, .heavy, 0));
    try testing.expectEqualStrings("swing/heavy_0003.png", EntryOverrideAnim.spriteName(.swing, .heavy, 1));
    try testing.expectEqualStrings("swing/heavy_0002.png", EntryOverrideAnim.spriteName(.swing, .heavy, 2));
    // Past the override's slot count → empty (base still has a slot 3).
    try testing.expectEqualStrings("", EntryOverrideAnim.spriteName(.swing, .heavy, 3));
}

test "AnimationDef: count-form override on an entry-list base (#684)" {
    // Base variant keeps hold + marker + file reuse.
    const base = EntryOverrideAnim.clipMetaFor(.combo, .base_gal);
    try testing.expectEqual(@as(u8, 3), base.entry_count);
    try testing.expectEqual(@as(u16, 5), base.beat_count);
    try testing.expectEqualStrings("windup", EntryOverrideAnim.markerAtBeat(.combo, .base_gal, 0));
    try testing.expectEqual(@as(u8, 0), EntryOverrideAnim.slotForBeat(.combo, .base_gal, 2)); // still held
    try testing.expectEqualStrings("combo/base_gal_0001.png", EntryOverrideAnim.spriteName(.combo, .base_gal, 2)); // reused file 1

    // swift's count row: 2 unit-run slots, no marker, own speed.
    const swift = EntryOverrideAnim.clipMetaFor(.combo, .swift);
    try testing.expectEqual(@as(u8, 2), swift.entry_count);
    try testing.expectEqual(@as(u16, 2), swift.beat_count);
    try testing.expectEqual(@as(f32, 9.0), swift.speed);
    try testing.expectEqual(@as(u8, 1), EntryOverrideAnim.slotForBeat(.combo, .swift, 1));
    try testing.expectEqualStrings("", EntryOverrideAnim.markerAtBeat(.combo, .swift, 0));
    try testing.expectEqualStrings("combo/swift_0001.png", EntryOverrideAnim.spriteName(.combo, .swift, 0));
    try testing.expectEqualStrings("combo/swift_0002.png", EntryOverrideAnim.spriteName(.combo, .swift, 1));
    try testing.expectEqualStrings("", EntryOverrideAnim.spriteName(.combo, .swift, 2));
}

test "AnimationDef: advanceState follows the state's variant row (#684)" {
    // heavy still holds slot 0 at beat 1 where base_gal has moved on.
    var heavy_state = AnimationState{ .variant = @intFromEnum(EntryOverrideAnim.variants.heavy) };
    heavy_state.transitionFromMeta(
        @intFromEnum(EntryOverrideAnim.clips.swing),
        EntryOverrideAnim.clipMetaFor(.swing, .heavy),
    );
    var base_state = AnimationState{ .variant = @intFromEnum(EntryOverrideAnim.variants.base_gal) };
    base_state.transitionFromMeta(
        @intFromEnum(EntryOverrideAnim.clips.swing),
        EntryOverrideAnim.clipMetaFor(.swing, .base_gal),
    );

    EntryOverrideAnim.advanceState(&heavy_state, 1.5); // beat 1
    EntryOverrideAnim.advanceState(&base_state, 1.5); // beat 1
    try testing.expectEqual(@as(u8, 0), heavy_state.frame); // held
    try testing.expectEqual(@as(u8, 1), base_state.frame); // identity

    EntryOverrideAnim.advanceState(&heavy_state, 2.0); // timer 3.5 → beat 3
    try testing.expectEqual(@as(u8, 2), heavy_state.frame);
}

test "AnimationDef: advanceStateEvents fires the variant's own markers (#684)" {
    // `impact` exists only in heavy's override — base_gal's count-form
    // row stays silent over the same beats.
    var buf = engine.AnimPendingBuf{};
    var heavy_state = AnimationState{ .variant = @intFromEnum(EntryOverrideAnim.variants.heavy) };
    heavy_state.transitionFromMeta(
        @intFromEnum(EntryOverrideAnim.clips.swing),
        EntryOverrideAnim.clipMetaFor(.swing, .heavy),
    );
    EntryOverrideAnim.advanceStateEvents(&heavy_state, 3.5, &buf); // crosses beat 2
    try testing.expectEqual(@as(usize, 1), buf.len);
    try testing.expectEqualStrings("impact", buf.slice()[0].marker);
    try testing.expectEqual(@as(u8, 1), buf.slice()[0].frame); // heavy's slot 1

    buf.clear();
    var base_state = AnimationState{ .variant = @intFromEnum(EntryOverrideAnim.variants.base_gal) };
    base_state.transitionFromMeta(
        @intFromEnum(EntryOverrideAnim.clips.swing),
        EntryOverrideAnim.clipMetaFor(.swing, .base_gal),
    );
    EntryOverrideAnim.advanceStateEvents(&base_state, 3.5, &buf);
    try testing.expectEqual(@as(usize, 0), buf.len);
}

test "AnimationDef: no-override defs keep base-identical per-variant rows (#684)" {
    // Every per-variant row of a def WITHOUT overrides must equal the
    // base row — meta, beat→slot, markers, and names all agree across
    // variants (the #684 byte-identity guarantee, checked per lookup).
    inline for (@typeInfo(TestAnim.clips).@"enum".fields) |cf| {
        const clip: TestAnim.clips = @enumFromInt(cf.value);
        const base = TestAnim.clipMeta(clip);
        inline for (@typeInfo(TestAnim.variants).@"enum".fields) |vf| {
            const variant: TestAnim.variants = @enumFromInt(vf.value);
            const m = TestAnim.clipMetaFor(clip, variant);
            try testing.expectEqual(base.frame_count, m.frame_count);
            try testing.expectEqual(base.entry_count, m.entry_count);
            try testing.expectEqual(base.beat_count, m.beat_count);
            try testing.expectEqual(base.speed, m.speed);
            try testing.expectEqual(base.mode, m.mode);
            try testing.expectEqualStrings(base.folder, m.folder);
            var b: u16 = 0;
            while (b < base.beat_count) : (b += 1) {
                try testing.expectEqual(
                    TestAnim.slotForBeat(clip, @enumFromInt(0), b),
                    TestAnim.slotForBeat(clip, variant, b),
                );
                try testing.expectEqualStrings(
                    TestAnim.markerAtBeat(clip, @enumFromInt(0), b),
                    TestAnim.markerAtBeat(clip, variant, b),
                );
            }
        }
    }
}

// Comptime-error cases (verified by construction; the repo has no
// compile-failure harness, so these stay documented rather than run):
//   - override key naming a nonexistent clip → "overrides unknown clip '…'"
//   - override field other than frames/speed/mode/folder → "unknown field '…'"
//   - a variant whose effective (mode, frames) pair is .static with a
//     .run > 1 → "holds are meaningless when frame is always slot 0"
