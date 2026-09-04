//! Hard-deadline harness for the BLOCKING asset-load shims
//! (`loadImageIfNeeded`, `loadAtlasIfNeeded`, …).
//!
//! Extracted from `image_load_shim_test.zig` (#832) when the atlas
//! deadlock test needed the same guarantee (#833). One harness, because
//! two copies of a wait loop is the bug this issue is about and two
//! copies of its test harness would be the same mistake one level up.
//!
//! ## Why the deadline kills the process
//!
//! Two bots flagged the original shape of these timeouts: they `join()`ed
//! the worker unconditionally, so a loader that regressed into an unbounded
//! spin HUNG CI instead of failing at the deadline. A test that cannot fail
//! is worse than no test, so the deadline is real.
//!
//! There is no SAFE in-process recovery from a wedged loader. The worker
//! thread owns the `*Game`: joining it waits forever by construction, and
//! returning without joining lets the caller's `defer game.deinit()` free
//! the catalog out from under a thread that is still pumping it (and leaves
//! `testing.allocator`'s leak check racing a live thread). Full process
//! isolation — fork a child, watchdog it, reap it — is the textbook answer
//! and is out of proportion to a regression guard in a unit-test binary.
//!
//! So the deadline is enforced by killing the process: print exactly which
//! call wedged, then `abort()`. CI fails LOUDLY at 200 ms with a named
//! regression instead of stalling until the job timeout. Nothing but a
//! genuine regression can reach that branch.

const std = @import("std");
const testing = std.testing;

pub const Outcome = union(enum) {
    ok: bool,
    err: anyerror,
};

pub const deadline_ns: u64 = 200 * std.time.ns_per_ms;

/// Call `Game.<method>(game, name)` on a worker thread under a hard
/// deadline. Returns its outcome, or aborts the process if it does not
/// return in time.
///
/// `method` is a decl name rather than a function value so the abort
/// message can NAME the wedged call, and so each test file can point the
/// harness at its own shim (`"loadImageIfNeeded"`, `"loadAtlasIfNeeded"`)
/// without the harness knowing anything about either `Game` type.
pub fn callWithDeadline(
    comptime Game: type,
    comptime method: []const u8,
    game: *Game,
    name: []const u8,
) Outcome {
    const Runner = struct {
        outcome: Outcome = .{ .err = error.RunnerNeverRan },
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This(), g: *Game, n: []const u8) void {
            if (@call(.auto, @field(Game, method), .{ g, n })) |did_load| {
                self.outcome = .{ .ok = did_load };
            } else |err| {
                self.outcome = .{ .err = err };
            }
            self.done.store(true, .release);
        }
    };

    var runner = Runner{};
    const handle = std.Thread.spawn(.{}, Runner.run, .{ &runner, game, name }) catch |err| {
        std.debug.print("load_deadline: thread spawn failed: {s}\n", .{@errorName(err)});
        std.process.abort();
    };

    // Zig 0.16 has neither `std.Thread.sleep` nor `std.time.Timer`, so the
    // deadline is counted in libc `nanosleep` steps — the same primitive
    // every other timing-sensitive test in this repo falls back to.
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    while (waited_ns < deadline_ns) : (waited_ns += step_ns) {
        if (runner.done.load(.acquire)) break;
        var req: std.c.timespec = .{
            .sec = @intCast(step_ns / std.time.ns_per_s),
            .nsec = @intCast(step_ns % std.time.ns_per_s),
        };
        var rem: std.c.timespec = undefined;
        // Retry the REMAINDER on EINTR. Counting a signal-interrupted sleep
        // as a full `step_ns` would let repeated interruptions burn the
        // deadline while barely any wall-clock time had passed — aborting a
        // loader that was never actually wedged. A test whose whole job is to
        // fail deterministically must not itself be flaky under signals.
        while (std.c.nanosleep(&req, &rem) == -1 and std.posix.errno(@as(c_int, -1)) == .INTR) {
            req = rem;
        }
    }

    if (!runner.done.load(.acquire)) {
        std.debug.print(
            "\n" ++
                "load_deadline: REGRESSION — " ++ method ++ "(\"{s}\") did not return\n" ++
                "within {d}ms. The blocking loop is wedged (see src/game/atlas_mixin.zig\n" ++
                "loadAssetIfNeededInternal). Aborting so this FAILS CI now rather than\n" ++
                "hanging it; the worker owns the Game, so there is no safe way to unwind.\n",
            .{ name, deadline_ns / std.time.ns_per_ms },
        );
        std.process.abort();
    }

    // `join` establishes happens-before with the worker's writes, so the
    // plain read of `runner.outcome` below is well-defined.
    handle.join();
    return runner.outcome;
}

/// Assert a deadline-guarded call returned a specific error. A success is
/// reported with the `did_load` value it produced, which is what a
/// regression that silently "works" looks like.
pub fn expectError(outcome: Outcome, expected: anyerror) !void {
    switch (outcome) {
        .ok => |did_load| {
            std.debug.print(
                "expected {s}, but the load SUCCEEDED (did_load = {})\n",
                .{ @errorName(expected), did_load },
            );
            return error.TestUnexpectedResult;
        },
        .err => |err| try testing.expectEqual(expected, err),
    }
}
