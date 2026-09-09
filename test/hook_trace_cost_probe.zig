//! Zero-cost probe for opt-in hook tracing (#858).
//!
//! A minimal headless game that touches EVERY emit/dispatch path #858
//! instrumented — `emit`, `tryEmit`, `emitSync`, `emitHook`,
//! `dispatchEvents`, a notification event and a consumable one — and
//! declares **no** `labelle_hook_trace`, so it is an untraced build.
//!
//! It is not a behaviour test (`test/hook_trace_off_test.zig` is that).
//! It exists to be COMPILED: `tools/hook_trace_cost.sh` builds this
//! same file, byte-for-byte, against the pre-#858 engine and against
//! the post-#858 engine, at the same filesystem path, and compares the
//! resulting binaries. Identical hashes are the measurement behind the
//! claim that a build which does not opt in pays nothing.
//!
//! Keep it dependency-light and deterministic: no clock, no
//! environment, no allocation beyond the game's own.

const std = @import("std");
const engine = @import("engine");

const core = engine.core;
const MockEcs = core.MockEcsBackend(u32);

const ClaimPayload = struct {
    seq: u32 = 0,
    pub const consumable = true;
};

const ProbeEvents = union(enum) {
    p__alpha: struct { seq: u32 = 0 },
    p__beta: struct { seq: u32 = 0 },
    p__claim: ClaimPayload,
    p__quiet: struct { seq: u32 = 0 },
};

const R1 = struct {
    hits: usize = 0,
    pub fn p__alpha(self: *R1, _: anytype) void {
        self.hits += 1;
    }
    pub fn p__claim(self: *R1, _: anytype) bool {
        self.hits += 1;
        return false;
    }
    pub fn frame_start(self: *R1, _: anytype) void {
        self.hits += 1;
    }
};

const R2 = struct {
    hits: usize = 0,
    pub fn p__alpha(self: *R2, _: anytype) void {
        self.hits += 1;
    }
    pub fn p__beta(self: *R2, _: anytype) void {
        self.hits += 1;
    }
    pub fn p__claim(self: *R2, _: anytype) bool {
        self.hits += 1;
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

const ProbePayload = core.MergeHookPayloads(.{ engine.HookPayload(u32), ProbeEvents });
const ProbeHooks = core.MergeHooks(ProbePayload, .{ *R1, *R2 });

const ProbeGame = engine.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *ProbeHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    ProbeEvents,
);

pub const Game = ProbeGame;

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var r1 = R1{};
    var r2 = R2{};
    var hooks = ProbeHooks{ .receivers = .{ &r1, &r2 } };

    var game = ProbeGame.init(gpa.allocator());
    defer game.deinit();
    game.setHooks(&hooks);

    game.emit(.{ .p__alpha = .{ .seq = 1 } });
    try game.tryEmit(.{ .p__beta = .{ .seq = 2 } });
    game.emit(.{ .p__quiet = .{ .seq = 3 } });
    game.dispatchEvents();

    game.emitSync(.{ .p__claim = .{ .seq = 4 } });
    game.emitHook(.{ .frame_start = .{ .frame_number = 1, .dt = 0.016 } });

    if (r1.hits + r2.hits == 0) return 1;
    std.debug.print("hook_trace_cost_probe: {d}\n", .{r1.hits + r2.hits});
    return 0;
}
