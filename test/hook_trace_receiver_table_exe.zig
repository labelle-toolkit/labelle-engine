//! The generated receiver-id table is what labels trace records
//! (labelle-assembler#727).
//!
//! #723 resolves a receiver's id; #724 prints it in the route inspector;
//! #858's tracer labels dispatch frames. Before this, the tracer derived
//! its own id from `@typeName` and the inspector printed the assembler's,
//! so the two agreed only by coincidence of derivation — nothing kept
//! them in step, and a layout the derivation got wrong would have the
//! same receiver appearing under two names in two tools.
//!
//! #727 has the assembler emit `hook_receiver_ids`, index-aligned with
//! the `GameHooks` tuple. This harness is the consumer proof: its root
//! declares such a table and the checks below verify the tracer READS it
//! rather than deriving.
//!
//! The table entries here are deliberately UNLIKE both the derived and
//! the declared ids. If the tracer ignored the table and fell back, every
//! id check below would fail — which is what makes this a proof of the
//! table path rather than a test that two spellings happen to match.
//!
//! Executable, not `zig test`: both `labelle_hook_trace` and
//! `hook_receiver_ids` are read from the COMPILATION ROOT, and a test
//! binary's root is Zig's own test runner.

const std = @import("std");
const engine = @import("engine");

const core = engine.core;
const Entity = core.MockEcsBackend(u32).Entity;

pub const labelle_hook_trace: engine.HookTraceOptions = .{ .ring_capacity = 32 };

/// THE TABLE — what an assembler-generated `main.zig` emits (#727).
/// Index-aligned with the `GameHooks` tuple below.
///
/// None of these strings is reachable by derivation from the receiver
/// type names, and the first one contradicts a `labelle_receiver_id`
/// decl, so each check below can only pass by actually reading this.
pub const hook_receiver_ids = [_][]const u8{
    "packs/alpha/hooks/first_hooks",
    "packs/beta/hooks/second_hooks",
};

const TableEvents = union(enum) {
    t__ping: struct { seq: u32 = 0 },
};

const EmptyComponents = struct {};

/// Declares an id AND appears in the table, with the two disagreeing.
/// The table must win: it is the one aligned with dispatch order.
const FirstHooks = struct {
    pub const labelle_receiver_id = "hooks/declared_but_not_the_table";
    hits: u32 = 0,
    pub fn t__ping(self: *FirstHooks, _: anytype) void {
        self.hits += 1;
    }
};

/// Declares nothing — without the table this would be DERIVED from
/// `@typeName`, which for this file-scope type is not a pack path.
const SecondHooks = struct {
    hits: u32 = 0,
    pub fn t__ping(self: *SecondHooks, _: anytype) void {
        self.hits += 1;
    }
};

const AllHookPayloads = engine.MergeHookPayloads(.{
    engine.HookPayload(Entity),
    TableEvents,
});
const AllHooks = engine.MergeHooks(AllHookPayloads, .{ *FirstHooks, *SecondHooks });

pub const Game = engine.GameConfig(
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
    TableEvents,
);

var failures: usize = 0;

fn expect(ok: bool, what: []const u8) void {
    if (ok) return;
    failures += 1;
    std.debug.print("hook_trace_receiver_table_exe: FAILED: {s}\n", .{what});
}

fn expectEqStr(want: []const u8, got: []const u8, what: []const u8) void {
    if (std.mem.eql(u8, want, got)) return;
    failures += 1;
    std.debug.print(
        "hook_trace_receiver_table_exe: FAILED: {s}\n  want: {s}\n  got:  {s}\n",
        .{ what, want, got },
    );
}

/// The deliver record at tuple slot `index`, or null.
fn deliverAt(t: *const engine.HookTracer, index: u16) ?*const engine.HookTraceRecord {
    for (0..t.count()) |i| {
        const r = t.at(i);
        if (r.phase == .deliver and r.index == index) return r;
    }
    return null;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The table is visible to the engine at comptime.
    expect(engine.hook_trace.receiver_id_table != null, "the engine sees the root's table");
    if (engine.hook_trace.receiver_id_table) |tbl| {
        expect(tbl.len == 2, "the table has both entries");
    }

    var first: FirstHooks = .{};
    var second: SecondHooks = .{};
    var hooks: AllHooks = .{ .receivers = .{ &first, &second } };

    var game = Game.init(allocator);
    defer game.deinit();
    game.setHooks(&hooks);
    // `setHooks` traces its own game_init fan-out; start from a clean ring
    // so the checks below read only the dispatch under test.
    game.hook_tracer.clear();

    game.emit(.{ .t__ping = .{ .seq = 1 } });
    game.dispatchEvents();

    expect(first.hits == 1, "the first receiver ran");
    expect(second.hits == 1, "the second receiver ran");

    const t = &game.hook_tracer;

    // 1 — slot 0: the table BEATS a declared id that disagrees.
    if (deliverAt(t, 0)) |r| {
        expectEqStr("packs/alpha/hooks/first_hooks", r.receiver, "slot 0 is labelled from the table");
        expect(r.receiver_id_kind == .table, "slot 0 reports its id came from the table");
        expect(
            !std.mem.eql(u8, r.receiver, FirstHooks.labelle_receiver_id),
            "the table wins over a disagreeing labelle_receiver_id",
        );
        // The raw truth is never lost, whichever id won.
        expect(
            std.mem.indexOf(u8, r.receiver_type, "FirstHooks") != null,
            "slot 0 still carries the receiver's real @typeName",
        );
    } else expect(false, "slot 0 produced a deliver record");

    // 2 — slot 1: the table BEATS the @typeName derivation.
    if (deliverAt(t, 1)) |r| {
        expectEqStr("packs/beta/hooks/second_hooks", r.receiver, "slot 1 is labelled from the table");
        expect(r.receiver_id_kind == .table, "slot 1 reports its id came from the table");
        expect(
            std.mem.indexOf(u8, r.receiver, "SecondHooks") == null,
            "the table wins over the @typeName derivation",
        );
    } else expect(false, "slot 1 produced a deliver record");

    // 3 — the rendered trace says HOW the id was obtained, so a reader can
    //     tell a contract from a guess.
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.writeJsonLines(&w);
    const json = w.buffered();
    expect(
        std.mem.indexOf(u8, json, "\"receiver_id_kind\":\"table\"") != null,
        "the JSON rendering reports the table kind",
    );
    expect(
        std.mem.indexOf(u8, json, "packs/alpha/hooks/first_hooks") != null,
        "the JSON rendering carries the table id",
    );

    if (failures != 0) {
        std.debug.print("hook_trace_receiver_table_exe: {d} failure(s)\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("hook_trace_receiver_table_exe: OK\n", .{});
}
