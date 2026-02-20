const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const ecs = @import("ecs");

const Game = engine.Game;
const Entity = ecs.Entity;
const Color = engine.Color;
const RenderPipeline = engine.RenderPipeline;

test {
    zspec.runAll(@This());
}

// ── Test helpers ────────────────────────────────────

fn createTestGame() !Game {
    const alloc = std.testing.allocator;
    var game: Game = undefined;
    game.allocator = alloc;
    game.registry = ecs.Registry.init(alloc);
    game.pipeline = RenderPipeline.init(alloc, undefined);
    game.gizmos_enabled = true;
    game.standalone_gizmos = std.ArrayList(Game.StandaloneGizmo).empty;
    game.selected_entities = try std.DynamicBitSet.initEmpty(alloc, 10_000);
    return game;
}

fn fixTestGamePointers(game: *Game) void {
    game.pipeline.registry = &game.registry;
}

fn deinitTestGame(game: *Game) void {
    game.standalone_gizmos.deinit(game.allocator);
    game.selected_entities.deinit();
    game.pipeline.deinit();
    game.registry.deinit();
}

// ============================================
// ENABLE / DISABLE
// ============================================

pub const ENABLE_DISABLE = struct {
    test "setEnabled(true) / areEnabled() round-trip" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos_enabled = false;
        game.gizmos.setEnabled(true);
        try expect.toBeTrue(game.gizmos.areEnabled());
    }

    test "setEnabled(false) disables gizmos" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos.setEnabled(false);
        try expect.toBeFalse(game.gizmos.areEnabled());
    }

    test "setEnabled with same value is no-op" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos_enabled = true;
        game.gizmos.setEnabled(true);
        try expect.toBeTrue(game.gizmos.areEnabled());
    }
};

// ============================================
// ENTITY SELECTION
// ============================================

pub const ENTITY_SELECTION = struct {
    test "selectEntity marks entity as selected" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = game.registry.createEntity();
        game.gizmos.selectEntity(e);
        try expect.toBeTrue(game.gizmos.isEntitySelected(e));
    }

    test "deselectEntity clears selection" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = game.registry.createEntity();
        game.gizmos.selectEntity(e);
        game.gizmos.deselectEntity(e);
        try expect.toBeFalse(game.gizmos.isEntitySelected(e));
    }

    test "isEntitySelected returns false for unselected entity" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = game.registry.createEntity();
        try expect.toBeFalse(game.gizmos.isEntitySelected(e));
    }

    test "clearSelection clears all selections" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e1 = game.registry.createEntity();
        const e2 = game.registry.createEntity();
        game.gizmos.selectEntity(e1);
        game.gizmos.selectEntity(e2);

        game.gizmos.clearSelection();

        try expect.toBeFalse(game.gizmos.isEntitySelected(e1));
        try expect.toBeFalse(game.gizmos.isEntitySelected(e2));
    }
};

// ============================================
// STANDALONE GIZMOS
// ============================================

pub const STANDALONE_GIZMOS = struct {
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };

    test "drawGizmo adds to standalone list" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos.drawCircle(10, 20, 25, red);

        try expect.equal(game.standalone_gizmos.items.len, 1);
        try expect.equal(game.standalone_gizmos.items[0].x, 10);
        try expect.equal(game.standalone_gizmos.items[0].y, 20);
    }

    test "clearGizmos empties the list" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos.drawCircle(10, 20, 25, red);
        game.gizmos.drawCircle(30, 40, 5, red);
        try expect.equal(game.standalone_gizmos.items.len, 2);

        game.gizmos.clearGizmos();
        try expect.equal(game.standalone_gizmos.items.len, 0);
    }

    test "clearGizmoGroup only removes matching group" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        // Add gizmos with different groups directly
        try game.standalone_gizmos.append(game.allocator, .{
            .shape = .{ .circle = .{ .radius = 5 } },
            .x = 0,
            .y = 0,
            .color = red,
            .group = "enemies",
        });
        try game.standalone_gizmos.append(game.allocator, .{
            .shape = .{ .circle = .{ .radius = 10 } },
            .x = 1,
            .y = 1,
            .color = green,
            .group = "allies",
        });
        try game.standalone_gizmos.append(game.allocator, .{
            .shape = .{ .circle = .{ .radius = 15 } },
            .x = 2,
            .y = 2,
            .color = red,
            .group = "enemies",
        });
        try expect.equal(game.standalone_gizmos.items.len, 3);

        game.gizmos.clearGizmoGroup("enemies");

        try expect.equal(game.standalone_gizmos.items.len, 1);
        try expect.equal(game.standalone_gizmos.items[0].x, 1);
    }

    test "drawArrow adds arrow shape" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos.drawArrow(10, 20, 50, 60, green);

        try expect.equal(game.standalone_gizmos.items.len, 1);
        const item = game.standalone_gizmos.items[0];
        try expect.equal(item.x, 10);
        try expect.equal(item.y, 20);
        switch (item.shape) {
            .arrow => |a| {
                try expect.equal(a.delta.x, 40);
                try expect.equal(a.delta.y, 40);
            },
            else => return error.TestExpectedEqual,
        }
    }

    test "drawLine adds line shape" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos.drawLine(5, 10, 25, 30, red);

        try expect.equal(game.standalone_gizmos.items.len, 1);
        const item = game.standalone_gizmos.items[0];
        try expect.equal(item.x, 5);
        try expect.equal(item.y, 10);
        switch (item.shape) {
            .line => |l| {
                try expect.equal(l.end.x, 20);
                try expect.equal(l.end.y, 20);
            },
            else => return error.TestExpectedEqual,
        }
    }

    test "drawCircle adds circle shape" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos.drawCircle(100, 200, 50, green);

        try expect.equal(game.standalone_gizmos.items.len, 1);
        const item = game.standalone_gizmos.items[0];
        try expect.equal(item.x, 100);
        try expect.equal(item.y, 200);
        switch (item.shape) {
            .circle => |c| try expect.equal(c.radius, 50),
            else => return error.TestExpectedEqual,
        }
    }

    test "drawRect adds rectangle shape" {
        var game = try createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        game.gizmos.drawRect(10, 20, 100, 50, red);

        try expect.equal(game.standalone_gizmos.items.len, 1);
        const item = game.standalone_gizmos.items[0];
        try expect.equal(item.x, 10);
        try expect.equal(item.y, 20);
        switch (item.shape) {
            .rectangle => |r| {
                try expect.equal(r.width, 100);
                try expect.equal(r.height, 50);
            },
            else => return error.TestExpectedEqual,
        }
    }
};
