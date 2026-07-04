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
        // Metadata parity.
        const cm = WorkerAnim.clipMeta(clip);
        const rm = rt.clipMeta(ci);
        try testing.expectEqual(cm.frame_count, rm.frame_count);
        try testing.expectEqual(cm.speed, rm.speed);
        try testing.expectEqual(cm.mode, rm.mode);
        try testing.expectEqualStrings(cm.folder, rm.folder);

        inline for (@typeInfo(WorkerAnim.variants).@"enum".fields) |vf| {
            const variant: WorkerAnim.variants = @enumFromInt(vf.value);
            const vi: u8 = vf.value;
            try testing.expectEqual(@as(?u8, vi), rt.variantIndex(vf.name));
            // Byte-equal sprite names across every valid frame of the clip.
            var f: u8 = 0;
            while (f < cm.frame_count) : (f += 1) {
                try testing.expectEqualStrings(
                    WorkerAnim.spriteName(clip, variant, f),
                    rt.spriteName(ci, vi, f),
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
