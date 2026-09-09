//! The SINGLE-receiver dispatch path validates the table too (#727/#866).
//!
//! `walkMerged` compile-fails when the generated `hook_receiver_ids` table
//! disagrees in length with the hook tuple. `walkSingle` — the path a game
//! whose `GameConfig` takes one receiver directly (no `MergeHooks`) goes
//! through — did not. So a single-receiver game shipped with a stale
//! two-entry table built happily and labelled its one receiver from slot 0
//! of a table that no longer described it, which is precisely the silent
//! mislabelling the compile-time check exists to prevent (#866 review).
//!
//! Both walks now call the same `assertTableAligned` helper. One helper
//! rather than two inline checks is deliberate: the gap existed because
//! the rule was written in one place and not the other.
//!
//! This harness is the VALID case — exactly one receiver, exactly one
//! table entry — proving the guard admits the correct shape and that the
//! id still comes from the table on this path. The rejection cases (zero
//! or two entries against one receiver) are compile failures, so they
//! cannot be expressed as a passing test in the same binary; they are
//! verified by construction against this file.

const std = @import("std");
const engine = @import("engine");

const core = engine.core;
const Entity = core.MockEcsBackend(u32).Entity;

pub const labelle_hook_trace: engine.HookTraceOptions = .{ .ring_capacity = 16 };

/// ONE entry, matching the single-receiver tuple below.
pub const hook_receiver_ids = [_][]const u8{"packs/solo/hooks/only_hooks"};

const SoloEvents = union(enum) {
    t__solo: struct { n: u32 = 0 },
};

const EmptyComponents = struct {};

/// Declares an id that DISAGREES with the table, so "the table won" is
/// observable rather than a coincidence of spelling.
const OnlyHooks = struct {
    pub const labelle_receiver_id = "hooks/not_the_table_value";
    hits: u32 = 0,
    pub fn t__solo(self: *OnlyHooks, _: anytype) void {
        self.hits += 1;
    }
};

const AllHookPayloads = engine.MergeHookPayloads(.{
    engine.HookPayload(Entity),
    SoloEvents,
});

/// The single-receiver shape: the receiver type itself, NOT a
/// `MergeHooks` tuple. This is what routes dispatch through `walkSingle`.
pub const Game = engine.GameConfig(
    core.StubRender(Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *OnlyHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    SoloEvents,
);

var failures: usize = 0;

fn expect(ok: bool, what: []const u8) void {
    if (ok) return;
    failures += 1;
    std.debug.print("hook_trace_single_receiver_table_exe: FAILED: {s}\n", .{what});
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var only: OnlyHooks = .{};
    var game = Game.init(allocator);
    defer game.deinit();
    game.setHooks(&only);
    game.hook_tracer.clear();

    game.emit(.{ .t__solo = .{ .n = 1 } });
    game.dispatchEvents();

    expect(only.hits == 1, "the single receiver ran");

    const t = &game.hook_tracer;
    var found = false;
    for (0..t.count()) |i| {
        const r = t.at(i);
        if (r.phase != .deliver) continue;
        found = true;
        expect(
            std.mem.eql(u8, r.receiver, "packs/solo/hooks/only_hooks"),
            "the single-receiver path labels from the TABLE",
        );
        expect(r.receiver_id_kind == .table, "…and reports the table kind");
        expect(
            !std.mem.eql(u8, r.receiver, OnlyHooks.labelle_receiver_id),
            "the table wins over a disagreeing declared id here too",
        );
        expect(r.index == 0, "the single receiver is tuple slot 0");
    }
    expect(found, "a deliver record was produced");

    if (failures != 0) {
        std.debug.print("hook_trace_single_receiver_table_exe: {d} failure(s)\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("hook_trace_single_receiver_table_exe: OK\n", .{});
}
