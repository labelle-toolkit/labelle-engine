//! Typed hook context (#855).
//!
//! A hook receiver used to open every handler with a hand-written cast of
//! an injected `*anyopaque`:
//!
//!     fn getGame(ptr: *anyopaque) *@import("root").Game {
//!         return @ptrCast(@alignCast(ptr));
//!     }
//!
//! `engine.HookContext` replaces that: declare it as a field, and
//! `Game.setHooks` binds it. These tests cover the new form, the legacy
//! form, and — critically — the two coexisting in one merged receiver
//! tuple, because the change has to be additive for every shipped game.
//!
//! Note on `ctx.game()` vs `ctx.gameAs(Game)`: under `zig test` the
//! compilation ROOT is Zig's test runner, not this file, so
//! `@import("root").Game` — what the no-argument `ctx.game()` resolves —
//! does not exist here. This file therefore exercises `gameAs`, and the
//! sibling headless harness `test/typed_hook_context_root_exe.zig` (a
//! real executable whose root declares `pub const Game`, exactly like an
//! assembler-generated `main.zig`) covers the `ctx.game()` path. Both are
//! wired into `zig build test`.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

const Entity = core.MockEcsBackend(u32).Entity;

// ── Game events, in the two shapes real projects produce ───────────────
// A bare root event and a pack-namespaced one (`<pack>__<event>`).
const GameEventsUnion = union(enum) {
    worker_eat_start: struct { worker_id: u32 },
    citizens__worker_poop: struct { worker_id: u32 },
};

// ── Receiver 1: new form, root hook, stateful ──────────────────────────
const RootHooks = struct {
    /// Injected by `setHooks`. No `undefined`, no `*anyopaque`.
    ctx: engine.HookContext = .{},
    /// Receiver state survives the change — the whole point of a
    /// receiver struct rather than a free function.
    eats: usize = 0,
    last_worker: u32 = 0,
    entities_seen: usize = 0,

    pub fn worker_eat_start(self: *RootHooks, payload: anytype) void {
        // The line under test: typed game, no cast written by hand.
        const game = self.ctx.gameAs(Game);
        comptime std.debug.assert(@TypeOf(game) == *Game);

        self.eats += 1;
        self.last_worker = payload.worker_id;
        // Reach a real game API through the typed pointer.
        self.entities_seen = game.active_world.ecs_backend.entityCount();
    }
};

// ── Receiver 2: new form, pack hook, context field under another name ──
// Injection is by field TYPE, so a pack is free to call the field
// whatever reads best.
const PackHooks = struct {
    poops: usize = 0,
    hook_ctx: engine.HookContext = .{},

    pub fn citizens__worker_poop(self: *PackHooks, payload: anytype) void {
        const game = self.hook_ctx.gameAs(Game);
        comptime std.debug.assert(@TypeOf(game) == *Game);
        self.poops += 1;
        // Prove the pointer is the live game, not a copy.
        _ = game.createEntity();
        _ = payload;
    }
};

// ── Receiver 3: LEGACY form, unchanged ─────────────────────────────────
// Byte-for-byte the shape flying-platform ships today. It must keep
// working with no edit, in the same merged tuple as the new form.
const LegacyHooks = struct {
    game_ptr: *anyopaque = undefined,
    frames: usize = 0,
    entities_seen: usize = 0,

    // Verbatim status quo, except that under `zig test` the root is the
    // test runner, so the game type is named directly rather than through
    // `@import("root").Game`. The cast is the point, and it is unchanged.
    fn getGame(ptr: *anyopaque) *Game {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn frame_start(self: *LegacyHooks, _: anytype) void {
        const game = getGame(self.game_ptr);
        self.frames += 1;
        self.entities_seen = game.active_world.ecs_backend.entityCount();
    }
};

// ── Receiver 4: no context and no game_ptr at all ──────────────────────
// The third existing shape: a pure state machine that never touches the
// game. Must not be disturbed by the injection walk.
const StatelessHooks = struct {
    ticks: usize = 0,

    pub fn frame_end(self: *StatelessHooks, _: anytype) void {
        self.ticks += 1;
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
    GameEventsUnion,
});

const AllHooks = engine.MergeHooks(AllHookPayloads, .{
    *RootHooks,
    *PackHooks,
    *LegacyHooks,
    *StatelessHooks,
});

const AssembledGame = game_mod.GameConfig(
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
    GameEventsUnion,
);

/// What the assembler's generated `main.zig` exports. Named locally here
/// because `zig test`'s root is the test runner (see the file header).
pub const Game = AssembledGame;

const Harness = struct {
    root: RootHooks = .{},
    pack: PackHooks = .{},
    legacy: LegacyHooks = .{},
    stateless: StatelessHooks = .{},
    hooks: AllHooks = undefined,
    game: Game = undefined,

    fn start(self: *Harness) void {
        self.hooks = .{ .receivers = .{ &self.root, &self.pack, &self.legacy, &self.stateless } };
        self.game = Game.init(testing.allocator);
        self.game.setHooks(&self.hooks);
    }

    fn stop(self: *Harness) void {
        self.game.deinit();
    }
};

// ── The new form ───────────────────────────────────────────────────────

test "ctx.game() gives a typed game with no cast in the handler" {
    var h = Harness{};
    h.start();
    defer h.stop();

    const a = h.game.createEntity();
    const b = h.game.createEntity();
    _ = a;
    _ = b;

    h.game.emit(.{ .worker_eat_start = .{ .worker_id = 42 } });
    h.game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), h.root.eats);
    try testing.expectEqual(@as(u32, 42), h.root.last_worker);
    // Read through the injected pointer, so it really is the live game.
    try testing.expectEqual(@as(usize, 2), h.root.entities_seen);
}

test "a pack receiver is bound too, under its own field name" {
    var h = Harness{};
    h.start();
    defer h.stop();

    h.game.emit(.{ .citizens__worker_poop = .{ .worker_id = 7 } });
    h.game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), h.pack.poops);
    // The handler created an entity through the typed pointer; observe
    // it from outside.
    try testing.expectEqual(@as(usize, 1), h.game.active_world.ecs_backend.entityCount());
}

test "every receiver in the tuple is bound to the same game instance" {
    var h = Harness{};
    h.start();
    defer h.stop();

    try testing.expect(h.root.ctx.isBound());
    try testing.expect(h.pack.hook_ctx.isBound());
    try testing.expectEqual(h.root.ctx.gameAs(Game), h.pack.hook_ctx.gameAs(Game));
    try testing.expectEqual(&h.game, h.root.ctx.gameAs(Game));
}

test "a context is unbound until setHooks runs" {
    var recv = RootHooks{};
    try testing.expect(!recv.ctx.isBound());
}

test "gameAs returns a pointer typed as the named game" {
    var h = Harness{};
    h.start();
    defer h.stop();

    const via_named = h.root.ctx.gameAs(AssembledGame);
    try testing.expectEqual(&h.game, via_named);
    comptime std.debug.assert(@TypeOf(via_named) == *AssembledGame);
}

test "the binding survives scene resets and many frames" {
    var h = Harness{};
    h.start();
    defer h.stop();

    // `Game` is at a stable address for its whole life, so a context
    // bound once at setHooks stays correct across world resets.
    h.game.resetEcsBackend();
    h.game.setPaused(true);
    h.game.setPaused(false);

    var i: usize = 0;
    while (i < 8) : (i += 1) h.game.tick(0.016);

    h.game.emit(.{ .worker_eat_start = .{ .worker_id = 1 } });
    h.game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), h.root.eats);
    try testing.expectEqual(&h.game, h.root.ctx.gameAs(Game));
}

// ── Backward compatibility ─────────────────────────────────────────────

test "an OLD-STYLE game_ptr receiver still works, unchanged" {
    var h = Harness{};
    h.start();
    defer h.stop();

    _ = h.game.createEntity();
    h.game.tick(0.016);
    h.game.tick(0.016);

    try testing.expectEqual(@as(usize, 2), h.legacy.frames);
    try testing.expectEqual(@as(usize, 1), h.legacy.entities_seen);
}

test "a receiver with neither a context nor a game_ptr is untouched" {
    var h = Harness{};
    h.start();
    defer h.stop();

    h.game.tick(0.016);
    try testing.expectEqual(@as(usize, 1), h.stateless.ticks);
}

test "old and new receiver forms coexist in one merged tuple" {
    var h = Harness{};
    h.start();
    defer h.stop();

    h.game.tick(0.016);
    h.game.emit(.{ .worker_eat_start = .{ .worker_id = 3 } });
    h.game.emit(.{ .citizens__worker_poop = .{ .worker_id = 4 } });
    h.game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), h.legacy.frames);
    try testing.expectEqual(@as(usize, 1), h.stateless.ticks);
    try testing.expectEqual(@as(usize, 1), h.root.eats);
    try testing.expectEqual(@as(usize, 1), h.pack.poops);
}

// ── Identity plumbing ──────────────────────────────────────────────────

test "typeId is stable per type and distinct across types" {
    const A = struct { x: u8 };
    const B = struct { x: u8 };
    try testing.expectEqual(engine.typeId(A), engine.typeId(A));
    try testing.expect(engine.typeId(A) != engine.typeId(B));
    try testing.expect(engine.typeId(AssembledGame) != engine.typeId(A));
}

test "a bound context records the game type it was bound to" {
    var h = Harness{};
    h.start();
    defer h.stop();

    try testing.expectEqual(engine.typeId(AssembledGame), h.root.ctx.id.?);
    try testing.expectEqualStrings(@typeName(AssembledGame), h.root.ctx.bound_name);
}
