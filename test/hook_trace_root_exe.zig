//! Executable harness for opt-in hook tracing (#858, parent #854).
//!
//! Tracing is switched on by a declaration on the COMPILATION ROOT, and
//! under `zig test` the compilation root is Zig's own test runner — not
//! the test file. So, exactly as #855 found for `HookContext.game()`,
//! the shipping form can only be compiled and run from a real
//! executable whose root carries the declaration. This file is that
//! root: it declares `labelle_hook_trace` and `pub const Game` the way
//! an assembler-generated `main.zig` does.
//!
//! `zig build test` runs it; any failed check exits non-zero.
//!
//! The OFF half of the contract is `test/hook_trace_off_test.zig`, an
//! ordinary unit test (whose root, being the test runner, can never
//! declare the flag — which is precisely what makes it the off proof).
//!
//! What is checked here, in order:
//!
//!   1  enqueue through `emit` and through `tryEmit`
//!   2  a FAILED enqueue, through both, with the error name
//!   3  buffered drain — drain identity, per-event fan-out bounds
//!   4  `emitSync` — immediate, no drain records
//!   5  `emitHook` — the engine's closed payload
//!   6  a handler-emitted event landing on the NEXT drain
//!   7  a consumable event: where propagation stopped
//!   8  an event with no listener at all
//!   9  receiver identity: declared (exact #723 id) vs derived
//!  10  event and receiver filtering
//!  11  the bound: both overflow strategies, and the drop counters
//!  12  a live sink, and its re-entrancy guard
//!  13  text and JSONL rendering
//!  14  PARITY: the traced walk visits receivers in exactly the order
//!      `labelle-core`'s own `MergeHooks.emit` does

const std = @import("std");
const engine = @import("engine");

const core = engine.core;
const trace = engine.hook_trace;
const Order = @import("hook_trace_fixtures/order.zig");
const needs_hooks = @import("hook_trace_fixtures/hooks/needs_hooks.zig");

const Entity = core.MockEcsBackend(u32).Entity;

/// THE OPT-IN. Everything in this file exists because of this line.
pub const labelle_hook_trace: engine.HookTraceOptions = .{
    .ring_capacity = 64,
    .payload_capacity = 32,
};

// ── The event union ────────────────────────────────────────────────────

const ClaimPayload = struct {
    seq: u32 = 0,
    pub const consumable = true;
};

const TraceEvents = union(enum) {
    t__alpha: struct { seq: u32 = 0 },
    t__chain_src: struct { depth: u32 = 0 },
    t__chain_dst: struct { depth: u32 = 0 },
    t__claim: ClaimPayload,
    /// Declared by nobody — the "my listener never ran" case.
    t__quiet: struct { seq: u32 = 0 },
    /// Slice-bearing: pins that payload capture never dereferences a
    /// borrowed pointer.
    t__named: struct { name: []const u8 = "", seq: u32 = 0 },
};

var chain_game: ?*Game = null;
/// #858 review: when set, `t__chain_src`'s handler ALSO drains, producing a
/// nested `dispatchEvents` inside a running drain.
var nested_drain_game: ?*Game = null;

// ── Receivers ──────────────────────────────────────────────────────────

/// Declares its #723 id explicitly, so its trace records are labelled
/// with the assembler's id verbatim rather than a derivation.
const AnimationHooks = struct {
    /// Exactly labelle-assembler#723's `Receiver.id` for a game-root
    /// hook at `hooks/animation_hooks.zig`.
    pub const labelle_receiver_id = "hooks/animation_hooks";

    order: *Order.Log,

    pub fn t__alpha(self: *AnimationHooks, _: anytype) void {
        self.order.push("anim:alpha");
    }
    pub fn t__chain_src(self: *AnimationHooks, info: anytype) void {
        self.order.push("anim:chain_src");
        if (chain_game) |g| g.emit(.{ .t__chain_dst = .{ .depth = info.depth + 1 } });
        // #858 review: drain from INSIDE a drain, so the nested-numbering
        // regression has something to observe.
        if (nested_drain_game) |g| g.dispatchEvents();
    }
    pub fn t__chain_dst(self: *AnimationHooks, _: anytype) void {
        self.order.push("anim:chain_dst");
    }
    pub fn t__named(self: *AnimationHooks, _: anytype) void {
        self.order.push("anim:named");
    }
    pub fn t__claim(self: *AnimationHooks, _: anytype) bool {
        self.order.push("anim:claim");
        return false; // declines — the next receiver gets a look
    }
    pub fn frame_start(self: *AnimationHooks, _: anytype) void {
        self.order.push("anim:frame_start");
    }
};

/// Third receiver, declared in this ROOT file. Its derived id is the
/// degenerate case the derivation cannot separate — see check 9.
const TailHooks = struct {
    order: *Order.Log,

    pub fn t__alpha(self: *TailHooks, _: anytype) void {
        self.order.push("tail:alpha");
    }
    pub fn t__claim(self: *TailHooks, _: anytype) bool {
        self.order.push("tail:claim");
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

const AllHookPayloads = engine.MergeHookPayloads(.{
    engine.HookPayload(Entity),
    TraceEvents,
});

/// Tuple order IS dispatch order (assembler#723 §2.1).
const AllHooks = engine.MergeHooks(AllHookPayloads, .{
    *AnimationHooks,
    *needs_hooks.NeedsHooks,
    *TailHooks,
});

const AssembledGame = engine.GameConfig(
    core.StubRender(Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *AllHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    TraceEvents,
);

pub const Game = AssembledGame;

// ── Assertion plumbing ─────────────────────────────────────────────────

var failures: usize = 0;

fn expect(ok: bool, what: []const u8) void {
    if (!ok) {
        std.debug.print("hook_trace_root_exe: FAILED: {s}\n", .{what});
        failures += 1;
    }
}

fn expectEqStr(want: []const u8, got: []const u8, what: []const u8) void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print(
            "hook_trace_root_exe: FAILED: {s}\n  want: \"{s}\"\n  got:  \"{s}\"\n",
            .{ what, want, got },
        );
        failures += 1;
    }
}

fn expectEqU64(want: u64, got: u64, what: []const u8) void {
    if (want != got) {
        std.debug.print(
            "hook_trace_root_exe: FAILED: {s} (want {d}, got {d})\n",
            .{ what, want, got },
        );
        failures += 1;
    }
}

/// Render the retained trace as `phase:event[:receiver]` lines so a whole
/// expected sequence is one literal array.
fn shape(t: *const engine.HookTracer, buf: [][]const u8, store: [][64]u8) []const []const u8 {
    var n: usize = 0;
    for (0..t.count()) |i| {
        const r = t.at(i);
        var w = std.Io.Writer.fixed(&store[n]);
        w.print("{s}:{s}", .{ @tagName(r.phase), r.event }) catch {};
        if (r.receiver.len != 0) w.print(":{s}", .{r.receiver}) catch {};
        buf[n] = store[n][0..w.end];
        n += 1;
        if (n == buf.len) break;
    }
    return buf[0..n];
}

var shape_buf: [128][]const u8 = undefined;
var shape_store: [128][64]u8 = undefined;

fn expectShape(t: *const engine.HookTracer, expected: []const []const u8, what: []const u8) void {
    const got = shape(t, &shape_buf, &shape_store);
    var ok = got.len == expected.len;
    if (ok) {
        for (got, expected) |a, b| {
            if (!std.mem.eql(u8, a, b)) ok = false;
        }
    }
    if (!ok) {
        std.debug.print("hook_trace_root_exe: FAILED: {s}\n  want:\n", .{what});
        for (expected) |e| std.debug.print("    {s}\n", .{e});
        std.debug.print("  got:\n", .{});
        for (got) |g| std.debug.print("    {s}\n", .{g});
        failures += 1;
    }
}

/// The receiver-scoped record for `receiver_id`, or null.
fn findDeliver(t: *const engine.HookTracer, receiver_id: []const u8) ?*const engine.HookTraceRecord {
    for (0..t.count()) |i| {
        const r = t.at(i);
        if (r.phase == .deliver and std.mem.eql(u8, r.receiver, receiver_id)) return r;
    }
    return null;
}

// ── Harness ────────────────────────────────────────────────────────────

const Harness = struct {
    game: Game,
    hooks: AllHooks,
    anim: AnimationHooks,
    needs: needs_hooks.NeedsHooks,
    tail: TailHooks,
    order: Order.Log,

    fn wire(self: *Harness, allocator: std.mem.Allocator) void {
        self.order = .{};
        self.anim = .{ .order = &self.order };
        self.needs = .{ .order = &self.order };
        self.tail = .{ .order = &self.order };
        self.hooks = .{ .receivers = .{ &self.anim, &self.needs, &self.tail } };
        self.game = Game.init(allocator);
        self.game.setHooks(&self.hooks);
        chain_game = &self.game;
    }

    fn unwire(self: *Harness) void {
        chain_game = null;
        self.game.deinit();
    }

    /// Forget everything `setHooks`' own `game_init` produced so each
    /// check starts from a clean trace.
    fn fresh(self: *Harness) *engine.HookTracer {
        self.order.reset();
        self.game.hook_tracer.clear();
        return &self.game.hook_tracer;
    }
};

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    expect(engine.hookTraceEnabled, "tracing is ON in this compilation");
    expect(Game.hook_trace_enabled, "Game agrees tracing is on");
    expect(engine.HookTracer.capacity == 64, "ring capacity comes from the root options");

    var h: Harness = undefined;
    h.wire(allocator);
    defer h.unwire();

    try check01Enqueue(&h);
    try check03BufferedDrain(&h);
    try check04Sync(&h);
    try check05Hook(&h);
    try check06NextDrain(&h);
    try check07Consumable(&h);
    try check08NoListener(&h);
    try check09Identity(&h);
    try check10Filtering(&h);
    try check11NestedDrainNumbering(&h);
    try check12ReentrantSinkLeavesNoTrace(&h);
    try check12Sink(&h);
    try check13Rendering(&h);
    try check14Parity(&h);
    try check15Payloads(&h);

    // These build their own games / tracers.
    try check02FailedEnqueue(allocator);
    try check11Bound();

    if (failures != 0) {
        std.debug.print("hook_trace_root_exe: {d} check(s) FAILED\n", .{failures});
        return 1;
    }
    std.debug.print("hook_trace_root_exe: ok\n", .{});
    return 0;
}

// ── 1. Enqueue, both APIs ──────────────────────────────────────────────

/// #858 review: a NESTED `dispatchEvents` must not renumber the outer drain.
///
/// `drain_end` (and every outer deliver/enqueue after the nested call) read
/// the monotonic `drain_seq`, so a handler that drained made the OUTER drain
/// report the INNER id — the one field that says which drain a record belongs
/// to, silently wrong exactly when the trace is hardest to read.
fn check11NestedDrainNumbering(h: *Harness) !void {
    const t = h.fresh();

    // `t__chain_src`'s handler emits; here we make it DRAIN as well, so the
    // inner drain runs inside the outer one.
    nested_drain_game = &h.game;
    defer nested_drain_game = null;

    h.game.emit(.{ .t__chain_src = .{ .depth = 0 } });
    h.game.dispatchEvents();

    var outer_begin: ?u64 = null;
    var outer_end: ?u64 = null;
    var inner_begin: ?u64 = null;
    var depth: u32 = 0;
    for (0..t.count()) |i| {
        const r = t.at(i);
        switch (r.phase) {
            .drain_begin => {
                depth += 1;
                if (depth == 1) outer_begin = r.drain else if (depth == 2) inner_begin = r.drain;
            },
            .drain_end => {
                if (depth == 1) outer_end = r.drain;
                depth -= 1;
            },
            else => {},
        }
    }
    expect(outer_begin != null and inner_begin != null, "the nested drain actually ran");
    expect(outer_end != null, "the outer drain ended");
    expect(inner_begin.? != outer_begin.?, "the inner drain got its OWN id");
    expectEqU64(outer_begin.?, outer_end.?, "drain_end reports the OUTER id, not the nested one");
}

/// #858 review: a record rejected for sink reentrancy must leave NO trace —
/// it previously consumed a `seq` and was written to the ring first, so the
/// trace showed a sequence gap AND a retained record for something counted as
/// dropped, which cannot be reconciled.
fn check12ReentrantSinkLeavesNoTrace(h: *Harness) !void {
    const t = h.fresh();
    const Sink = struct {
        var tracer: *engine.HookTracer = undefined;
        fn onRecord(_: ?*anyopaque, _: *const engine.HookTraceRecord) void {
            // Re-enter: this push must be rejected outright.
            tracer.push(.{ .phase = .deliver, .source = .drain, .event = "reentrant" });
        }
    };
    Sink.tracer = t;
    var ctx: u8 = 0;
    t.sink = .{ .ctx = @ptrCast(&ctx), .onRecord = Sink.onRecord };
    defer t.sink = null;

    const seq_before = t.seq;
    const count_before = t.count();
    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });

    expectEqU64(1, t.dropped_reentrant, "the reentrant record is counted");
    expectEqU64(seq_before + 1, t.seq, "…and consumed NO sequence number");
    expect(t.count() == count_before + 1, "…and was not retained in the ring");
    for (0..t.count()) |i| {
        expect(!std.mem.eql(u8, t.at(i).event, "reentrant"), "the rejected record is absent");
    }

    // Leave no buffered event behind: a later check asserts on EVERY
    // rendered payload, and a stray `t__alpha` would fail it with the wrong
    // seq. Sink is cleared first so the drain does not re-enter it.
    t.sink = null;
    h.game.dispatchEvents();
}

fn check01Enqueue(h: *Harness) !void {
    var t = h.fresh();
    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });
    expectShape(t, &.{"enqueue:t__alpha"}, "emit records one enqueue");
    expect(t.at(0).source == .emit, "…tagged with the emit API");
    expect(t.at(0).err.len == 0, "…and no error");

    t = h.fresh();
    try h.game.tryEmit(.{ .t__alpha = .{ .seq = 2 } });
    expectShape(t, &.{"enqueue:t__alpha"}, "tryEmit records one enqueue too");
    expect(t.at(0).source == .try_emit, "…tagged with the tryEmit API");

    // Drain what we queued so later checks start empty.
    h.game.dispatchEvents();
}

// ── 2. A FAILED enqueue, both APIs ─────────────────────────────────────

/// A dropped notification is exactly what someone turns tracing on to
/// find: `emit` swallows the failure, and even `tryEmit`'s caller may.
fn check02FailedEnqueue(backing: std.mem.Allocator) !void {
    const armOom = struct {
        fn f(fa: *std.testing.FailingAllocator) void {
            fa.fail_index = fa.alloc_index;
            fa.resize_fail_index = fa.resize_index;
        }
    }.f;
    const healOom = struct {
        fn f(fa: *std.testing.FailingAllocator) void {
            fa.fail_index = std.math.maxInt(usize);
            fa.resize_fail_index = std.math.maxInt(usize);
        }
    }.f;

    var failing = std.testing.FailingAllocator.init(backing, .{});
    var h: Harness = undefined;
    h.wire(failing.allocator());
    defer h.unwire();

    // Park the buffer exactly at capacity so the next append must grow.
    try h.game.event_buffer.ensureTotalCapacityPrecise(h.game.allocator, 4);
    while (h.game.event_buffer.items.len < h.game.event_buffer.capacity) {
        try h.game.tryEmit(.{ .t__alpha = .{ .seq = 0 } });
    }

    var t = h.fresh();
    armOom(&failing);
    h.game.emit(.{ .t__alpha = .{ .seq = 99 } });
    healOom(&failing);
    expectShape(t, &.{"enqueue_failed:t__alpha"}, "a swallowed emit failure IS traced");
    expect(t.at(0).source == .emit, "…attributed to emit");
    expectEqStr("OutOfMemory", t.at(0).err, "…with the error name");
    expectEqU64(4, t.at(0).count, "…and the queue depth at the moment of loss");

    t = h.fresh();
    armOom(&failing);
    const res = h.game.tryEmit(.{ .t__alpha = .{ .seq = 98 } });
    healOom(&failing);
    expect(res == error.OutOfMemory, "tryEmit still returns the error");
    expectShape(t, &.{"enqueue_failed:t__alpha"}, "and the failure is traced");
    expect(t.at(0).source == .try_emit, "…attributed to tryEmit");

    // The four accepted events still drain normally: tracing changed
    // nothing about the #856 failure guarantee.
    _ = h.fresh();
    h.game.dispatchEvents();
    // Four accepted `t__alpha`s x three receivers that declare it.
    expectEqU64(12, h.order.len, "the four accepted events still delivered");
}

// ── 3. Buffered delivery ───────────────────────────────────────────────

fn check03BufferedDrain(h: *Harness) !void {
    const t = h.fresh();
    const drain_before = t.drain_seq;
    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });
    h.game.dispatchEvents();

    expectShape(t, &.{
        "enqueue:t__alpha",
        "drain_begin:",
        "dispatch_begin:t__alpha",
        "deliver:t__alpha:hooks/animation_hooks",
        "deliver:t__alpha:hook_trace_fixtures/hooks/needs_hooks",
        "deliver:t__alpha:hook_trace_root_exe",
        "dispatch_end:t__alpha",
        "drain_end:",
    }, "a buffered emit traces enqueue → drain → per-receiver delivery");

    expectEqU64(drain_before + 1, t.drain_seq, "the drain counter advanced");
    expect(t.at(1).count == 1, "drain_begin carries the snapshot size");
    expect(t.at(6).count == 3, "dispatch_end carries the handler count");
    expect(t.at(2).source == .drain, "delivery is attributed to the drain");
    expect(t.at(0).drain == drain_before, "the enqueue predates the drain it landed in");
    expect(t.at(3).drain == drain_before + 1, "delivery carries the drain that ran it");
}

// ── 4. Immediate delivery ──────────────────────────────────────────────

fn check04Sync(h: *Harness) !void {
    const t = h.fresh();
    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });
    expectShape(t, &.{
        "dispatch_begin:t__alpha",
        "deliver:t__alpha:hooks/animation_hooks",
        "deliver:t__alpha:hook_trace_fixtures/hooks/needs_hooks",
        "deliver:t__alpha:hook_trace_root_exe",
        "dispatch_end:t__alpha",
    }, "emitSync delivers with NO enqueue and NO drain records");
    expect(t.at(0).source == .emit_sync, "…attributed to emitSync");
    expectEqU64(0, h.game.event_buffer.items.len, "…and never touched the buffer");
}

// ── 5. The engine's own closed payload ─────────────────────────────────

fn check05Hook(h: *Harness) !void {
    const t = h.fresh();
    h.game.emitHook(.{ .frame_start = .{ .frame_number = 7, .dt = 0.016 } });
    expectShape(t, &.{
        "dispatch_begin:frame_start",
        "deliver:frame_start:hooks/animation_hooks",
        "dispatch_end:frame_start",
    }, "emitHook traces the closed HookPayload path");
    expect(t.at(0).source == .emit_hook, "…attributed to emitHook");
}

// ── 6. Handler-emitted → NEXT drain ────────────────────────────────────

fn check06NextDrain(h: *Harness) !void {
    const t = h.fresh();
    const d0 = t.drain_seq;
    h.game.emit(.{ .t__chain_src = .{ .depth = 0 } });
    h.game.dispatchEvents();

    // The handler's own emit lands AFTER its `deliver` record and
    // carries the CURRENT drain number — it is not in this drain.
    expectShape(t, &.{
        "enqueue:t__chain_src",
        "drain_begin:",
        "dispatch_begin:t__chain_src",
        "deliver:t__chain_src:hooks/animation_hooks",
        "enqueue:t__chain_dst",
        "dispatch_end:t__chain_src",
        "drain_end:",
    }, "a handler-emitted event is traced inside the delivering drain but not delivered by it");
    expectEqU64(d0 + 1, t.at(4).drain, "the handler's enqueue is stamped with the running drain");

    _ = h.fresh();
    h.game.dispatchEvents();
    expectShape(t, &.{
        "drain_begin:",
        "dispatch_begin:t__chain_dst",
        "deliver:t__chain_dst:hooks/animation_hooks",
        "deliver:t__chain_dst:hook_trace_fixtures/hooks/needs_hooks",
        "dispatch_end:t__chain_dst",
        "drain_end:",
    }, "…and delivered by the NEXT drain");
    expectEqU64(d0 + 2, t.at(2).drain, "…under the next drain's number");
}

// ── 7. Consumable: where propagation stopped ───────────────────────────

fn check07Consumable(h: *Harness) !void {
    h.needs.claims = true;
    const t = h.fresh();
    h.game.emitSync(.{ .t__claim = .{ .seq = 1 } });

    expectShape(t, &.{
        "dispatch_begin:t__claim",
        "deliver:t__claim:hooks/animation_hooks",
        "deliver:t__claim:hook_trace_fixtures/hooks/needs_hooks",
        "consumed:t__claim:hook_trace_fixtures/hooks/needs_hooks",
        "dispatch_end:t__claim",
    }, "the trace names the receiver that consumed the event");
    expect(t.at(0).consumable, "the variant is marked consumable");
    expect(t.at(4).count == 2, "only two handlers ran");
    expect(findDeliver(t, "hook_trace_root_exe") == null, "the receiver after the claim never ran");
    expect(h.order.matches(&.{ "anim:claim", "needs:claim" }), "and the handlers agree");

    // With nobody claiming, propagation reaches the tail and there is no
    // `consumed` record at all.
    h.needs.claims = false;
    const t2 = h.fresh();
    h.game.emitSync(.{ .t__claim = .{ .seq = 2 } });
    expectShape(t2, &.{
        "dispatch_begin:t__claim",
        "deliver:t__claim:hooks/animation_hooks",
        "deliver:t__claim:hook_trace_fixtures/hooks/needs_hooks",
        "deliver:t__claim:hook_trace_root_exe",
        "consumed:t__claim:hook_trace_root_exe",
        "dispatch_end:t__claim",
    }, "…and stops at the last receiver when the earlier ones decline");
}

// ── 8. Nobody is listening ─────────────────────────────────────────────

fn check08NoListener(h: *Harness) !void {
    const t = h.fresh();
    h.game.emitSync(.{ .t__quiet = .{ .seq = 1 } });
    expectShape(t, &.{
        "dispatch_begin:t__quiet",
        "dispatch_end:t__quiet",
    }, "an event with no declared handler traces an EMPTY fan-out");
    expect(t.at(1).count == 0, "…with an explicit zero handler count");
}

// ── 9. Receiver identity ───────────────────────────────────────────────

fn check09Identity(h: *Harness) !void {
    const t = h.fresh();
    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });

    const declared_rec = findDeliver(t, "hooks/animation_hooks").?;
    expect(declared_rec.receiver_id_kind == .declared, "a declared id is reported as declared");
    expectEqStr(
        "hook_trace_root_exe.AnimationHooks",
        declared_rec.receiver_type,
        "…and the raw Zig type name travels alongside it",
    );

    // The derivation reproduces assembler#723's id shape for a receiver
    // that lives in a subdirectory of the module root, which is what
    // every generated hook file is.
    const derived_rec = findDeliver(t, "hook_trace_fixtures/hooks/needs_hooks").?;
    expect(derived_rec.receiver_id_kind == .derived, "an underived receiver is reported as derived");
    expectEqStr(
        "hook_trace_fixtures.hooks.needs_hooks.NeedsHooks",
        derived_rec.receiver_type,
        "…derived from this type name",
    );

    // The degenerate case, asserted rather than hidden: a receiver
    // declared in the ROOT FILE derives the root file's own stem, which
    // is not a per-receiver id. Real generated hooks never live in
    // `main.zig`, but `labelle_receiver_id` is the fix when one does.
    const root_rec = findDeliver(t, "hook_trace_root_exe").?;
    expectEqStr(
        "hook_trace_root_exe.TailHooks",
        root_rec.receiver_type,
        "a root-file receiver derives the ROOT's stem, not its own name",
    );
    expect(root_rec.index == 2, "tuple position is recorded");
}

// ── 10. Filtering ──────────────────────────────────────────────────────

fn check10Filtering(h: *Harness) !void {
    var t = h.fresh();

    t.events.include = &.{"t__alpha"};
    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });
    h.game.emitSync(.{ .t__quiet = .{ .seq = 2 } });
    expect(t.count() == 5, "an event include-filter admits only the named event");
    for (0..t.count()) |i| {
        expectEqStr("t__alpha", t.at(i).event, "…and nothing else got through");
    }
    t.events = .{};

    // Prefix form.
    t = h.fresh();
    t.events.include = &.{"t__q*"};
    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });
    h.game.emitSync(.{ .t__quiet = .{ .seq = 2 } });
    expect(t.count() == 2, "a trailing '*' makes the pattern a prefix");
    t.events = .{};

    // Receiver filtering narrows the RECEIVER-scoped records only; the
    // dispatch bounds still frame them, and dispatch is untouched.
    t = h.fresh();
    t.receivers.include = &.{"hooks/*"};
    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });
    expectShape(t, &.{
        "dispatch_begin:t__alpha",
        "deliver:t__alpha:hooks/animation_hooks",
        "dispatch_end:t__alpha",
    }, "a receiver filter narrows delivery records but keeps the dispatch frame");
    expect(t.at(2).count == 3, "…and the handler count still reports every handler that RAN");
    expect(h.order.len == 3, "…because filtering never changes dispatch");
    t.receivers = .{};

    // Exclude wins over include.
    t = h.fresh();
    t.events.include = &.{"t__*"};
    t.events.exclude = &.{"t__alpha"};
    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });
    expect(t.count() == 0, "exclude beats include");
    t.events = .{};
}

// ── 11. The bound ──────────────────────────────────────────────────────

fn check11Bound() !void {
    var t: engine.HookTracer = .{};
    const cap = engine.HookTracer.capacity;

    for (0..cap + 10) |i| {
        t.push(.{ .phase = .enqueue, .event = "t__alpha", .count = @intCast(i) });
    }
    expectEqU64(cap, t.count(), "the ring never exceeds its capacity");
    expectEqU64(10, t.dropped, "…and reports exactly how many records it lost");
    expectEqU64(cap + 10, t.seq, "…while the sequence number stays honest");
    expectEqU64(10, t.at(0).count, "overwrite_oldest keeps the NEWEST window");
    expectEqU64(cap + 9, t.at(cap - 1).count, "…up to the last record pushed");

    var t2: engine.HookTracer = .{ .overflow = .drop_newest };
    for (0..cap + 10) |i| {
        t2.push(.{ .phase = .enqueue, .event = "t__alpha", .count = @intCast(i) });
    }
    expectEqU64(cap, t2.count(), "drop_newest also respects the bound");
    expectEqU64(10, t2.dropped, "…and counts the refusals");
    expectEqU64(0, t2.at(0).count, "…but keeps the OLDEST window");
}

// ── 12. A live sink ────────────────────────────────────────────────────

const SinkState = struct {
    seen: usize = 0,
    reenter: bool = false,
    tracer: ?*engine.HookTracer = null,
};

fn sinkFn(ctx: ?*anyopaque, rec: *const engine.HookTraceRecord) void {
    const st: *SinkState = @ptrCast(@alignCast(ctx.?));
    st.seen += 1;
    _ = rec;
    if (st.reenter) {
        // A misbehaving sink that pushes back into the tracer. The guard
        // must stop the recursion rather than blow the stack.
        st.tracer.?.push(.{ .phase = .enqueue, .event = "t__alpha" });
    }
}

fn check12Sink(h: *Harness) !void {
    var st: SinkState = .{};
    const t = h.fresh();
    st.tracer = t;
    t.sink = .{ .ctx = &st, .onRecord = sinkFn };
    defer t.sink = null;

    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });
    expectEqU64(5, st.seen, "the sink saw every admitted record");

    st.reenter = true;
    st.seen = 0;
    const before = t.dropped_reentrant;
    h.game.emitSync(.{ .t__alpha = .{ .seq = 2 } });
    expect(t.dropped_reentrant > before, "a re-entrant sink is detected and counted separately");
    expect(st.seen == 5, "…and is not itself called recursively");
    st.reenter = false;
}

// ── 13. Rendering ──────────────────────────────────────────────────────

var render_buf: [16 * 1024]u8 = undefined;

fn check13Rendering(h: *Harness) !void {
    const t = h.fresh();
    h.game.emitSync(.{ .t__alpha = .{ .seq = 1 } });

    var w = std.Io.Writer.fixed(&render_buf);
    try t.writeText(&w);
    const text = render_buf[0..w.end];
    expect(std.mem.indexOf(u8, text, "deliver") != null, "text output names the phase");
    expect(std.mem.indexOf(u8, text, "hooks/animation_hooks") != null, "…and the receiver id");
    expect(std.mem.indexOf(u8, text, "-- hook trace:") != null, "…and ends with the completeness summary");

    var w2 = std.Io.Writer.fixed(&render_buf);
    try t.writeJsonLines(&w2);
    const json = render_buf[0..w2.end];
    // Every line must parse, and the last one must be the summary.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, json, "\n"), '\n');
    var n: usize = 0;
    var last: []const u8 = "";
    while (lines.next()) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, h.game.allocator, line, .{}) catch {
            std.debug.print("hook_trace_root_exe: FAILED: unparseable JSONL line: {s}\n", .{line});
            failures += 1;
            continue;
        };
        parsed.deinit();
        n += 1;
        last = line;
    }
    expectEqU64(t.count() + 1, n, "JSONL emits one object per record plus a summary");
    expect(std.mem.indexOf(u8, last, "\"summary\"") != null, "…and the summary is last");
    expect(std.mem.indexOf(u8, json, "\"receiver\":\"hooks/animation_hooks\"") != null, "…carrying the receiver id");
    expect(std.mem.indexOf(u8, json, "\"receiver_id_kind\":\"declared\"") != null, "…and how that id was obtained");
}

// ── 14. PARITY with core's own dispatcher ──────────────────────────────

/// The engine walks the receiver tuple itself when tracing is on. That
/// walk must be indistinguishable from `labelle-core`'s `MergeHooks.emit`
/// — which is what an UNTRACED build calls. Driving both over the same
/// payloads and comparing the handler-order log is the proof; it is also
/// what would catch a future divergence in core's dispatch loop.
fn check14Parity(h: *Harness) !void {
    const payloads = [_]AllHookPayloads{
        .{ .t__alpha = .{ .seq = 1 } },
        .{ .t__claim = .{ .seq = 2 } },
        .{ .frame_start = .{ .frame_number = 1, .dt = 0.016 } },
        .{ .t__quiet = .{ .seq = 3 } },
        .{ .t__named = .{ .name = "x", .seq = 4 } },
    };

    inline for (.{ true, false }) |claims| {
        h.needs.claims = claims;

        // Traced walk, through the engine.
        _ = h.fresh();
        for (payloads) |p| h.game.emitHook(p);
        var traced = h.order;

        // Core's walk, straight into MergeHooks.emit.
        h.order.reset();
        for (payloads) |p| h.hooks.emit(p);
        const untraced = h.order;

        expect(
            traced.eql(&untraced),
            "the traced walk visits receivers exactly as core.MergeHooks.emit does",
        );
    }
    h.needs.claims = false;
}

// ── 15. Payload capture is doubly opt-in ───────────────────────────────

fn check15Payloads(h: *Harness) !void {
    var t = h.fresh();
    h.game.emitSync(.{ .t__named = .{ .name = "secret", .seq = 42 } });
    for (0..t.count()) |i| {
        expectEqU64(0, t.at(i).payload_len, "payload capture is OFF by default even with a budget");
    }

    t = h.fresh();
    t.capture_payloads = true;
    defer t.capture_payloads = false;
    h.game.emit(.{ .t__named = .{ .name = "secret", .seq = 42 } });
    h.game.dispatchEvents();

    var saw_scalar = false;
    for (0..t.count()) |i| {
        const p = t.at(i).payload();
        if (p.len == 0) continue;
        saw_scalar = true;
        expect(std.mem.indexOf(u8, p, "seq=42") != null, "scalar fields are rendered");
        expect(std.mem.indexOf(u8, p, "secret") == null, "a BORROWED slice is never dereferenced");
    }
    expect(saw_scalar, "…and something was rendered at all");
}
