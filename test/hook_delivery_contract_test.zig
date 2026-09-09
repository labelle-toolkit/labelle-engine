//! Executable specification of the hook / event DELIVERY CONTRACT
//! (#857, parent #854). Prose lives in `HOOK-DELIVERY-CONTRACT.md`; every
//! numbered guarantee there has at least one test here, and each test
//! names the guarantee it pins.
//!
//! These tests describe what the engine DOES today — they are not a
//! wish-list. Where current behaviour is surprising (the drain runs
//! BEFORE `g.tick` in every shipped backend template; `unloadCurrentScene`
//! DISCARDS queued events; a `[]const u8` payload field is borrowed, not
//! copied) the test asserts the surprising thing on purpose, so a future
//! change to it shows up as a failing test and a deliberate decision
//! rather than a silent behavioural drift.
//!
//! Nothing here calls `@setEvalBranchQuota` — the dispatcher's own quota
//! (`core.MergeHooks.emit`) is what has to carry the load. The scaling
//! half of that guarantee lives in `test/hook_dispatch_scaling_test.zig`.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const MockEcs = core.MockEcsBackend(u32);

// ── Shared trace ───────────────────────────────────────────────────────
//
// Receivers are distinct TYPES (that is what `MergeHooks` fans out over),
// so ordering assertions need one shared sink they all append to. Keep it
// free of two-parameter `pub fn`s: `MergeHooks`' comptime validation reads
// every `pub` declaration of a RECEIVER and rejects any two-param function
// that is not an event name. `Trace` is not a receiver, but the receivers
// below hold a `*Trace`, so the same discipline is applied throughout.

const Trace = struct {
    entries: [64][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *Trace, label: []const u8) void {
        if (self.len < self.entries.len) {
            self.entries[self.len] = label;
            self.len += 1;
        }
    }

    fn items(self: *const Trace) []const []const u8 {
        return self.entries[0..self.len];
    }
};

fn expectTrace(trace: *const Trace, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, trace.len);
    for (expected, trace.items()) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
}

// ── The event union under test ─────────────────────────────────────────

/// Consumable payload (RFC-PLUGIN-EVENTS O4): handlers return `bool` and
/// the dispatcher stops at the first `true`.
const ClaimPayload = struct {
    seq: u32 = 0,
    pub const consumable = true;
};

const DeliveryEvents = union(enum) {
    /// Plain notification, fanned out to every receiver that declares it.
    t__alpha: struct { seq: u32 = 0 },
    t__beta: struct { seq: u32 = 0 },
    /// Handler-emitted chain source / sink.
    t__chain_src: struct { depth: u32 = 0 },
    t__chain_dst: struct { depth: u32 = 0 },
    /// Slice-bearing payload — pins the BORROWED lifetime rule.
    t__borrowed: struct { name: []const u8 = "" },
    /// Consumable.
    t__claim: ClaimPayload,
    /// Nested `emitSync` source / sink — pins that a sync emit raised from
    /// INSIDE a running handler dispatches inline, before the outer
    /// receiver chain resumes.
    t__nest_src: struct { seq: u32 = 0 },
    t__nest_dst: struct { seq: u32 = 0 },
};

// The receivers reach the game to emit chained events. A file-scope
// pointer keeps them free of the `*anyopaque` cast dance (which is exactly
// what #855 is about) without introducing a type cycle — file-scope decls
// resolve in any order.
var chain_game: ?*DeliveryGame = null;

/// Receiver #1 — declares every variant.
const R1 = struct {
    trace: *Trace,
    last_alpha_seq: u32 = 0,
    last_borrowed: []const u8 = "",
    chain_depth_seen: u32 = 0,

    pub fn t__alpha(self: *R1, info: anytype) void {
        self.last_alpha_seq = info.seq;
        self.trace.push("r1:alpha");
    }
    pub fn t__beta(self: *R1, _: anytype) void {
        self.trace.push("r1:beta");
    }
    pub fn t__borrowed(self: *R1, info: anytype) void {
        self.last_borrowed = info.name;
        self.trace.push("r1:borrowed");
    }
    /// Emits a follow-up event from INSIDE a dispatch. Pins guarantee D3:
    /// the follow-up is NOT seen by the drain that is running.
    pub fn t__chain_src(self: *R1, info: anytype) void {
        self.chain_depth_seen = info.depth;
        self.trace.push("r1:chain_src");
        if (chain_game) |g| g.emit(.{ .t__chain_dst = .{ .depth = info.depth + 1 } });
    }
    pub fn t__chain_dst(self: *R1, _: anytype) void {
        self.trace.push("r1:chain_dst");
    }
    pub fn t__claim(self: *R1, _: anytype) bool {
        self.trace.push("r1:claim");
        return false; // declines — the next receiver gets a look
    }
    /// Raises a SYNC event from inside a running handler. If `emitSync`
    /// ever deferred or queued while a dispatch is in flight, the trace
    /// order below changes and this test fails.
    pub fn t__nest_src(self: *R1, _: anytype) void {
        self.trace.push("r1:nest_src");
        if (chain_game) |g| g.emitSync(.{ .t__nest_dst = .{ .seq = 1 } });
    }
    pub fn t__nest_dst(self: *R1, _: anytype) void {
        self.trace.push("r1:nest_dst");
    }
};

/// Receiver #2 — claims the consumable event.
const R2 = struct {
    trace: *Trace,

    pub fn t__alpha(self: *R2, _: anytype) void {
        self.trace.push("r2:alpha");
    }
    pub fn t__nest_src(self: *R2, _: anytype) void {
        self.trace.push("r2:nest_src");
    }
    pub fn t__nest_dst(self: *R2, _: anytype) void {
        self.trace.push("r2:nest_dst");
    }
    pub fn t__claim(self: *R2, _: anytype) bool {
        self.trace.push("r2:claim");
        return true; // claims — R3 must not run
    }
};

/// Receiver #3 — declares `t__alpha` and `t__claim` but must never see a
/// claimed event.
const R3 = struct {
    trace: *Trace,

    pub fn t__alpha(self: *R3, _: anytype) void {
        self.trace.push("r3:alpha");
    }
    pub fn t__nest_src(self: *R3, _: anytype) void {
        self.trace.push("r3:nest_src");
    }
    pub fn t__nest_dst(self: *R3, _: anytype) void {
        self.trace.push("r3:nest_dst");
    }
    pub fn t__claim(self: *R3, _: anytype) bool {
        self.trace.push("r3:claim");
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

/// The merged payload + multi-receiver dispatcher, wired exactly the way
/// the assembler wires a multi-plugin project: `MergeHookPayloads` over
/// the engine's closed `HookPayload` plus the project `GameEvents`, then
/// `MergeHooks` over the receiver tuple in generated (scanner-sort) order.
const DeliveryPayload = core.MergeHookPayloads(.{ engine.HookPayload(u32), DeliveryEvents });
const DeliveryHooks = core.MergeHooks(DeliveryPayload, .{ *R1, *R2, *R3 });

const DeliveryGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *DeliveryHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    DeliveryEvents,
);

/// One-call harness: build the game + the three receivers + the merged
/// dispatcher, and point the file-scope chain pointers at them.
const Harness = struct {
    game: DeliveryGame,
    hooks: DeliveryHooks,
    r1: R1,
    r2: R2,
    r3: R3,
    trace: Trace,

    fn wire(self: *Harness) void {
        self.trace = .{};
        self.r1 = .{ .trace = &self.trace };
        self.r2 = .{ .trace = &self.trace };
        self.r3 = .{ .trace = &self.trace };
        self.hooks = .{ .receivers = .{ &self.r1, &self.r2, &self.r3 } };
        self.game = DeliveryGame.init(testing.allocator);
        self.game.setHooks(&self.hooks);
        chain_game = &self.game;
    }

    fn unwire(self: *Harness) void {
        chain_game = null;
        self.game.deinit();
    }
};

// ══ D1 — nothing is delivered before the drain ════════════════════════

test "D1: a buffered emit delivers nothing until dispatchEvents runs" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });
    h.game.emit(.{ .t__beta = .{ .seq = 2 } });

    // Pre-drain: the buffer holds them, no handler has run.
    try testing.expectEqual(@as(usize, 2), h.game.event_buffer.items.len);
    try testing.expectEqual(@as(usize, 0), h.trace.len);

    h.game.dispatchEvents();

    // Post-drain: the buffer is empty and every handler has run.
    try testing.expectEqual(@as(usize, 0), h.game.event_buffer.items.len);
    try testing.expect(h.trace.len > 0);
}

// ══ D2 — FIFO within one drain, receiver-tuple order within one event ══

test "D2: buffered events drain FIFO; receivers fan out in tuple order" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });
    h.game.emit(.{ .t__beta = .{ .seq = 2 } });
    h.game.emit(.{ .t__alpha = .{ .seq = 3 } });
    h.game.dispatchEvents();

    // Event order is queue order (alpha, beta, alpha), and WITHIN each
    // event the receivers run in `MergeHooks` tuple order (R1, R2, R3).
    // `t__beta` is declared only by R1, so it contributes one entry.
    try expectTrace(&h.trace, &.{
        "r1:alpha", "r2:alpha", "r3:alpha",
        "r1:beta",  "r1:alpha", "r2:alpha",
        "r3:alpha",
    });
    // The LAST alpha wins the recorded payload — proof the two alphas are
    // distinct deliveries and not deduplicated.
    try testing.expectEqual(@as(u32, 3), h.r1.last_alpha_seq);
}

// ══ D3 — handler-emitted events land on the NEXT drain ════════════════

test "D3: an event emitted from a handler arrives on the NEXT drain" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__chain_src = .{ .depth = 0 } });
    h.game.dispatchEvents();

    // The chained `t__chain_dst` was emitted DURING this drain. It must
    // not have been delivered by it: `dispatchEvents` iterates a snapshot
    // swapped out of `event_buffer`, so the handler's emit lands in the
    // fresh buffer instead.
    try expectTrace(&h.trace, &.{"r1:chain_src"});
    try testing.expectEqual(@as(usize, 1), h.game.event_buffer.items.len);

    h.game.dispatchEvents();
    try expectTrace(&h.trace, &.{ "r1:chain_src", "r1:chain_dst" });
    try testing.expectEqual(@as(usize, 0), h.game.event_buffer.items.len);
}

test "D3: a chain of N handler-emitted events costs N drains" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    // `t__chain_dst`'s handler does NOT re-emit, so the chain is one hop
    // deep. Re-emitting the SOURCE gives an unbounded chain; drive it by
    // hand to show the per-drain step cost.
    var frame: u32 = 0;
    while (frame < 3) : (frame += 1) {
        h.game.emit(.{ .t__chain_src = .{ .depth = frame } });
        h.game.dispatchEvents();
    }
    // Drain 1: src(0).            Buffer: dst(1)
    // Drain 2: dst(1), src(1).    Buffer: dst(2)
    // Drain 3: dst(2), src(2).    Buffer: dst(3)  ← still undelivered
    try expectTrace(&h.trace, &.{
        "r1:chain_src",
        "r1:chain_dst",
        "r1:chain_src",
        "r1:chain_dst",
        "r1:chain_src",
    });
    try testing.expectEqual(@as(usize, 1), h.game.event_buffer.items.len);
}

// ══ D4 — emitSync jumps the queue ═════════════════════════════════════

test "D4: emitSync runs immediately, ahead of events queued before it" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__alpha = .{ .seq = 1 } }); // queued FIRST
    h.game.emitSync(.{ .t__beta = .{ .seq = 2 } }); // dispatched FIRST

    // `emitSync` does not drain the buffer first — beta has run, alpha
    // has not, even though alpha was queued earlier.
    try expectTrace(&h.trace, &.{"r1:beta"});
    try testing.expectEqual(@as(usize, 1), h.game.event_buffer.items.len);

    h.game.dispatchEvents();
    try expectTrace(&h.trace, &.{ "r1:beta", "r1:alpha", "r2:alpha", "r3:alpha" });
}

test "D4: emitSync fans out synchronously from the call site" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    // The sync path uses the SAME `MergeHooks.emit` fan-out, so receiver
    // order and the consumable rule hold identically.
    h.game.emitSync(.{ .t__alpha = .{ .seq = 7 } });
    try expectTrace(&h.trace, &.{ "r1:alpha", "r2:alpha", "r3:alpha" });
    try testing.expectEqual(@as(u32, 7), h.r1.last_alpha_seq);
    try testing.expectEqual(@as(usize, 0), h.game.event_buffer.items.len);
}

test "D4b: emitSync raised INSIDE a handler nests before the outer chain resumes" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    // D4 above only proves fan-out from the test body. This drives the
    // case the guarantee is actually about: R1's handler calls `emitSync`
    // WHILE the outer dispatch is still walking receivers.
    h.game.emit(.{ .t__nest_src = .{ .seq = 1 } });
    h.game.dispatchEvents();

    // The nested event runs to completion across ALL receivers before the
    // outer `nest_src` chain continues to R2 and R3. A regression that
    // queued the nested emit instead would trace
    //   r1:nest_src, r2:nest_src, r3:nest_src, (…next drain…) r*:nest_dst
    // and fail here.
    try expectTrace(&h.trace, &.{
        "r1:nest_src",
        "r1:nest_dst", "r2:nest_dst", "r3:nest_dst",
        "r2:nest_src", "r3:nest_src",
    });

    // Nothing was left queued: the nested emit never touched the buffer.
    try testing.expectEqual(@as(usize, 0), h.game.event_buffer.items.len);
}

// ══ D5 — consumable events stop at the first claim ════════════════════

test "D5: a consumable event stops at the first receiver returning true" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__claim = .{ .seq = 1 } });
    h.game.dispatchEvents();

    // R1 declines (false) → R2 claims (true) → R3 is never called.
    try expectTrace(&h.trace, &.{ "r1:claim", "r2:claim" });
}

test "D5: a notification event ignores handler return values" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    // `t__alpha`'s payload declares no `consumable`, so the dispatcher
    // takes the fan-out path and every receiver runs.
    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });
    h.game.dispatchEvents();
    try expectTrace(&h.trace, &.{ "r1:alpha", "r2:alpha", "r3:alpha" });
}

// ══ D6 — payload ownership: value-copied, slices BORROWED ═════════════

test "D6: the payload is copied by value at emit time" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    var seq: u32 = 10;
    h.game.emit(.{ .t__alpha = .{ .seq = seq } });
    seq = 999; // mutating the source after the emit changes nothing
    h.game.dispatchEvents();

    try testing.expectEqual(@as(u32, 10), h.r1.last_alpha_seq);
}

test "D6: a []const u8 payload field is BORROWED — the copy is shallow" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    // This is the trap the contract exists to name. `emit` copies the
    // payload STRUCT into the buffer; the struct's slice field copies the
    // (ptr, len) pair, NOT the bytes. Mutating the referent between emit
    // and drain is therefore observable in the handler.
    var name_buf: [5]u8 = "first".*;
    h.game.emit(.{ .t__borrowed = .{ .name = &name_buf } });
    @memcpy(&name_buf, "AFTER");
    h.game.dispatchEvents();

    // The handler saw the MUTATED bytes: value-copying an event is not
    // deep-copying its data. A caller whose backing storage dies before
    // the drain hands the handler a dangling slice.
    try testing.expectEqualStrings("AFTER", h.r1.last_borrowed);
}

test "D6: the safe pattern — storage that outlives the drain" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    // Program-lifetime storage (a string literal, a comptime table, an
    // arena that outlives the frame) is always safe to borrow.
    const stable: []const u8 = "program-lifetime";
    h.game.emit(.{ .t__borrowed = .{ .name = stable } });
    h.game.dispatchEvents();
    try testing.expectEqualStrings("program-lifetime", h.r1.last_borrowed);
    // And the handler's copy stays valid after the drain, because the
    // referent is not owned by the event machinery at all.
    try testing.expectEqualStrings("program-lifetime", h.r1.last_borrowed);
}

// ══ D7 — scene reset DISCARDS the queue ═══════════════════════════════

test "D7: a scene swap discards the outgoing scene's queued events" {
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });
    h.game.emit(.{ .t__beta = .{ .seq = 2 } });
    try testing.expectEqual(@as(usize, 2), h.game.event_buffer.items.len);

    // The DISCARD is unchanged and still by design: the outgoing scene's
    // entities are about to be destroyed, so its queued events reference
    // ids that will be dead by the drain.
    //
    // What changed in #864 is WHO does it. The clear used to be
    // `unloadCurrentScene`'s first statement, which also discarded the
    // `engine__scene_assets_acquire` / `engine__scene_before_reset` emitted
    // moments earlier to ANNOUNCE the transition — so no subscriber could
    // ever see them. It is now `clearPendingSceneEvents`, which the scene
    // paths call BEFORE announcing, so the announcements survive to the
    // drain while the outgoing scene's own events still do not.
    h.game.clearPendingSceneEvents();
    h.game.unloadCurrentScene();
    try testing.expectEqual(@as(usize, 0), h.game.event_buffer.items.len);

    h.game.dispatchEvents();
    try testing.expectEqual(@as(usize, 0), h.trace.len);
}

test "D7b: unloadCurrentScene alone no longer clears the queue (#864)" {
    // The other half of the split, pinned explicitly so the two cannot
    // drift back together. Teardown does not silently eat the buffer;
    // discarding is now an explicit decision at the call site.
    var h: Harness = undefined;
    h.wire();
    defer h.unwire();

    h.game.emit(.{ .t__alpha = .{ .seq = 1 } });
    try testing.expectEqual(@as(usize, 1), h.game.event_buffer.items.len);

    h.game.unloadCurrentScene();
    try testing.expect(h.game.event_buffer.items.len >= 1);
}

// ══ D8 — shutdown flushes exactly once ════════════════════════════════

const ShutdownRecorder = struct {
    trace: *Trace,

    pub fn t__alpha(self: *ShutdownRecorder, _: anytype) void {
        self.trace.push("alpha");
        // Emitted from a shutdown-time handler: `Game.deinit` drains
        // once and then tears the buffer down, so this never lands.
        if (shutdown_game) |g| g.emit(.{ .t__beta = .{} });
    }
    pub fn t__beta(self: *ShutdownRecorder, _: anytype) void {
        self.trace.push("beta");
    }
};

var shutdown_game: ?*ShutdownGame = null;

const ShutdownGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *ShutdownRecorder,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    DeliveryEvents,
);

test "D8: Game.deinit flushes the queue once; a handler's own emit is dropped" {
    var trace = Trace{};
    var recorder = ShutdownRecorder{ .trace = &trace };
    var game = ShutdownGame.init(testing.allocator);
    game.setHooks(&recorder);
    shutdown_game = &game;
    defer shutdown_game = null;

    game.emit(.{ .t__alpha = .{ .seq = 1 } });
    // Not drained yet — deinit is the last drain point.
    try testing.expectEqual(@as(usize, 0), trace.len);

    game.deinit();

    // The pending alpha WAS delivered by deinit's drain…
    try expectTrace(&trace, &.{"alpha"});
    // …but the beta that handler emitted was not: there is no next drain.
}

// ══ D9 — the generated frame shape: the drain precedes `g.tick` ═══════
//
// Every shipped backend template (raylib/sokol/bgfx desktop, mobile, wasm,
// null headless) emits `{{tick_code}}` — which ENDS in `g.dispatchEvents()`
// — immediately BEFORE `g.tick(dt)`. Verified against a real generated
// main (`flying-platform-labelle/.labelle/bgfx_desktop/main.zig`):
//
//     if (scaled_dt > 0) { runner.tick(...); PluginSystems.tick/postTick }
//     g.dispatchEvents();      ← THE DRAIN
//     g.tick(dt);              ← engine lifecycle events emitted HERE
//     window.beginFrame(); g.render(); ...
//
// Consequence: anything the ENGINE emits inside `tick` (engine__tick,
// engine__post_tick, the input-event scan, entity_created from a spawn) is
// delivered by the drain of the NEXT loop iteration — one frame of latency.
// Anything a SCRIPT or PLUGIN emits during its own tick is delivered later
// in the SAME iteration.

const LoopEvents = union(enum) {
    engine__tick: engine.Events.tick,
    engine__post_tick: engine.Events.post_tick,
    script__ping: struct { iteration: u32 = 0 },
};

/// The loop iteration currently executing, stamped by the harness below so
/// a handler can record WHEN it was called relative to WHEN it was emitted.
var loop_iteration: u32 = 0;

const LoopRecorder = struct {
    /// (emitted frame_number, delivered-in iteration) pairs.
    tick_delivery: [8]struct { frame: u64, iter: u32 } = undefined,
    tick_len: usize = 0,
    ping_delivery: [8]struct { emitted: u32, iter: u32 } = undefined,
    ping_len: usize = 0,

    pub fn engine__tick(self: *LoopRecorder, info: anytype) void {
        if (self.tick_len < self.tick_delivery.len) {
            self.tick_delivery[self.tick_len] = .{ .frame = info.frame_number, .iter = loop_iteration };
            self.tick_len += 1;
        }
    }
    pub fn engine__post_tick(_: *LoopRecorder, _: anytype) void {}
    pub fn script__ping(self: *LoopRecorder, info: anytype) void {
        if (self.ping_len < self.ping_delivery.len) {
            self.ping_delivery[self.ping_len] = .{ .emitted = info.iteration, .iter = loop_iteration };
            self.ping_len += 1;
        }
    }
};

const LoopGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *LoopRecorder,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    LoopEvents,
);

/// One iteration of the generated main loop, in the order the templates
/// emit it. Keep this shape in lockstep with
/// `labelle-assembler/src/codegen/lifecycle/render.zig` (`tick_code`).
fn generatedLoopIteration(g: *LoopGame, dt: f32) void {
    // 1. scripts + plugin systems tick (they emit here)
    g.emit(.{ .script__ping = .{ .iteration = loop_iteration } });
    // 2. the drain
    g.dispatchEvents();
    // 3. the engine tick (engine lifecycle events are emitted here)
    g.tick(dt);
    // 4. render — no dispatch point
}

test "D9: a script's emit lands in the SAME iteration's drain" {
    var recorder = LoopRecorder{};
    var game = LoopGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    loop_iteration = 0;
    while (loop_iteration < 3) : (loop_iteration += 1) {
        generatedLoopIteration(&game, 0.016);
    }

    try testing.expectEqual(@as(usize, 3), recorder.ping_len);
    for (recorder.ping_delivery[0..recorder.ping_len]) |d| {
        try testing.expectEqual(d.emitted, d.iter);
    }
}

test "D9: an engine lifecycle event emitted in tick lands one iteration LATER" {
    var recorder = LoopRecorder{};
    var game = LoopGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    loop_iteration = 0;
    while (loop_iteration < 4) : (loop_iteration += 1) {
        generatedLoopIteration(&game, 0.016);
    }

    // `g.tick` runs AFTER the drain, so frame N's `engine__tick` waits for
    // iteration N+1's drain. Frame numbers start at 0 and the last frame's
    // event is still sitting in the buffer when the loop exits.
    try testing.expectEqual(@as(usize, 3), recorder.tick_len);
    for (recorder.tick_delivery[0..recorder.tick_len]) |d| {
        try testing.expectEqual(d.frame + 1, @as(u64, d.iter));
    }
    // The 4th frame's tick event is queued, undelivered.
    try testing.expectEqual(@as(usize, 2), game.event_buffer.items.len); // tick + post_tick
}

// ══ D10 — lifecycle caveat: ready callbacks are not transactional ═════

/// Counts `onReady` invocations across a whole scene load.
var d10_ready_calls: u32 = 0;

const ReadyMarker = struct {
    _tag: u8 = 0,

    pub fn onReady(payload: engine.ComponentPayload) void {
        _ = payload;
        d10_ready_calls += 1;
    }
};

const D10Components = engine.ComponentRegistry(.{ .ReadyMarker = ReadyMarker });
const D10Bridge = engine.JsoncSceneBridge(engine.Game, D10Components);

fn d10TmpPath(tmp_dir: *std.testing.TmpDir, sub: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ buf[0..len], sub });
}

test "D10: onReady of an EARLIER entity has already run when a LATER one fails the load (#805)" {
    // Scene loading is INCREMENTAL, not transactional. `fireOnReadyAll`
    // runs the moment an entity's components are applied — before later
    // siblings get a chance to fail. When entity #2 is rejected, entity
    // #1's `onReady`/`postLoad` have already run; the `errdefer` teardown
    // removes the ECS tree but cannot undo external side effects those
    // hooks caused.
    //
    // There is therefore NO implicit "the whole scene loaded or nothing
    // happened" guarantee, and none is being added here: #805 records the
    // stance that a stronger guarantee would need a validate-only
    // pre-pass, not hook reordering (which would break the #561 hook-order
    // contract). This test pins the CURRENT behaviour so a future change
    // is a deliberate decision. Refs #805, #802, #801, #561.
    d10_ready_calls = 0;

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    // The rejection is intentional and logs at error level; keep the
    // suite output clean.
    const prev_log = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    const prefab_path = try d10TmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    // Entity #1 is valid and carries an `onReady` component. Entity #2
    // pairs a prefab reference with a legacy `components` key, which the
    // unified-format loader rejects.
    const result = D10Bridge.loadSceneFromSource(&game,
        \\{
        \\  "children": [
        \\    { "components": { "ReadyMarker": {} } },
        \\    { "prefab": "missing_prefab", "components": { "ReadyMarker": {} } }
        \\  ]
        \\}
    , prefab_path);

    // The load aborted…
    try testing.expectError(error.InvalidFormat, result);
    // …but entity #1's `onReady` had already fired. That is the caveat.
    try testing.expectEqual(@as(u32, 1), d10_ready_calls);
}
