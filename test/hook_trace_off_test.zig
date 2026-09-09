//! The OFF half of the tracing contract (#858).
//!
//! Tracing is opt-in, and "opt-in" has to mean *a build that did not opt
//! in pays nothing*. This file is that proof from inside the language:
//! `zig test` makes Zig's own test runner the compilation root, and the
//! test runner declares no `labelle_hook_trace` — so this binary is,
//! structurally, an untraced build.
//!
//! What is asserted here:
//!
//!   * `engine.hookTraceEnabled` is `false`, so every `if (comptime
//!     tracing)` in `events_mixin.zig` and `hook_trace_dispatch.zig` is
//!     a comptime-false branch and is not lowered at all;
//!   * `Game.HookTracer` is `void` and the `hook_tracer` field is
//!     zero-sized, so `Game`'s layout is unchanged;
//!   * `hook_trace_dispatch.zig` is never instantiated — `Game.hooks`
//!     goes straight to `core.MergeHooks.emit`;
//!   * emit / tryEmit / emitSync / emitHook / dispatchEvents still
//!     behave exactly as `HOOK-DELIVERY-CONTRACT.md` says, including the
//!     receiver-tuple order the traced walk mirrors.
//!
//! The BINARY-level measurement (an untraced build of this branch
//! producing byte-identical code to pre-#858) is `bash tools/hook_trace_cost.sh` (the script IS the entrypoint —
//! there is no such build step);
//! see `HOOK-TRACING.md` §5.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const MockEcs = core.MockEcsBackend(u32);

// ── Same receivers and order as the traced harness ─────────────────────
//
// `test/hook_trace_root_exe.zig` runs this same fan-out with tracing ON.
// Keeping the expected order literal identical in both files is what
// pins "trace on/off produce the same observable handler order".

const Log = struct {
    entries: [32][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *Log, label: []const u8) void {
        if (self.len < self.entries.len) {
            self.entries[self.len] = label;
            self.len += 1;
        }
    }
    fn items(self: *const Log) []const []const u8 {
        return self.entries[0..self.len];
    }
    fn reset(self: *Log) void {
        self.len = 0;
    }
};

fn expectOrder(log: *const Log, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, log.len);
    for (expected, log.items()) |want, got| try testing.expectEqualStrings(want, got);
}

const ClaimPayload = struct {
    seq: u32 = 0,
    pub const consumable = true;
};

const OffEvents = union(enum) {
    t__alpha: struct { seq: u32 = 0 },
    t__claim: ClaimPayload,
    t__quiet: struct { seq: u32 = 0 },
};

const A = struct {
    pub const labelle_receiver_id = "hooks/animation_hooks";
    log: *Log,
    pub fn t__alpha(self: *A, _: anytype) void {
        self.log.push("anim:alpha");
    }
    pub fn t__claim(self: *A, _: anytype) bool {
        self.log.push("anim:claim");
        return false;
    }
};

const B = struct {
    log: *Log,
    claims: bool = false,
    pub fn t__alpha(self: *B, _: anytype) void {
        self.log.push("needs:alpha");
    }
    pub fn t__claim(self: *B, _: anytype) bool {
        self.log.push("needs:claim");
        return self.claims;
    }
};

const C = struct {
    log: *Log,
    pub fn t__alpha(self: *C, _: anytype) void {
        self.log.push("tail:alpha");
    }
    pub fn t__claim(self: *C, _: anytype) bool {
        self.log.push("tail:claim");
        return true;
    }
};

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

const OffPayload = core.MergeHookPayloads(.{ engine.HookPayload(u32), OffEvents });
const OffHooks = core.MergeHooks(OffPayload, .{ *A, *B, *C });

const OffGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *OffHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    OffEvents,
);

const Harness = struct {
    game: OffGame,
    hooks: OffHooks,
    a: A,
    b: B,
    c: C,
    log: Log,

    fn wire(self: *Harness) void {
        self.log = .{};
        self.a = .{ .log = &self.log };
        self.b = .{ .log = &self.log };
        self.c = .{ .log = &self.log };
        self.hooks = .{ .receivers = .{ &self.a, &self.b, &self.c } };
        self.game = OffGame.init(testing.allocator);
        self.game.setHooks(&self.hooks);
    }
    fn unwire(self: *Harness) void {
        self.game.deinit();
    }
};

// ── The off proof ──────────────────────────────────────────────────────

test "tracing is OFF unless the compilation root opts in" {
    try testing.expect(!engine.hookTraceEnabled);
    try testing.expect(!engine.hook_trace.enabled);
    try testing.expect(!OffGame.hook_trace_enabled);
}

test "an untraced Game carries no tracer state at all" {
    // `void`, not "a disabled Tracer" — there is nothing to disable.
    try testing.expect(OffGame.HookTracer == void);
    try testing.expectEqual(@as(usize, 0), @sizeOf(OffGame.HookTracer));

    var h: Harness = undefined;
    h.wire();
    defer h.unwire();
    try testing.expect(@TypeOf(h.game.hook_tracer) == void);
    try testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(h.game.hook_tracer)));
}

test "the trace ring type would be non-trivial if it were instantiated" {
    // Guards against the off proof passing because the tracer is empty
    // in every build: with the DEFAULT options the ring is real state,
    // and it is `Game`'s `void` field — not a small `Tracer` — that
    // makes the untraced build free.
    try testing.expect(@sizeOf(engine.HookTracer) > 0);
    try testing.expect(engine.HookTracer.capacity > 0);
}

// ── Behaviour is untouched ─────────────────────────────────────────────

test "off: buffered emit still drains in receiver-tuple order" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });
    try testing.expectEqual(@as(usize, 1), h.game.event_buffer.items.len);
    try testing.expectEqual(@as(usize, 0), h.log.len);

    h.game.dispatchEvents();
    // Byte-identical to the sequence `test/hook_trace_root_exe.zig`
    // asserts with tracing ON.
    try expectOrder(&h.log, &.{ "anim:alpha", "needs:alpha", "tail:alpha" });
    try testing.expectEqual(@as(usize, 0), h.game.event_buffer.items.len);
}

test "off: emitSync still bypasses the buffer" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });
    try expectOrder(&h.log, &.{ "anim:alpha", "needs:alpha", "tail:alpha" });
    try testing.expectEqual(@as(usize, 0), h.game.event_buffer.items.len);
}

test "off: a consumable event still stops at the first claim" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.b.claims = true;
    h.game.emitSync(.{ .t__claim = .{ .seq = 1 } });
    try expectOrder(&h.log, &.{ "anim:claim", "needs:claim" });

    h.log.reset();
    h.b.claims = false;
    h.game.emitSync(.{ .t__claim = .{ .seq = 2 } });
    try expectOrder(&h.log, &.{ "anim:claim", "needs:claim", "tail:claim" });
}

test "off: an event nobody declares is still silently dropped" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__quiet = .{ .seq = 1 } });
    h.game.dispatchEvents();
    try testing.expectEqual(@as(usize, 0), h.log.len);
}

test "off: tryEmit and emit still share one enqueue" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    try h.game.tryEmit(.{ .t__alpha = .{ .seq = 1 } });
    h.game.emit(.{ .t__alpha = .{ .seq = 2 } });
    try testing.expectEqual(@as(usize, 2), h.game.event_buffer.items.len);
    h.game.dispatchEvents();
    try testing.expectEqual(@as(usize, 6), h.log.len);
}

// ── The pieces that DO compile in an off build ─────────────────────────
//
// `hook_trace.zig` is imported by `game.zig` either way; only its call
// sites fold. These keep the module itself honest so a traced build is
// not the first place a typo shows up.

test "off: receiver identity still resolves at comptime" {
    const Id = engine.hook_trace.ReceiverId(A);
    try testing.expectEqualStrings("hooks/animation_hooks", Id.id);
    try testing.expect(Id.kind == .declared);

    const Id2 = engine.hook_trace.ReceiverId(B);
    try testing.expect(Id2.kind == .derived);
    // Derivation drops the final `.Name` and maps `.` back to `/`.
    try testing.expectEqualStrings("hook_trace_off_test", Id2.id);
    try testing.expectEqualStrings("hook_trace_off_test.B", Id2.type_name);
}

test "off: the filter grammar is exact-match plus a trailing-star prefix" {
    const F = engine.HookTraceFilter;
    const all: F = .{};
    try testing.expect(all.admits("anything"));

    const only_alpha: F = .{ .include = &.{"t__alpha"} };
    try testing.expect(only_alpha.admits("t__alpha"));
    try testing.expect(!only_alpha.admits("t__alphabet"));

    const prefix: F = .{ .include = &.{"packs/citizens/*"} };
    try testing.expect(prefix.admits("packs/citizens/hooks/needs_hooks"));
    try testing.expect(!prefix.admits("hooks/animation_hooks"));

    const excluded: F = .{ .include = &.{"t__*"}, .exclude = &.{"t__alpha"} };
    try testing.expect(excluded.admits("t__beta"));
    try testing.expect(!excluded.admits("t__alpha"));
}

test "off: a record renders to text and to JSON" {
    var rec: engine.HookTraceRecord = .{
        .seq = 3,
        .frame = 9,
        .drain = 2,
        .phase = .deliver,
        .source = .drain,
        .event = "t__alpha",
        .receiver = "hooks/animation_hooks",
        .receiver_type = "animation_hooks.AnimationHooks",
        .receiver_id_kind = .declared,
        .index = 1,
    };

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try rec.writeText(&w);
    const text = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, text, "deliver") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hooks/animation_hooks") != null);

    var w2 = std.Io.Writer.fixed(&buf);
    try rec.writeJson(&w2);
    const json = buf[0..w2.end];
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("deliver", obj.get("phase").?.string);
    try testing.expectEqualStrings("t__alpha", obj.get("event").?.string);
    try testing.expectEqualStrings("hooks/animation_hooks", obj.get("receiver").?.string);
    try testing.expectEqual(@as(i64, 1), obj.get("index").?.integer);
    // Non-receiver keys are omitted, not null.
    try testing.expect(obj.get("error") == null);
}

test "off: JSON escaping survives a quote in a name" {
    var rec: engine.HookTraceRecord = .{ .phase = .enqueue, .event = "we\"ird\n" };
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try rec.writeJson(&w);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf[0..w.end], .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("we\"ird\n", parsed.value.object.get("event").?.string);
}

test "off: the ring bound and its drop accounting" {
    var t: engine.HookTracer = .{};
    const cap = engine.HookTracer.capacity;
    for (0..cap + 5) |i| t.push(.{ .phase = .enqueue, .event = "e", .count = @intCast(i) });
    try testing.expectEqual(cap, t.count());
    try testing.expectEqual(@as(u64, 5), t.dropped);
    try testing.expectEqual(@as(u64, cap + 5), t.seq);
    try testing.expectEqual(@as(u32, 5), t.at(0).count);
}
