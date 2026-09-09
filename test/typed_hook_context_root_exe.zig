//! Headless "assembled root" harness for the typed hook context (#855).
//!
//! `zig test` makes Zig's own test runner the compilation root, so a unit
//! test can never exercise `HookContext.game()` — the no-argument form
//! that resolves `@import("root").Game`. This file is an EXECUTABLE, so
//! it IS the root, and it declares `pub const Game` exactly the way the
//! assembler's generated `main.zig` does. That makes it the only place
//! the shipping authoring form
//!
//!     ctx: engine.HookContext = .{},
//!     ...
//!     const game = self.ctx.game();
//!
//! is compiled and run end to end. `zig build test` runs it; a failed
//! assertion exits non-zero and fails the step.
//!
//! It also stands in for the "root hook + pack hook" scaffold the issue
//! asks for: `RootHooks` is a root-level receiver, `PackHooks` a
//! pack-namespaced one, and neither writes a cast or an import.

const std = @import("std");
const engine = @import("engine");

const core = engine.core;
const Entity = core.MockEcsBackend(u32).Entity;

const GameEvents = union(enum) {
    worker_eat_start: struct { worker_id: u32 },
    citizens__worker_poop: struct { worker_id: u32 },
};

// ── A root hook, stateful, with typed game access ──────────────────────
const RootHooks = struct {
    ctx: engine.HookContext = .{},
    eats: usize = 0,
    entities_at_last_eat: usize = 0,

    pub fn worker_eat_start(self: *RootHooks, payload: anytype) void {
        // No `@ptrCast`, no `@alignCast`, no `@import("root")`.
        const game = self.ctx.game();
        comptime std.debug.assert(@TypeOf(game) == *Game);
        self.eats += 1;
        self.entities_at_last_eat = game.active_world.ecs_backend.entityCount();
        // The entity type without an `@import("root")` either — this is
        // the form RFC-TYPED-HOOK-CONTEXT documents for migrating the
        // `const Entity = @import("root").Game.EntityType;` preamble.
        const worker: @TypeOf(game.*).EntityType = @intCast(payload.worker_id);
        _ = worker;
    }
};

// ── A pack hook, namespaced handler, context under its own name ────────
const PackHooks = struct {
    poops: usize = 0,
    hook_ctx: engine.HookContext = .{},

    pub fn citizens__worker_poop(self: *PackHooks, payload: anytype) void {
        const game = self.hook_ctx.game();
        self.poops += 1;
        _ = game.createEntity();
        _ = payload;
    }
};

// ── The legacy form, alongside, unchanged ──────────────────────────────
const LegacyHooks = struct {
    game_ptr: *anyopaque = undefined,
    frames: usize = 0,

    fn getGame(ptr: *anyopaque) *@import("root").Game {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn frame_start(self: *LegacyHooks, _: anytype) void {
        _ = getGame(self.game_ptr);
        self.frames += 1;
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
    GameEvents,
});

const AllHooks = engine.MergeHooks(AllHookPayloads, .{
    *RootHooks,
    *PackHooks,
    *LegacyHooks,
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
    GameEvents,
);

/// The generated-`main.zig` contract `HookContext.game()` relies on.
pub const Game = AssembledGame;

fn expect(ok: bool, what: []const u8) !void {
    if (!ok) {
        std.debug.print("typed_hook_context_root_exe: FAILED: {s}\n", .{what});
        return error.AssertionFailed;
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var root_hooks = RootHooks{};
    var pack_hooks = PackHooks{};
    var legacy_hooks = LegacyHooks{};
    var hooks = AllHooks{ .receivers = .{ &root_hooks, &pack_hooks, &legacy_hooks } };

    var game = Game.init(allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    try expect(root_hooks.ctx.isBound(), "root hook context bound by setHooks");
    try expect(pack_hooks.hook_ctx.isBound(), "pack hook context bound by setHooks");
    try expect(root_hooks.ctx.game() == &game, "ctx.game() is the live game");

    _ = game.createEntity();
    _ = game.createEntity();

    game.emit(.{ .worker_eat_start = .{ .worker_id = 11 } });
    game.emit(.{ .citizens__worker_poop = .{ .worker_id = 12 } });
    game.dispatchEvents();
    game.tick(0.016);

    try expect(root_hooks.eats == 1, "root handler ran once");
    try expect(root_hooks.entities_at_last_eat == 2, "root handler read the live entity count");
    try expect(pack_hooks.poops == 1, "pack handler ran once");
    // The pack handler created a third entity through its typed pointer.
    try expect(game.active_world.ecs_backend.entityCount() == 3, "pack handler mutated the live game");
    try expect(legacy_hooks.frames == 1, "legacy game_ptr receiver still fires");

    std.debug.print("typed_hook_context_root_exe: ok\n", .{});
}
