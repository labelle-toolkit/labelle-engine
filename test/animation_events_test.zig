const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const AnimationDef = engine.AnimationDef;
const AnimationState = engine.AnimationState;
const SpriteAnimation = engine.SpriteAnimation;
const PendingBuf = engine.AnimPendingBuf;
const Kind = engine.AnimEventKind;

// A clip with a marker on slot 2 (0-based), .time @ speed 1 so beats map
// 1:1 to seconds and to slots (all runs 1 → beat_count == slot_count).
const marker_zon = .{
    .variants = .{"hero"},
    .clips = .{
        .punch = .{ .frames = .{ 1, 2, .{ .f = 3, .marker = "contact" }, 4 }, .mode = .time, .speed = 1.0 },
        .idle = .{ .frames = 1, .mode = .static },
    },
};
const Def = AnimationDef(marker_zon);
const punch: u8 = @intFromEnum(Def.clips.punch);

fn mkPunch() AnimationState {
    const meta = Def.clipMeta(.punch);
    return .{ .clip = punch, .frame_count = meta.frame_count, .speed = meta.speed, .mode = .time };
}

fn countKind(buf: *const PendingBuf, kind: Kind) usize {
    var c: usize = 0;
    for (buf.slice()) |e| {
        if (e.kind == kind) c += 1;
    }
    return c;
}

// ── Marker table (comptime) ───────────────────────────────

test "AnimationDef.markerAtBeat: marker sits on its slot's beat (#670)" {
    try testing.expectEqualStrings("", Def.markerAtBeat(.punch, 0));
    try testing.expectEqualStrings("", Def.markerAtBeat(.punch, 1));
    try testing.expectEqualStrings("contact", Def.markerAtBeat(.punch, 2));
    try testing.expectEqualStrings("", Def.markerAtBeat(.punch, 3));
    // Wraps past beat_count.
    try testing.expectEqualStrings("contact", Def.markerAtBeat(.punch, 6));
}

// ── AnimationState marker + loop-end dispatch ─────────────

test "advanceStateEvents: a dt spike that skips frames still fires the marker once (#670)" {
    var state = mkPunch();
    var buf = PendingBuf{};
    // dt 3.5 crosses beats 1,2,3 in one tick (no wrap: beat 4 not reached).
    Def.advanceStateEvents(&state, 3.5, &buf);

    try testing.expectEqual(@as(usize, 1), buf.len);
    const e = buf.slice()[0];
    try testing.expectEqual(Kind.marker, e.kind);
    try testing.expectEqual(@as(u8, 2), e.frame); // slot 2
    try testing.expectEqualStrings("contact", e.marker);
    try testing.expectEqual(@as(u16, 0), e.repetition);
    try testing.expectEqual(@as(u8, 3), state.frame); // landed on slot 3
}

test "advanceStateEvents: two skipped loops emit interleaved markers + loop-ends in order (#670)" {
    var state = mkPunch();
    var buf = PendingBuf{};
    // dt 8.5 → beats 1..8: marker@2, wrap@4, marker@6, wrap@8.
    Def.advanceStateEvents(&state, 8.5, &buf);

    const evs = buf.slice();
    try testing.expectEqual(@as(usize, 4), evs.len);
    // Oldest first, interleaved: marker(rep0), loop(rep1), marker(rep1), loop(rep2).
    try testing.expectEqual(Kind.marker, evs[0].kind);
    try testing.expectEqual(@as(u16, 0), evs[0].repetition);
    try testing.expectEqual(Kind.loop_end, evs[1].kind);
    try testing.expectEqual(@as(u16, 1), evs[1].repetition);
    try testing.expectEqual(Kind.marker, evs[2].kind);
    try testing.expectEqual(@as(u16, 1), evs[2].repetition);
    try testing.expectEqual(Kind.loop_end, evs[3].kind);
    try testing.expectEqual(@as(u16, 2), evs[3].repetition);
    // Authoritative loop count after two wraps.
    try testing.expectEqual(@as(u16, 2), state.repetition);
}

test "advanceStateEvents: repetition saturates instead of wrapping (#670)" {
    var state = mkPunch();
    state.repetition = std.math.maxInt(u16) - 1; // 0xFFFE
    var buf = PendingBuf{};
    // Two wraps would push 0xFFFE + 2 = 0x10000 → must saturate at 0xFFFF.
    Def.advanceStateEvents(&state, 8.5, &buf);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), state.repetition);
}

test "advanceStateEvents: transition resets tracking — no stale marker catch-up (#670)" {
    var state = mkPunch();
    var buf = PendingBuf{};
    Def.advanceStateEvents(&state, 3.5, &buf); // fires the contact marker
    try testing.expectEqual(@as(usize, 1), buf.len);

    // Re-enter the clip: transition clears event_pos/timer/repetition.
    buf.clear();
    state.transitionFromMeta(punch, Def.clipMeta(.punch));
    try testing.expectEqual(@as(f32, 0), state.event_pos);
    try testing.expectEqual(@as(u16, 0), state.repetition);

    // Advancing only to beat 1 must NOT replay beat 2's marker.
    Def.advanceStateEvents(&state, 1.5, &buf);
    try testing.expectEqual(@as(usize, 0), buf.len);
}

test "advanceStateEvents: a marker on slot 0 fires on the FIRST play-through (#670)" {
    // Marker on the clip's entry slot — displayed the moment the clip
    // starts. The linear traversal starts at beat 1, so without the
    // explicit entry-beat emit this marker would only fire on wraps.
    const zon = .{
        .variants = .{"h"},
        .clips = .{
            .kick = .{ .frames = .{ .{ .f = 1, .marker = "windup" }, 2, 3 }, .mode = .time, .speed = 1.0 },
        },
    };
    const D = AnimationDef(zon);
    const meta = D.clipMeta(.kick);
    var state = AnimationState{ .clip = 0, .frame_count = meta.frame_count, .speed = meta.speed, .mode = .time };
    var buf = PendingBuf{};

    // First advance (mid-beat): the entry marker fires once, rep 0.
    D.advanceStateEvents(&state, 0.5, &buf);
    try testing.expectEqual(@as(usize, 1), buf.len);
    try testing.expectEqualStrings("windup", buf.slice()[0].marker);
    try testing.expectEqual(@as(u16, 0), buf.slice()[0].repetition);

    // Second advance, still inside the first cycle: no re-fire.
    buf.clear();
    D.advanceStateEvents(&state, 1.0, &buf); // timer 1.5, beat 1
    try testing.expectEqual(@as(usize, 0), buf.len);

    // Crossing the wrap fires loop_end + the entry marker again (rep 1).
    buf.clear();
    D.advanceStateEvents(&state, 2.0, &buf); // timer 3.5 → beats 2,3(wrap→0)
    try testing.expectEqual(@as(usize, 2), buf.len);
    try testing.expectEqual(@as(@TypeOf(buf.slice()[0].kind), .loop_end), buf.slice()[0].kind);
    try testing.expectEqualStrings("windup", buf.slice()[1].marker);
    try testing.expectEqual(@as(u16, 1), buf.slice()[1].repetition);
}

test "advanceStateEvents: transition re-arms the entry marker (#670)" {
    const zon = .{
        .variants = .{"h"},
        .clips = .{ .kick = .{ .frames = .{ .{ .f = 1, .marker = "windup" }, 2 }, .mode = .time, .speed = 1.0 } },
    };
    const D = AnimationDef(zon);
    const meta = D.clipMeta(.kick);
    var state = AnimationState{ .clip = 0, .frame_count = meta.frame_count, .speed = meta.speed, .mode = .time };
    var buf = PendingBuf{};
    D.advanceStateEvents(&state, 0.5, &buf);
    try testing.expectEqual(@as(usize, 1), buf.len); // fired

    state.transitionFromMeta(0, meta); // re-enter the clip
    buf.clear();
    D.advanceStateEvents(&state, 0.5, &buf);
    try testing.expectEqual(@as(usize, 1), buf.len); // fires again after re-entry
    try testing.expectEqual(@as(u16, 0), buf.slice()[0].repetition);
}

test "advanceStateEvents: a static clip emits nothing and holds frame 0 (#670)" {
    const meta = Def.clipMeta(.idle);
    var state = AnimationState{ .clip = @intFromEnum(Def.clips.idle), .frame_count = meta.frame_count, .mode = .static };
    var buf = PendingBuf{};
    Def.advanceStateEvents(&state, 5.0, &buf);
    try testing.expectEqual(@as(usize, 0), buf.len);
    try testing.expectEqual(@as(u8, 0), state.frame);
}

// ── SpriteAnimation lifecycle events (props) ──────────────

test "SpriteAnimation.advanceEvents: .once fires AnimClipEnd exactly once (#670)" {
    var sa = SpriteAnimation{ .frames = &.{ "a", "b", "c" }, .fps = 10, .mode = .once };
    var buf = PendingBuf{};
    _ = sa.advanceEvents(1.0, &buf); // 10 steps → clamps to last frame
    try testing.expectEqual(@as(usize, 1), countKind(&buf, .clip_end));
    try testing.expectEqual(@as(u8, 2), sa.frame);

    buf.clear();
    _ = sa.advanceEvents(1.0, &buf); // already finished → silent
    try testing.expectEqual(@as(usize, 0), countKind(&buf, .clip_end));
}

test "SpriteAnimation.advanceEvents: .loop fires AnimLoopEnd once per wrap (#670)" {
    var sa = SpriteAnimation{ .frames = &.{ "a", "b", "c", "d" }, .fps = 10, .mode = .loop };
    var buf = PendingBuf{};
    _ = sa.advanceEvents(0.85, &buf); // 8 steps over 4 frames → 2 wraps
    try testing.expectEqual(@as(usize, 2), countKind(&buf, .loop_end));
    const evs = buf.slice();
    try testing.expectEqual(@as(u16, 1), evs[0].repetition);
    try testing.expectEqual(@as(u16, 2), evs[1].repetition);
}

test "SpriteAnimation.advanceEvents: .ping_pong fires on each endpoint reversal (#670)" {
    var sa = SpriteAnimation{ .frames = &.{ "a", "b", "c" }, .fps = 10, .mode = .ping_pong };
    var buf = PendingBuf{};
    // 5 steps from frame 0 forward: 0→1→2, peak-reverse, →1→0, trough-reverse.
    _ = sa.advanceEvents(0.55, &buf);
    try testing.expectEqual(@as(usize, 2), countKind(&buf, .loop_end));
}

test "SpriteAnimation.advance: the no-event overload still works unchanged (#670)" {
    var sa = SpriteAnimation{ .frames = &.{ "a", "b" }, .fps = 10, .mode = .loop };
    const changed = sa.advance(0.1); // 1 step
    try testing.expect(changed);
    try testing.expectEqual(@as(u8, 1), sa.frame);
}

// ── PendingBuf overflow safety ────────────────────────────

test "PendingBuf: append caps at capacity without UB (#670)" {
    var buf = PendingBuf{};
    var i: usize = 0;
    while (i < engine.anim_pending_cap + 10) : (i += 1) {
        _ = buf.append(.{ .kind = .marker });
    }
    try testing.expectEqual(@as(u8, @intCast(engine.anim_pending_cap)), buf.len);
    try testing.expect(buf.isFull());
}
