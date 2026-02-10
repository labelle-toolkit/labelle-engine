// POC 2: Namespaced accessor functions (Approach B).
//
// Validates:
// 1. Accessor functions returning wrapper structs work with comptime-generic parent
// 2. Wrapper struct holds *GameType pointer for field access
// 3. Cross-mixin calls work (hierarchy calling methods on Game)
// 4. Comptime generic type parameter (Hooks) is accessible

const std = @import("std");

// ── Simulated sub-modules ──────────────────────────────────────────

/// Hierarchy manager — simulates game_hierarchy.zig
pub fn HierarchyManager(comptime GameType: type) type {
    return struct {
        game: *GameType,

        pub fn setParent(self: @This(), child: u32, parent: u32) !void {
            self.game.parent_map[child] = parent;
            self.game.op_count += 1;
        }

        pub fn getParent(self: @This(), child: u32) ?u32 {
            const val = self.game.parent_map[child];
            return if (val == 0xFFFF) null else val;
        }

        /// Cross-call: hierarchy calling a method on Game
        pub fn reparentAndCount(self: @This(), child: u32, new_parent: u32) !void {
            try self.setParent(child, new_parent);
            self.game.incrementCounter();
        }
    };
}

/// Position manager — simulates game_position.zig
pub fn PositionManager(comptime GameType: type) type {
    return struct {
        game: *GameType,

        pub fn setPosition(self: @This(), entity: u32, x: f32, y: f32) void {
            self.game.positions[entity] = .{ x, y };
            self.game.op_count += 1;
        }

        pub fn getPosition(self: @This(), entity: u32) [2]f32 {
            return self.game.positions[entity];
        }
    };
}

// ── Simulated GameWith(Hooks) ──────────────────────────────────────

pub fn GameWith(comptime Hooks: type) type {
    const hooks_enabled = Hooks != void;

    return struct {
        const Self = @This();

        // Data fields
        parent_map: [64]u32,
        positions: [64][2]f32,
        op_count: u32,
        hook_count: u32,

        // Accessor functions return lightweight wrappers
        pub fn hierarchy(self: *Self) HierarchyManager(Self) {
            return .{ .game = self };
        }

        pub fn pos(self: *Self) PositionManager(Self) {
            return .{ .game = self };
        }

        pub fn init() Self {
            var game = Self{
                .parent_map = [_]u32{0xFFFF} ** 64,
                .positions = [_][2]f32{.{ 0, 0 }} ** 64,
                .op_count = 0,
                .hook_count = 0,
            };
            if (hooks_enabled and @hasDecl(Hooks, "onInit")) {
                Hooks.onInit();
                game.hook_count += 1;
            }
            return game;
        }

        pub fn incrementCounter(self: *Self) void {
            self.op_count += 1;
        }

        pub fn doSomethingWithHooks(self: *Self) void {
            if (hooks_enabled and @hasDecl(Hooks, "onAction")) {
                Hooks.onAction();
                self.hook_count += 1;
            }
        }
    };
}

pub const Game = GameWith(void);

// ── Tests ──────────────────────────────────────────────────────────

test "no extra struct fields needed" {
    // Accessor approach adds NO fields to Game — wrappers are created on demand
    const size = @sizeOf(Game);
    const expected = @sizeOf([64]u32) + @sizeOf([64][2]f32) + @sizeOf(u32) + @sizeOf(u32);
    try std.testing.expectEqual(expected, size);
}

test "hierarchy accessor: setParent and getParent" {
    var game = Game.init();

    try game.hierarchy().setParent(1, 0);
    try std.testing.expectEqual(@as(u32, 0), game.hierarchy().getParent(1).?);
    try std.testing.expectEqual(@as(?u32, null), game.hierarchy().getParent(2));
    try std.testing.expectEqual(@as(u32, 1), game.op_count);
}

test "position accessor: setPosition and getPosition" {
    var game = Game.init();

    game.pos().setPosition(5, 100.0, 200.0);
    const p = game.pos().getPosition(5);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), p[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), p[1], 0.001);
}

test "cross-call: hierarchy calling Game method" {
    var game = Game.init();

    try game.hierarchy().reparentAndCount(3, 0);
    try std.testing.expectEqual(@as(u32, 2), game.op_count);
    try std.testing.expectEqual(@as(u32, 0), game.hierarchy().getParent(3).?);
}

test "hooks still work" {
    const MyHooks = struct {
        var init_called = false;
        var action_called = false;

        pub fn onInit() void {
            init_called = true;
        }
        pub fn onAction() void {
            action_called = true;
        }
    };

    var game = GameWith(MyHooks).init();
    try std.testing.expect(MyHooks.init_called);

    game.doSomethingWithHooks();
    try std.testing.expect(MyHooks.action_called);
}
