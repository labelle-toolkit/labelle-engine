const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const AnimationDef = engine.AnimationDef;
const AnimationState = engine.AnimationState;
const RuntimeAnimationDef = engine.RuntimeAnimationDef;
const AnimDefSource = engine.AnimDefSource;
const refreshState = engine.refreshState;
const ReloadWatcher = engine.ReloadWatcher;

// The same fixture consumed two ways: `@import` drives the comptime
// AnimationDef, `@embedFile` feeds the runtime parser. Any divergence in
// index assignment or sprite-name formatting fails the parity test below.
const WorkerAnim = AnimationDef(@import("fixtures/worker_anim.zon"));
const worker_src = @embedFile("fixtures/worker_anim.zon");

// ── Parity: runtime path == comptime path over the same source ──

test "RuntimeAnimationDef: byte-equal sprite names + index compatibility (#672)" {
    var rt = try RuntimeAnimationDef.load(testing.allocator, worker_src);
    defer rt.deinit();

    try testing.expectEqual(@as(usize, WorkerAnim.clip_count_val), rt.clip_names.len);
    try testing.expectEqual(@as(usize, WorkerAnim.variant_count_val), rt.variant_names.len);

    inline for (@typeInfo(WorkerAnim.clips).@"enum".fields) |cf| {
        const clip: WorkerAnim.clips = @enumFromInt(cf.value);
        const ci: u8 = cf.value;
        // Clip index must match the comptime ordinal — a live u8 means the
        // same clip on both paths.
        try testing.expectEqual(@as(?u8, ci), rt.clipIndex(cf.name));
        // Metadata parity — the #664 beat vocabulary included (#685).
        const cm = WorkerAnim.clipMeta(clip);
        const rm = rt.clipMeta(ci);
        try testing.expectEqual(cm.frame_count, rm.frame_count);
        try testing.expectEqual(cm.entry_count, rm.entry_count);
        try testing.expectEqual(cm.beat_count, rm.beat_count);
        try testing.expectEqual(cm.speed, rm.speed);
        try testing.expectEqual(cm.mode, rm.mode);
        try testing.expectEqualStrings(cm.folder, rm.folder);

        inline for (@typeInfo(WorkerAnim.variants).@"enum".fields) |vf| {
            const variant: WorkerAnim.variants = @enumFromInt(vf.value);
            const vi: u8 = vf.value;
            try testing.expectEqual(@as(?u8, vi), rt.variantIndex(vf.name));
            // Byte-equal sprite names across every valid slot of the clip.
            var f: u8 = 0;
            while (f < cm.frame_count) : (f += 1) {
                try testing.expectEqualStrings(
                    WorkerAnim.spriteName(clip, variant, f),
                    rt.spriteName(ci, vi, f),
                );
            }
            // Beat→slot parity across every beat (holds resolve alike).
            var b: u16 = 0;
            while (b < cm.beat_count) : (b += 1) {
                try testing.expectEqual(
                    WorkerAnim.slotForBeat(clip, variant, b),
                    rt.slotForBeat(ci, vi, b),
                );
            }
        }
    }
}

test "RuntimeAnimationDef: folder override + defaulting parity (#672)" {
    var rt = try RuntimeAnimationDef.load(testing.allocator, worker_src);
    defer rt.deinit();

    // carry declares folder "take"; ladder declares "latter_up".
    try testing.expectEqualStrings("take", rt.clipMeta(rt.clipIndex("carry").?).folder);
    try testing.expectEqualStrings("take/m_bald_0001.png", rt.spriteName(rt.clipIndex("carry").?, 0, 0));
    // idle declares no speed/folder → folder = clip name, speed = 1.0, static.
    const idle = rt.clipMeta(rt.clipIndex("idle").?);
    try testing.expectEqualStrings("idle", idle.folder);
    try testing.expectEqual(@as(f32, 1.0), idle.speed);
    try testing.expectEqual(engine.AnimMode.static, idle.mode);
}

test "RuntimeAnimationDef: entry-list frames parse holds/reuse/markers (#685)" {
    var rt = try RuntimeAnimationDef.load(testing.allocator, worker_src);
    defer rt.deinit();

    // The fixture's swing clip: .{ 1, 2, .{ .f = 3, .run = 2, .marker = "contact" }, 2 }.
    const ci = rt.clipIndex("swing").?;
    const m = rt.clipMeta(ci);
    try testing.expectEqual(@as(u8, 4), m.entry_count);
    try testing.expectEqual(@as(u16, 5), m.beat_count); // 1+1+2+1

    const entries = rt.clip_entries[ci];
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqual(@as(u16, 3), entries[2].f);
    try testing.expectEqual(@as(u8, 2), entries[2].run);
    try testing.expectEqualStrings("contact", entries[2].marker.?);
    try testing.expectEqual(@as(?[]const u8, null), entries[0].marker);
    try testing.expectEqual(@as(u16, 2), entries[3].f); // file reuse

    // Slot 3 renders file 2 again; the held slot spans beats 2 and 3.
    try testing.expectEqualStrings("swing/m_bald_0002.png", rt.spriteName(ci, 0, 3));
    try testing.expectEqual(@as(u8, 2), rt.slotForBeat(ci, 0, 2));
    try testing.expectEqual(@as(u8, 2), rt.slotForBeat(ci, 0, 3));
    try testing.expectEqual(@as(u8, 3), rt.slotForBeat(ci, 0, 4));
    try testing.expectEqual(@as(u8, 0), rt.slotForBeat(ci, 0, 5)); // wraps
}

test "RuntimeAnimationDef: minimal clip gets the comptime defaults (#672)" {
    const src =
        \\.{
        \\    .variants = .{ "only" },
        \\    .clips = .{ .solo = .{ .frames = 1 } },
        \\}
    ;
    var rt = try RuntimeAnimationDef.load(testing.allocator, src);
    defer rt.deinit();

    const m = rt.clipMeta(0);
    try testing.expectEqual(@as(u8, 1), m.frame_count);
    try testing.expectEqual(@as(f32, 1.0), m.speed);
    try testing.expectEqual(engine.AnimMode.static, m.mode);
    try testing.expectEqualStrings("solo", m.folder);
    try testing.expectEqualStrings("solo/only_0001.png", rt.spriteName(0, 0, 0));
}

// ── Reload refresh (live-entity meta refresh + clamping) ──

test "refreshState: re-copies meta and clamps a shrunk frame (#672)" {
    var state = AnimationState{
        .clip = 0,
        .variant = 0,
        .frame = 7,
        .frame_count = 8,
        .speed = 4.0,
        .mode = .time,
        .dirty = false,
    };
    // Reloaded def: clip 0 now has only 3 frames, distance @ 2.0.
    const src =
        \\.{
        \\    .variants = .{ "v" },
        \\    .clips = .{ .c = .{ .frames = 3, .mode = .distance, .speed = 2.0 } },
        \\}
    ;
    var def = try RuntimeAnimationDef.load(testing.allocator, src);
    defer def.deinit();

    refreshState(&state, &def);
    try testing.expectEqual(@as(u8, 3), state.frame_count); // re-copied
    try testing.expectEqual(@as(f32, 2.0), state.speed);
    try testing.expectEqual(engine.AnimMode.distance, state.mode);
    try testing.expectEqual(@as(u8, 2), state.frame); // 7 clamped to frame_count-1
    try testing.expect(state.dirty);
}

test "refreshState: clamps an out-of-range clip and variant index (#672)" {
    var state = AnimationState{ .clip = 9, .variant = 5, .frame = 0 };
    const src =
        \\.{
        \\    .variants = .{ "a", "b" },
        \\    .clips = .{ .only = .{ .frames = 2, .mode = .time, .speed = 1.0 } },
        \\}
    ;
    var def = try RuntimeAnimationDef.load(testing.allocator, src);
    defer def.deinit();

    refreshState(&state, &def);
    try testing.expectEqual(@as(u8, 0), state.clip); // 9 → last clip (0)
    try testing.expectEqual(@as(u8, 1), state.variant); // 5 → last variant (1)
}

// ── Parse-error resilience (never corrupt the running def) ──

test "RuntimeAnimationDef.load: malformed input errors cleanly (#672)" {
    const a = testing.allocator;
    // Truncated / unparseable ZON.
    try testing.expectError(error.ParseFailed, RuntimeAnimationDef.load(a, ".{ .variants = .{ "));
    // Missing top-level fields.
    try testing.expectError(error.MissingClips, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"} }"));
    try testing.expectError(error.MissingVariants, RuntimeAnimationDef.load(a, ".{ .clips = .{ .c = .{ .frames = 1 } } }"));
    // Frame count out of the 1..255 range.
    try testing.expectError(error.FramesOutOfRange, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = 0 } } }"));
    // Unknown mode enum.
    try testing.expectError(error.UnknownMode, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = 1, .mode = .bogus } } }"));
}

test "RuntimeAnimationDef.load: malformed entry lists error cleanly (#685)" {
    const a = testing.allocator;
    // Every message mirrors a comptime normalizeFrames @compileError.
    try testing.expectError(error.EmptyFrames, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = .{} } } }"));
    try testing.expectError(error.FrameIndexOutOfRange, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = .{ 0 } } } }"));
    try testing.expectError(error.FrameIndexOutOfRange, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = .{ .{ .f = 10000 } } } } }"));
    try testing.expectError(error.MissingFrameIndex, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = .{ .{ .run = 2 } } } } }"));
    try testing.expectError(error.RunOutOfRange, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = .{ .{ .f = 1, .run = 0 } } } } }"));
    try testing.expectError(error.BadFrameEntry, RuntimeAnimationDef.load(a, ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = .{ \"x\" } } } }"));
    // A marker mid-list must not leak when a later entry fails.
    try testing.expectError(error.RunOutOfRange, RuntimeAnimationDef.load(a,
        ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = .{ .{ .f = 1, .marker = \"hit\" }, .{ .f = 2, .run = 999 } } } } }"));
    // Comptime parity: holds on a .static clip are rejected.
    try testing.expectError(error.HoldOnStaticClip, RuntimeAnimationDef.load(a,
        ".{ .variants = .{\"a\"}, .clips = .{ .c = .{ .frames = .{ .{ .f = 1, .run = 2 } } } } }"));
}

// ── AnimDefSource dispatch ──

fn stubName(clip: u8, variant: u8, frame: u8) []const u8 {
    _ = clip;
    _ = variant;
    _ = frame;
    return "stub/x_0001.png";
}

test "AnimDefSource: both variants answer the same query (#672)" {
    var def = try RuntimeAnimationDef.load(testing.allocator, worker_src);
    defer def.deinit();

    const rt_src = AnimDefSource{ .runtime = &def };
    try testing.expectEqualStrings(def.spriteName(1, 0, 0), rt_src.spriteName(1, 0, 0));

    const ct_src = AnimDefSource{ .comptime_table = &stubName };
    try testing.expectEqualStrings("stub/x_0001.png", ct_src.spriteName(0, 0, 0));
}

// ── ReloadWatcher: mtime diff + one-generation deferred free ──

test "ReloadWatcher: mtimeChanged coalesces repeats (#672)" {
    var w = ReloadWatcher.init(try RuntimeAnimationDef.load(testing.allocator, worker_src), 100);
    defer w.deinit();

    try testing.expect(!w.mtimeChanged(100)); // unchanged since init — no startup reload
    try testing.expect(!w.mtimeChanged(100));
    try testing.expect(w.mtimeChanged(250)); // changed
    try testing.expect(!w.mtimeChanged(250));
    try testing.expect(w.mtimeChanged(300)); // changed again
}

test "ReloadWatcher: holds exactly one previous generation, frees on swap (#672)" {
    const a = testing.allocator;
    const src =
        \\.{ .variants = .{ "v" }, .clips = .{ .c = .{ .frames = 2, .mode = .time, .speed = 1.0 } } }
    ;
    var w = ReloadWatcher.init(try RuntimeAnimationDef.load(a, src), 0);
    defer w.deinit();

    // Swap in gen1 — gen0 retained as previous, still resolvable.
    w.swapIn(try RuntimeAnimationDef.load(a, src));
    try testing.expect(w.previous != null);
    try testing.expectEqualStrings("c/v_0001.png", w.previous.?.spriteName(0, 0, 0));

    // Swap in gen2 — gen0 must be freed here (one-generation rule); gen1 held.
    w.swapIn(try RuntimeAnimationDef.load(a, src));
    try testing.expect(w.previous != null);

    // End-of-frame release frees gen1; current (gen2) remains.
    w.releasePrevious();
    try testing.expect(w.previous == null);
    try testing.expectEqualStrings("c/v_0002.png", w.def().spriteName(0, 0, 1));
    // w.deinit() frees gen2. testing.allocator asserts no leak / no double-free.
}

// ── refreshState over game-typed (enum) components (#24 hot reload) ──

/// FP-shaped AnimationState: `clip`/`variant` are ENUMS generated from
/// the comptime def, not raw u8s. `refreshState` must read them via
/// `@intFromEnum` and clamp-write via `@enumFromInt`.
const TypedState = struct {
    const Clip = enum(u8) { idle, walk, eat };
    const Variant = enum(u8) { a, b };

    clip: Clip = .idle,
    variant: Variant = .a,
    frame_count: u8 = 1,
    speed: f32 = 1.0,
    mode: engine.AnimMode = .static,
    frame: u8 = 0,
    dirty: bool = false,
};

test "refreshState: enum-typed clip/variant — meta re-copy without a clamp write" {
    // Def still has all three clips: the enum fields must be left
    // untouched (no @enumFromInt write happens on the grow/steady path).
    var state = TypedState{ .clip = .eat, .variant = .b, .frame_count = 8, .speed = 4.0, .mode = .time };
    const src =
        \\.{
        \\    .variants = .{ "a", "b" },
        \\    .clips = .{
        \\        .idle = .{ .frames = 1 },
        \\        .walk = .{ .frames = 4, .mode = .distance, .speed = 15.0 },
        \\        .eat = .{ .frames = 6, .mode = .time, .speed = 3.0 },
        \\    },
        \\}
    ;
    var def = try RuntimeAnimationDef.load(testing.allocator, src);
    defer def.deinit();

    refreshState(&state, &def);
    try testing.expectEqual(TypedState.Clip.eat, state.clip);
    try testing.expectEqual(TypedState.Variant.b, state.variant);
    try testing.expectEqual(@as(u8, 6), state.frame_count); // .eat's new count
    try testing.expectEqual(@as(f32, 3.0), state.speed);
    try testing.expectEqual(engine.AnimMode.time, state.mode);
    try testing.expect(state.dirty);
}

test "refreshState: enum-typed clip/variant — shrink clamps stay inside the enum" {
    // Def shrank to one clip / one variant: .eat (2) and .b (1) are out
    // of range and must clamp to the last entry — indices 0 and 0, both
    // valid enum tags (the clamp target is always below the old value).
    var state = TypedState{ .clip = .eat, .variant = .b, .frame = 5, .frame_count = 6 };
    const src =
        \\.{
        \\    .variants = .{ "a" },
        \\    .clips = .{ .idle = .{ .frames = 2 } },
        \\}
    ;
    var def = try RuntimeAnimationDef.load(testing.allocator, src);
    defer def.deinit();

    refreshState(&state, &def);
    try testing.expectEqual(TypedState.Clip.idle, state.clip); // 2 → 0
    try testing.expectEqual(TypedState.Variant.a, state.variant); // 1 → 0
    try testing.expectEqual(@as(u8, 2), state.frame_count);
    try testing.expectEqual(@as(u8, 1), state.frame); // 5 → count-1
}

// ── RuntimeAnimDefs: named store + retire-don't-free (#24 hot reload) ──

test "RuntimeAnimDefs: put/get round-trip and count" {
    var store = engine.RuntimeAnimDefs.init(testing.allocator);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expect(store.get("worker") == null);

    try store.put("worker", try RuntimeAnimationDef.load(testing.allocator,
        \\.{ .variants = .{ "v" }, .clips = .{ .c = .{ .frames = 2 } } }
    ));
    try testing.expectEqual(@as(usize, 1), store.count());
    const def = store.get("worker").?;
    try testing.expectEqual(@as(usize, 1), def.clip_names.len);
    try testing.expectEqualStrings("c/v_0001.png", def.spriteName(0, 0, 0));

    // The key was duped — the caller's buffer can die.
    const transient = try testing.allocator.dupe(u8, "bandit");
    try store.put(transient, try RuntimeAnimationDef.load(testing.allocator,
        \\.{ .variants = .{ "v" }, .clips = .{ .c = .{ .frames = 1 } } }
    ));
    testing.allocator.free(transient);
    try testing.expectEqual(@as(usize, 2), store.count());
    try testing.expect(store.get("bandit") != null);
}

test "RuntimeAnimDefs: replacing a def retires the old generation alive (no UAF)" {
    var store = engine.RuntimeAnimDefs.init(testing.allocator);
    defer store.deinit();

    try store.put("worker", try RuntimeAnimationDef.load(testing.allocator,
        \\.{ .variants = .{ "v" }, .clips = .{ .c = .{ .frames = 2, .speed = 1.0 } } }
    ));
    // Simulate a Sprite holding a name slice + game code holding a borrow
    // across the swap (paused sim: nothing will re-resolve them).
    const gen0 = store.get("worker").?;
    const held_name = gen0.spriteName(0, 0, 1);

    try store.put("worker", try RuntimeAnimationDef.load(testing.allocator,
        \\.{ .variants = .{ "v" }, .clips = .{ .c = .{ .frames = 3, .speed = 9.0 } } }
    ));
    // New generation is live…
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expectEqual(@as(f32, 9.0), store.get("worker").?.clipMeta(0).speed);
    // …and the retired one is still readable (graveyard keeps it alive
    // until deinit — testing.allocator would flag a UAF here otherwise).
    try testing.expectEqualStrings("c/v_0002.png", held_name);
    try testing.expectEqual(@as(f32, 1.0), gen0.clipMeta(0).speed);
    // store.deinit() frees both generations; testing.allocator asserts no leak.
}

// ── Clip-major per-variant overrides (studio#61) ──

// Mirrors the comptime `override_zon`: drink shrinks + slows for w_ginger,
// carry re-folders for w_ginger. m_bald/m_beard inherit the base.
const override_src =
    \\.{
    \\    .variants = .{ "m_bald", "m_beard", "w_ginger" },
    \\    .clips = .{
    \\        .idle = .{ .frames = 1, .mode = .static },
    \\        .drink = .{ .frames = 10, .mode = .time, .speed = 5.0, .overrides = .{
    \\            .w_ginger = .{ .frames = 8, .speed = 4.0 },
    \\        } },
    \\        .carry = .{ .frames = 4, .mode = .distance, .speed = 15.0, .folder = "take", .overrides = .{
    \\            .w_ginger = .{ .folder = "take_ginger" },
    \\        } },
    \\    },
    \\}
;

test "RuntimeAnimationDef: clip-major overrides patch meta + sprite names" {
    var rt = try RuntimeAnimationDef.load(testing.allocator, override_src);
    defer rt.deinit();

    const idle = rt.clipIndex("idle").?;
    const drink = rt.clipIndex("drink").?;
    const carry = rt.clipIndex("carry").?;
    const m_bald = rt.variantIndex("m_bald").?;
    const w_ginger = rt.variantIndex("w_ginger").?;

    // drink: base (m_bald) keeps 10 @ 5.0; w_ginger sees 8 @ 4.0, with
    // mode + folder inherited from the base clip.
    const base = rt.clipMetaFor(drink, m_bald);
    try testing.expectEqual(@as(u8, 10), base.frame_count);
    try testing.expectEqual(@as(f32, 5.0), base.speed);
    try testing.expectEqualStrings("drink", base.folder);

    const ginger = rt.clipMetaFor(drink, w_ginger);
    try testing.expectEqual(@as(u8, 8), ginger.frame_count);
    try testing.expectEqual(@as(u8, 8), ginger.entry_count);
    try testing.expectEqual(@as(u16, 8), ginger.beat_count);
    try testing.expectEqual(@as(f32, 4.0), ginger.speed);
    try testing.expectEqual(engine.AnimMode.time, ginger.mode); // inherited
    try testing.expectEqualStrings("drink", ginger.folder); // inherited

    // carry: w_ginger only re-folders (frames/speed inherited).
    const carry_ginger = rt.clipMetaFor(carry, w_ginger);
    try testing.expectEqual(@as(u8, 4), carry_ginger.frame_count);
    try testing.expectEqual(@as(f32, 15.0), carry_ginger.speed);
    try testing.expectEqualStrings("take_ginger", carry_ginger.folder);
    try testing.expectEqualStrings("take", rt.clipMetaFor(carry, m_bald).folder);

    // A clip w_ginger does NOT override inherits the base meta exactly.
    try testing.expectEqual(rt.clipMeta(idle).frame_count, rt.clipMetaFor(idle, w_ginger).frame_count);

    // Sprite names honor the overridden folder + per-variant frame count.
    try testing.expectEqualStrings("take/m_bald_0001.png", rt.spriteName(carry, m_bald, 0));
    try testing.expectEqualStrings("take_ginger/w_ginger_0001.png", rt.spriteName(carry, w_ginger, 0));
    try testing.expectEqualStrings("drink/m_bald_0010.png", rt.spriteName(drink, m_bald, 9));
    try testing.expectEqualStrings("drink/w_ginger_0008.png", rt.spriteName(drink, w_ginger, 7));
    // w_ginger's drink row is 8 long — frame 8 is past it, but the base
    // (m_bald) still resolves its own longer row.
    try testing.expectEqualStrings("", rt.spriteName(drink, w_ginger, 8));
    try testing.expectEqualStrings("drink/m_bald_0009.png", rt.spriteName(drink, m_bald, 8));
}

test "RuntimeAnimationDef: refreshState applies the variant's override meta" {
    var def = try RuntimeAnimationDef.load(testing.allocator, override_src);
    defer def.deinit();

    const drink = def.clipIndex("drink").?;
    const m_bald = def.variantIndex("m_bald").?;
    const w_ginger = def.variantIndex("w_ginger").?;

    // Entity on w_ginger drinking: refreshState copies the OVERRIDE meta,
    // not the base — 8 frames @ 4.0, mode inherited as .time.
    var ginger_state = AnimationState{ .clip = drink, .variant = w_ginger, .frame = 0, .frame_count = 99, .speed = 1.0, .mode = .static };
    refreshState(&ginger_state, &def);
    try testing.expectEqual(@as(u8, 8), ginger_state.frame_count);
    try testing.expectEqual(@as(f32, 4.0), ginger_state.speed);
    try testing.expectEqual(engine.AnimMode.time, ginger_state.mode);
    try testing.expect(ginger_state.dirty);

    // Entity on the base variant gets the (unpatched) base meta.
    var base_state = AnimationState{ .clip = drink, .variant = m_bald, .frame = 0, .frame_count = 99, .speed = 1.0, .mode = .static };
    refreshState(&base_state, &def);
    try testing.expectEqual(@as(u8, 10), base_state.frame_count);
    try testing.expectEqual(@as(f32, 5.0), base_state.speed);
    try testing.expectEqual(engine.AnimMode.time, base_state.mode);
}

test "RuntimeAnimationDef.load: clip-major override errors mirror the comptime rejects" {
    const a = testing.allocator;
    // Override key names a variant that doesn't exist.
    try testing.expectError(error.UnknownVariant, RuntimeAnimationDef.load(a,
        \\.{ .variants = .{ "a" }, .clips = .{ .c = .{ .frames = 2, .mode = .time, .speed = 1.0, .overrides = .{ .nope = .{ .frames = 1 } } } } }
    ));
    // Override carries a field outside frames/speed/mode/folder.
    try testing.expectError(error.UnknownOverrideField, RuntimeAnimationDef.load(a,
        \\.{ .variants = .{ "a" }, .clips = .{ .c = .{ .frames = 2, .mode = .time, .speed = 1.0, .overrides = .{ .a = .{ .bogus = 3 } } } } }
    ));
    // Effective .static (base mode) + per-slot hold in the override entries.
    try testing.expectError(error.HoldOnStaticClip, RuntimeAnimationDef.load(a,
        \\.{ .variants = .{ "a" }, .clips = .{ .c = .{ .frames = 1, .mode = .static, .overrides = .{ .a = .{ .frames = .{ .{ .f = 1, .run = 2 } } } } } } }
    ));
    // Top-level `.overrides` that isn't a struct of per-variant overrides.
    try testing.expectError(error.BadOverrides, RuntimeAnimationDef.load(a,
        \\.{ .variants = .{ "a" }, .clips = .{ .c = .{ .frames = 2, .mode = .time, .speed = 1.0, .overrides = 5 } } }
    ));
    // A per-variant override VALUE that isn't a struct.
    try testing.expectError(error.BadOverride, RuntimeAnimationDef.load(a,
        \\.{ .variants = .{ "a" }, .clips = .{ .c = .{ .frames = 2, .mode = .time, .speed = 1.0, .overrides = .{ .a = 5 } } } }
    ));
}

test "RuntimeAnimationDef.load: an empty `.overrides = .{}` map is a no-op (editor-emitted)" {
    // Zoir lowers `.{}` to empty_literal, not struct_literal — the runtime
    // must accept it as "no overrides" (the comptime path does), because the
    // editor writes it the instant it opens the field before setting one.
    var rt = try RuntimeAnimationDef.load(testing.allocator,
        \\.{ .variants = .{ "a", "b" }, .clips = .{ .c = .{ .frames = 3, .mode = .time, .speed = 1.0, .overrides = .{} } } }
    );
    defer rt.deinit();
    const c = rt.clipIndex("c").?;
    // Both variants see the base — nothing was overridden.
    try testing.expectEqual(@as(u8, 3), rt.clipMetaFor(c, 0).frame_count);
    try testing.expectEqual(@as(u8, 3), rt.clipMetaFor(c, 1).frame_count);
    try testing.expectEqualStrings("c/b_0001.png", rt.spriteName(c, 1, 0));
}

test "RuntimeAnimationDef.load: an empty override VALUE `.{}` inherits everything" {
    // `.b = .{}` — the variant is listed but sets no field, so it inherits
    // the base clip wholesale (comptime accepts it as a no-op patch).
    var rt = try RuntimeAnimationDef.load(testing.allocator,
        \\.{ .variants = .{ "a", "b" }, .clips = .{ .c = .{ .frames = 3, .mode = .time, .speed = 2.0, .folder = "f", .overrides = .{ .b = .{} } } } }
    );
    defer rt.deinit();
    const c = rt.clipIndex("c").?;
    const b = rt.variantIndex("b").?;
    const m = rt.clipMetaFor(c, b);
    try testing.expectEqual(@as(u8, 3), m.frame_count);
    try testing.expectEqual(@as(f32, 2.0), m.speed);
    try testing.expectEqual(engine.AnimMode.time, m.mode);
    try testing.expectEqualStrings("f", m.folder);
    try testing.expectEqualStrings("f/b_0001.png", rt.spriteName(c, b, 0));
}

test "RuntimeAnimationDef.load: a `.mode=.static`-only override over a HELD base is rejected" {
    // The variant overrides ONLY the mode; the base's held entries (run 2)
    // are inherited, so the effective (static, holds) pair is illegal — the
    // comptime path rejects it, and the runtime must too even though the
    // override carries no `.frames` of its own.
    try testing.expectError(error.HoldOnStaticClip, RuntimeAnimationDef.load(testing.allocator,
        \\.{ .variants = .{ "a", "b" }, .clips = .{
        \\    .c = .{ .frames = .{ .{ .f = 1, .run = 2 }, 2 }, .mode = .time, .speed = 1.0, .overrides = .{ .b = .{ .mode = .static } } },
        \\} }
    ));
}

test "RuntimeAnimationDef: slotForBeat is variant-aware (override changes the run structure)" {
    // swing base is a 4-frame count-form clip; `heavy` overrides it with a
    // held+reordered entry list. slotForBeat must walk the VARIANT's entries.
    var rt = try RuntimeAnimationDef.load(testing.allocator,
        \\.{ .variants = .{ "base", "heavy" }, .clips = .{
        \\    .swing = .{ .frames = 4, .mode = .time, .speed = 1.0, .overrides = .{
        \\        .heavy = .{ .frames = .{ .{ .f = 1, .run = 2 }, 2, 3 } },
        \\    } },
        \\} }
    );
    defer rt.deinit();
    const swing = rt.clipIndex("swing").?;
    const base = rt.variantIndex("base").?;
    const heavy = rt.variantIndex("heavy").?;

    // base: identity count-form row over 4 beats.
    try testing.expectEqual(@as(u8, 0), rt.slotForBeat(swing, base, 0));
    try testing.expectEqual(@as(u8, 1), rt.slotForBeat(swing, base, 1));
    try testing.expectEqual(@as(u8, 3), rt.slotForBeat(swing, base, 3));
    // heavy: slot 0 held two beats {0,0,1,2}, beat_count 4.
    try testing.expectEqual(@as(u8, 0), rt.slotForBeat(swing, heavy, 0));
    try testing.expectEqual(@as(u8, 0), rt.slotForBeat(swing, heavy, 1)); // held
    try testing.expectEqual(@as(u8, 1), rt.slotForBeat(swing, heavy, 2));
    try testing.expectEqual(@as(u8, 2), rt.slotForBeat(swing, heavy, 3));
    try testing.expectEqual(@as(u8, 0), rt.slotForBeat(swing, heavy, 4)); // wraps
    // clipMetaFor already reports the overridden beat_count; slotForBeat now agrees.
    try testing.expectEqual(@as(u16, 4), rt.clipMetaFor(swing, heavy).beat_count);
}
