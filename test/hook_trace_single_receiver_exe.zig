//! Consumable tracing on the SINGLE-receiver dispatch path (#858).
//!
//! `walkMerged` checks a consumable handler's return and records
//! `Phase.consumed` where propagation stopped. `walkSingle` — the path a
//! game whose `GameConfig` takes one receiver DIRECTLY (no `MergeHooks`)
//! goes through — discarded the return, so it never produced a `.consumed`
//! record at all. A consumable event that WAS handled looked identical in
//! the trace to one that was ignored, on the very field a reader uses to
//! explain why propagation stopped (#865 review).
//!
//! The two controls are the point. Recording `.consumed` for a handler
//! that returned TRUE proves the record appears; recording NOTHING for one
//! that returned FALSE proves it is the return value driving it and not
//! merely "a consumable event was delivered". One without the other would
//! pass on an implementation that always emitted the record.
//!
//! Executable, not `zig test`: tracing is read from the compilation ROOT,
//! and a test binary's root is Zig's own test runner.
//!
//! Prints `PROBE_RESULT:` and sets the exit code:
//!   0 = SINGLE_CONSUMED_OK
//!   4 = MISSING_CONSUMED        (true handler produced no record — the bug)
//!   5 = SPURIOUS_CONSUMED       (false handler produced one)
//!   6 = DELIVER_MISSING         (nothing dispatched at all — vacuous run)

const std = @import("std");
const engine = @import("engine");

const core = engine.core;
const Entity = core.MockEcsBackend(u32).Entity;

pub const labelle_hook_trace: engine.HookTraceOptions = .{ .ring_capacity = 32 };

/// A consumable payload: `pub const consumable = true` is what puts the
/// dispatcher on the return-aware path.
const ClaimPayload = struct {
    seq: u32 = 0,
    pub const consumable = true;
};

const SingleEvents = union(enum) {
    t__claim: ClaimPayload,
};

const Components = engine.ComponentRegistry(.{ .Marker = struct { on: bool = false } });

/// THE single receiver — handed to `GameConfig` directly, so dispatch goes
/// through `walkSingle` rather than `walkMerged`.
const SoloHooks = struct {
    /// Flipped by the harness between the two controls.
    claim_it: bool = false,
    calls: u32 = 0,

    pub fn t__claim(self: *SoloHooks, _: anytype) bool {
        self.calls += 1;
        return self.claim_it;
    }
};

const AllHookPayloads = engine.MergeHookPayloads(.{
    engine.HookPayload(Entity),
    SingleEvents,
});

pub const Game = engine.GameConfig(
    core.StubRender(Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *SoloHooks,
    core.StubLogSink,
    Components,
    &.{},
    SingleEvents,
);

fn countPhase(t: *const engine.HookTracer, phase: anytype) u32 {
    var n: u32 = 0;
    for (0..t.count()) |i| {
        if (t.at(i).phase == phase) n += 1;
    }
    return n;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var solo: SoloHooks = .{};
    var game = Game.init(allocator);
    defer game.deinit();
    game.setHooks(&solo);

    // ── Control A: the handler CLAIMS the event ─────────────────────────
    solo.claim_it = true;
    game.hook_tracer.clear();
    game.emit(.{ .t__claim = .{ .seq = 1 } });
    game.dispatchEvents();

    const delivers_true = countPhase(&game.hook_tracer, .deliver);
    const consumed_true = countPhase(&game.hook_tracer, .consumed);
    std.debug.print(
        "PROBE: returned true  -> deliver={d} consumed={d} calls={d}\n",
        .{ delivers_true, consumed_true, solo.calls },
    );

    if (delivers_true == 0) {
        std.debug.print("PROBE_RESULT: DELIVER_MISSING (nothing dispatched)\n", .{});
        std.process.exit(6);
    }
    if (consumed_true == 0) {
        std.debug.print(
            "PROBE_RESULT: MISSING_CONSUMED (a consumable handler returned true and " ++
                "the trace does not say so)\n",
            .{},
        );
        std.process.exit(4);
    }

    // ── Control B: the handler DECLINES ─────────────────────────────────
    solo.claim_it = false;
    solo.calls = 0;
    game.hook_tracer.clear();
    game.emit(.{ .t__claim = .{ .seq = 2 } });
    game.dispatchEvents();

    const delivers_false = countPhase(&game.hook_tracer, .deliver);
    const consumed_false = countPhase(&game.hook_tracer, .consumed);
    std.debug.print(
        "PROBE: returned false -> deliver={d} consumed={d} calls={d}\n",
        .{ delivers_false, consumed_false, solo.calls },
    );

    if (delivers_false == 0) {
        std.debug.print("PROBE_RESULT: DELIVER_MISSING (nothing dispatched)\n", .{});
        std.process.exit(6);
    }
    if (consumed_false != 0) {
        std.debug.print(
            "PROBE_RESULT: SPURIOUS_CONSUMED (a handler returned false and the trace " ++
                "claims the event was consumed)\n",
            .{},
        );
        std.process.exit(5);
    }

    std.debug.print("PROBE_RESULT: SINGLE_CONSUMED_OK\n", .{});
}
