// POC 1: Zero-bit field mixin with @fieldParentPtr inside a comptime-generic struct.
//
// Validates:
// 1. @fieldParentPtr works inside a comptime-generic return type (like GameWith(Hooks))
// 2. Zero-bit mixin fields don't affect struct size
// 3. Cross-mixin calls work (hierarchy mixin calling methods on the parent struct)
// 4. Comptime generic type parameter (Hooks) is accessible from mixin code

const std = @import("std");

// ── Simulated sub-modules ──────────────────────────────────────────

/// Hierarchy mixin — simulates game_hierarchy.zig
pub fn HierarchyMixin(comptime GameType: type) type {
    return struct {
        const Self = @This();

        pub fn setParent(self: *Self, child: u32, parent: u32) !void {
            const game: *GameType = @alignCast(@fieldParentPtr("hierarchy", self));
            // Access game fields
            game.parent_map[child] = parent;
            game.op_count += 1;
        }

        pub fn getParent(self: *Self, child: u32) ?u32 {
            const game: *GameType = @alignCast(@fieldParentPtr("hierarchy", self));
            const val = game.parent_map[child];
            return if (val == 0xFFFF) null else val;
        }

        /// Cross-mixin call: hierarchy calling a method that stays on Game
        pub fn reparentAndCount(self: *Self, child: u32, new_parent: u32) !void {
            const game: *GameType = @alignCast(@fieldParentPtr("hierarchy", self));
            try self.setParent(child, new_parent);
            // Call a method on the parent Game struct (not on a mixin)
            game.incrementCounter();
        }
    };
}

/// Position mixin — simulates game_position.zig
pub fn PositionMixin(comptime GameType: type) type {
    return struct {
        const Self = @This();

        pub fn setPosition(self: *Self, entity: u32, x: f32, y: f32) void {
            const game: *GameType = @alignCast(@fieldParentPtr("pos", self));
            game.positions[entity] = .{ x, y };
            game.op_count += 1;
        }

        pub fn getPosition(self: *Self, entity: u32) [2]f32 {
            const game: *GameType = @alignCast(@fieldParentPtr("pos", self));
            return game.positions[entity];
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

        // Zero-bit mixin fields
        hierarchy: HierarchyMixin(Self) = .{},
        pos: PositionMixin(Self) = .{},

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

        /// A method that stays on Game (not in any mixin)
        pub fn incrementCounter(self: *Self) void {
            self.op_count += 1;
        }

        /// Method that uses hooks (stays on Game since it depends on Hooks type)
        pub fn doSomethingWithHooks(self: *Self) void {
            if (hooks_enabled and @hasDecl(Hooks, "onAction")) {
                Hooks.onAction();
                self.hook_count += 1;
            }
        }
    };
}

/// Alias for no hooks
pub const Game = GameWith(void);

// ── Tests ──────────────────────────────────────────────────────────

test "zero-bit mixin fields don't affect struct size" {
    // A struct with no mixins would have: parent_map(256) + positions(512) + op_count(4) + hook_count(4) = 776
    // The mixin fields should add 0 bytes
    const size_with_mixins = @sizeOf(Game);
    const expected = @sizeOf([64]u32) + @sizeOf([64][2]f32) + @sizeOf(u32) + @sizeOf(u32);
    try std.testing.expectEqual(expected, size_with_mixins);
}

test "hierarchy mixin: setParent and getParent via @fieldParentPtr" {
    var game = Game.init();

    try game.hierarchy.setParent(1, 0);
    try std.testing.expectEqual(@as(u32, 0), game.hierarchy.getParent(1).?);
    try std.testing.expectEqual(@as(?u32, null), game.hierarchy.getParent(2));
    try std.testing.expectEqual(@as(u32, 1), game.op_count);
}

test "position mixin: setPosition and getPosition via @fieldParentPtr" {
    var game = Game.init();

    game.pos.setPosition(5, 100.0, 200.0);
    const p = game.pos.getPosition(5);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), p[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), p[1], 0.001);
}

test "cross-mixin call: hierarchy calling Game method" {
    var game = Game.init();

    try game.hierarchy.reparentAndCount(3, 0);
    // setParent increments op_count once, incrementCounter once more
    try std.testing.expectEqual(@as(u32, 2), game.op_count);
    try std.testing.expectEqual(@as(u32, 0), game.hierarchy.getParent(3).?);
}

test "hooks still work on Game methods (comptime Hooks parameter)" {
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
    try std.testing.expectEqual(@as(u32, 1), game.hook_count);

    game.doSomethingWithHooks();
    try std.testing.expect(MyHooks.action_called);
    try std.testing.expectEqual(@as(u32, 2), game.hook_count);
}

test "void hooks (Game alias) work without issues" {
    var game = Game.init();
    game.doSomethingWithHooks(); // should be a no-op
    try std.testing.expectEqual(@as(u32, 0), game.hook_count);
}
