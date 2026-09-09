const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const AnimationDef = engine.AnimationDef;
const AnimationState = engine.AnimationState;

const trans_zon = .{
    .variants = .{"hero"},
    .clips = .{
        .idle = .{ .frames = 1, .mode = .static },
        .walk = .{ .frames = 4, .mode = .time, .speed = 1.0 },
        .carry = .{ .frames = 8, .mode = .time, .speed = 1.0 },
        .enter_combat = .{ .frames = 4, .mode = .time, .speed = 1.0 },
        .idle_combat = .{ .frames = 2, .mode = .time, .speed = 1.0 },
        .exit_combat = .{ .frames = 3, .mode = .time, .speed = 1.0 },
    },
    .transitions = .{
        // wildcard: ANY → idle_combat plays enter_combat first
        .{ .to = "idle_combat", .via = "enter_combat" },
        // from-specific override for the same `to` (precedence test)
        .{ .from = "walk", .to = "idle_combat", .via = "exit_combat" },
        // from-specific: idle_combat → idle plays exit_combat
        .{ .from = "idle_combat", .to = "idle", .via = "exit_combat" },
    },
};
const Def = AnimationDef(trans_zon);

const idle: u8 = @intFromEnum(Def.clips.idle);
const walk: u8 = @intFromEnum(Def.clips.walk);
const carry: u8 = @intFromEnum(Def.clips.carry);
const enter_combat: u8 = @intFromEnum(Def.clips.enter_combat);
const idle_combat: u8 = @intFromEnum(Def.clips.idle_combat);
const exit_combat: u8 = @intFromEnum(Def.clips.exit_combat);

// ── SwitchMode.sync ───────────────────────────────────────

test "requestTransition sync: carries normalized phase, scaled by frame_count (#671)" {
    var st = AnimationState{};
    st.transitionFromMeta(walk, Def.clipMeta(.walk)); // fc = 4
    st.timer = 2.0;
    st.requestTransition(carry, Def.clipMeta(.carry), .sync); // fc = 8
    try testing.expectEqual(carry, st.clip);
    try testing.expectEqual(@as(u8, 8), st.frame_count);
    try testing.expectApproxEqAbs(@as(f32, 4.0), st.timer, 1e-6); // 2.0 * 8/4
    try testing.expect(st.dirty);
}

test "requestTransition sync to the same clip leaves the timer untouched (#671)" {
    var st = AnimationState{};
    st.transitionFromMeta(walk, Def.clipMeta(.walk));
    st.timer = 2.5;
    st.requestTransition(walk, Def.clipMeta(.walk), .sync); // skin swap
    try testing.expectApproxEqAbs(@as(f32, 2.5), st.timer, 1e-6);
    try testing.expect(st.dirty);
}

// ── SwitchMode.at_end ─────────────────────────────────────

test "requestTransition at_end: defers to the cycle boundary, then applies (#671)" {
    var st = AnimationState{};
    st.transitionFromMeta(walk, Def.clipMeta(.walk)); // fc = 4, .time
    st.timer = 1.5; // mid-cycle
    st.requestTransition(idle, Def.clipMeta(.idle), .at_end);

    // Nothing changes yet; the switch is queued for timer == 4.0.
    try testing.expectEqual(walk, st.clip);
    try testing.expect(st.pending_set);
    try testing.expectApproxEqAbs(@as(f32, 4.0), st.pending_at, 1e-6);

    st.timer = 3.9;
    try testing.expect(!st.applyPending()); // before boundary → no-op
    try testing.expectEqual(walk, st.clip);

    st.timer = 4.0;
    try testing.expect(st.applyPending()); // boundary reached → apply
    try testing.expectEqual(idle, st.clip);
    try testing.expectEqual(@as(f32, 0), st.timer);
    try testing.expectEqual(@as(u8, 0), st.frame);
    try testing.expect(!st.pending_set);
}

test "requestTransition at_end: a second request overwrites the queue (last-wins) (#671)" {
    var st = AnimationState{};
    st.transitionFromMeta(walk, Def.clipMeta(.walk));
    st.timer = 1.0;
    st.requestTransition(idle, Def.clipMeta(.idle), .at_end);
    st.requestTransition(carry, Def.clipMeta(.carry), .at_end); // overwrites
    try testing.expectEqual(carry, st.pending_clip);

    st.timer = 4.0;
    try testing.expect(st.applyPending());
    try testing.expectEqual(carry, st.clip); // the second request won
}

test "requestTransition at_end on a .static clip applies immediately (#671)" {
    var st = AnimationState{};
    st.transitionFromMeta(idle, Def.clipMeta(.idle)); // .static — no cycle
    st.requestTransition(walk, Def.clipMeta(.walk), .at_end);
    try testing.expectEqual(walk, st.clip); // applied now
    try testing.expect(!st.pending_set);
}

test "requestTransition immediate resets and clears any pending switch (#671)" {
    var st = AnimationState{};
    st.transitionFromMeta(walk, Def.clipMeta(.walk));
    st.timer = 1.0;
    st.requestTransition(idle, Def.clipMeta(.idle), .at_end); // queue one
    try testing.expect(st.pending_set);
    st.requestTransition(carry, Def.clipMeta(.carry), .immediate); // hard cut
    try testing.expectEqual(carry, st.clip);
    try testing.expectEqual(@as(f32, 0), st.timer);
    try testing.expect(!st.pending_set); // queue cleared
}

// ── Transitional (via) clip resolution ────────────────────

test "transitionVia: from-specific rule wins over the wildcard (#671)" {
    // walk → idle_combat: the from=walk rule beats the wildcard.
    try testing.expectEqual(@as(?u8, exit_combat), Def.transitionVia(walk, idle_combat));
    // idle → idle_combat: no from-specific rule, so the wildcard applies.
    try testing.expectEqual(@as(?u8, enter_combat), Def.transitionVia(idle, idle_combat));
    // idle_combat → idle: the from-specific rule.
    try testing.expectEqual(@as(?u8, exit_combat), Def.transitionVia(idle_combat, idle));
    // No rule for this pair.
    try testing.expectEqual(@as(?u8, null), Def.transitionVia(walk, carry));
    try testing.expectEqual(@as(u8, 3), Def.transition_count_val);
}

const NoTrans = AnimationDef(.{
    .variants = .{"h"},
    .clips = .{ .a = .{ .frames = 1, .mode = .static } },
});

test "AnimationDef without a .transitions block has an empty table (#671)" {
    try testing.expectEqual(@as(u8, 0), NoTrans.transition_count_val);
    try testing.expectEqual(@as(?u8, null), NoTrans.transitionVia(0, 0));
}

// Comptime-error cases (verified by construction; the repo has no
// compile-failure harness, so these stay documented rather than run):
//   - `.{ .to = "x", .via = "x" }`            → "via must differ from to"
//   - `.{ .to = "nope", .via = "walk" }`      → "unknown clip: nope"
//   - two rules with identical (from, to)     → "duplicate transition rule"

// ── #686: game-wrapper drop-in (typed Clip enum, not u8) ──

// Mirrors flying-platform's components/animation_state.zig: a wrapper
// carrying typed enums plus the #670 event and #671 queue fields.
const WClip = enum(u8) { idle, walk, enter_combat, idle_combat };
const WrapperState = struct {
    clip: WClip = .idle,
    variant: u8 = 0,
    frame_count: u8 = 1,
    speed: f32 = 1.0,
    mode: engine.AnimMode = .static,
    frame: u8 = 0,
    timer: f32 = 0,
    event_pos: f32 = 0,
    repetition: u16 = 0,
    dirty: bool = true,
    pending_clip: WClip = .idle,
    pending_frame_count: u8 = 1,
    pending_speed: f32 = 1.0,
    pending_mode: engine.AnimMode = .static,
    pending_at: f32 = 0,
    pending_set: bool = false,
};

test "requestTransitionAny/applyPendingAny drive a typed-enum wrapper (#686)" {
    var st = WrapperState{};
    // enter combat: hard cut, then queue idle_combat for the cycle end.
    engine.transitionAny(&st, WClip.enter_combat, 4, 1.0, .time);
    engine.requestTransitionAny(&st, WClip.idle_combat, Def.clipMeta(.idle_combat), .at_end);
    try testing.expectEqual(WClip.enter_combat, st.clip);
    try testing.expect(st.pending_set);

    st.timer = 3.9;
    try testing.expect(!engine.applyPendingAny(&st));
    st.timer = 4.0;
    try testing.expect(engine.applyPendingAny(&st)); // boundary → cut
    try testing.expectEqual(WClip.idle_combat, st.clip);
    try testing.expectEqual(@as(u8, 2), st.frame_count); // idle_combat meta
    try testing.expect(!st.pending_set);
}

test "advanceState/advanceStateEvents accept a typed-enum clip (#686)" {
    // The marker def's punch clip is index 0 in its own enum — build a
    // wrapper whose clip enum ORDINALS match the def's clip ordinals.
    const MClip = enum(u8) { punch, idle };
    var st = struct {
        clip: MClip = .punch,
        variant: u8 = 0,
        frame_count: u8 = 4,
        speed: f32 = 1.0,
        mode: engine.AnimMode = .time,
        frame: u8 = 0,
        timer: f32 = 0,
        event_pos: f32 = 0,
        repetition: u16 = 0,
        dirty: bool = true,
    }{};
    const MDef = AnimationDef(.{
        .variants = .{"h"},
        .clips = .{
            .punch = .{ .frames = .{ 1, 2, .{ .f = 3, .marker = "contact" }, 4 }, .mode = .time, .speed = 1.0 },
            .idle = .{ .frames = 1, .mode = .static },
        },
    });
    var buf = engine.AnimPendingBuf{};
    MDef.advanceStateEvents(&st, 3.5, &buf); // crosses the marked beat
    try testing.expectEqual(@as(u8, 3), st.frame);
    try testing.expectEqual(@as(usize, 1), buf.len);
    try testing.expectEqualStrings("contact", buf.slice()[0].marker);

    // advanceState too (no events).
    st.timer = 0;
    st.frame = 0;
    MDef.advanceState(&st, 1.5);
    try testing.expectEqual(@as(u8, 1), st.frame);
}
