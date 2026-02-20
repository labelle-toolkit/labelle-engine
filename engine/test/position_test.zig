const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const ecs = @import("ecs");

const Game = engine.Game;
const Entity = ecs.Entity;
const Position = engine.Position;
const RenderPipeline = engine.RenderPipeline;

const Parent = engine.render.components.Parent;

test {
    zspec.runAll(@This());
}

// ── Test helpers (same pattern as hierarchy_test.zig) ───────────────

fn createTestGame() Game {
    const alloc = std.testing.allocator;
    var game: Game = undefined;
    game.allocator = alloc;
    game.registry = ecs.Registry.init(alloc);
    game.pipeline = RenderPipeline.init(alloc, undefined);
    return game;
}

fn fixTestGamePointers(game: *Game) void {
    game.pipeline.registry = &game.registry;
}

fn deinitTestGame(game: *Game) void {
    var view = game.registry.view(.{Parent});
    var iter = view.entityIterator();
    while (iter.next()) |child| {
        game.hierarchy.removeParent(child);
    }
    game.pipeline.deinit();
    game.registry.deinit();
}

fn createEntityAt(game: *Game, x: f32, y: f32) Entity {
    const e = game.registry.createEntity();
    game.registry.addComponent(e, Position{ .x = x, .y = y });
    return e;
}

// ============================================
// LOCAL POSITION
// ============================================

pub const LOCAL_POSITION = struct {
    test "addPosition creates Position component" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = game.registry.createEntity();
        game.pos.addPosition(e, Position{ .x = 10, .y = 20 });

        const pos = game.registry.getComponent(e, Position);
        try expect.toBeTrue(pos != null);
        try expect.equal(pos.?.x, 10);
        try expect.equal(pos.?.y, 20);
    }

    test "getLocalPosition returns pointer to existing Position" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 5, 15);
        const pos = game.pos.getLocalPosition(e);
        try expect.toBeTrue(pos != null);
        try expect.equal(pos.?.x, 5);
        try expect.equal(pos.?.y, 15);
    }

    test "getLocalPosition returns null for entity without Position" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = game.registry.createEntity();
        try expect.toBeTrue(game.pos.getLocalPosition(e) == null);
    }

    test "setLocalPosition updates Position and marks dirty" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 0, 0);
        try game.pipeline.trackEntity(e, .none);
        game.pipeline.tracked.getPtr(e).?.position_dirty = false;

        game.pos.setLocalPosition(e, Position{ .x = 42, .y = 99 });

        const pos = game.pos.getLocalPosition(e).?;
        try expect.equal(pos.x, 42);
        try expect.equal(pos.y, 99);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(e).?.position_dirty);
    }

    test "setLocalPositionXY updates x/y and marks dirty" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 0, 0);
        try game.pipeline.trackEntity(e, .none);
        game.pipeline.tracked.getPtr(e).?.position_dirty = false;

        game.pos.setLocalPositionXY(e, 7, 13);

        const pos = game.pos.getLocalPosition(e).?;
        try expect.equal(pos.x, 7);
        try expect.equal(pos.y, 13);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(e).?.position_dirty);
    }

    test "moveLocalPosition adds delta to current position" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 10, 20);
        try game.pipeline.trackEntity(e, .none);
        game.pipeline.tracked.getPtr(e).?.position_dirty = false;

        game.pos.moveLocalPosition(e, 5, -3);

        const pos = game.pos.getLocalPosition(e).?;
        try expect.equal(pos.x, 15);
        try expect.equal(pos.y, 17);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(e).?.position_dirty);
    }

    test "moveLocalPosition on entity without Position is a no-op" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = game.registry.createEntity();
        game.pos.moveLocalPosition(e, 5, 5);
        try expect.toBeTrue(game.pos.getLocalPosition(e) == null);
    }
};

// ============================================
// WORLD POSITION
// ============================================

pub const WORLD_POSITION = struct {
    test "getWorldPosition returns local pos for root entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 42, 99);
        const world = game.pos.getWorldPosition(e).?;
        try expect.equal(world.x, 42);
        try expect.equal(world.y, 99);
    }

    test "getWorldPosition sums through parent chain" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const grandparent = createEntityAt(&game, 10, 20);
        const parent = createEntityAt(&game, 30, 40);
        const child = createEntityAt(&game, 50, 60);

        try game.hierarchy.setParent(parent, grandparent);
        try game.hierarchy.setParent(child, parent);

        const world = game.pos.getWorldPosition(child).?;
        try expect.equal(world.x, 90);
        try expect.equal(world.y, 120);
    }

    test "getWorldPosition returns null for entity without Position" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = game.registry.createEntity();
        try expect.toBeTrue(game.pos.getWorldPosition(e) == null);
    }

    test "getWorldTransform includes rotation for root entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = game.registry.createEntity();
        game.registry.addComponent(e, Position{ .x = 10, .y = 20, .rotation = 1.5 });

        const wt = game.pos.getWorldTransform(e).?;
        try expect.equal(wt.x, 10);
        try expect.equal(wt.y, 20);
        try expect.equal(wt.rotation, 1.5);
    }

    test "getWorldTransform accumulates rotation with inherit_rotation" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = game.registry.createEntity();
        game.registry.addComponent(parent, Position{ .x = 0, .y = 0, .rotation = 1.0 });

        const child = game.registry.createEntity();
        game.registry.addComponent(child, Position{ .x = 0, .y = 0, .rotation = 0.5 });

        try game.hierarchy.setParentWithOptions(child, parent, true, false);

        const wt = game.pos.getWorldTransform(child).?;
        try expect.equal(wt.rotation, 1.5);
    }

    test "getWorldTransform rotates offset when parent has rotation + inherit" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const half_pi = std.math.pi / 2.0;
        const parent = game.registry.createEntity();
        game.registry.addComponent(parent, Position{ .x = 100, .y = 0, .rotation = half_pi });

        const child = game.registry.createEntity();
        game.registry.addComponent(child, Position{ .x = 10, .y = 0 });

        try game.hierarchy.setParentWithOptions(child, parent, true, false);

        const wt = game.pos.getWorldTransform(child).?;
        // cos(π/2) ≈ 0, sin(π/2) ≈ 1
        // world.x = 100 + 10*cos(π/2) - 0*sin(π/2) ≈ 100
        // world.y = 0 + 10*sin(π/2) + 0*cos(π/2) ≈ 10
        try expect.toBeTrue(@abs(wt.x - 100.0) < 0.001);
        try expect.toBeTrue(@abs(wt.y - 10.0) < 0.001);
    }

    test "getWorldTransform does NOT accumulate rotation without inherit flag" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = game.registry.createEntity();
        game.registry.addComponent(parent, Position{ .x = 100, .y = 0, .rotation = 1.0 });

        const child = game.registry.createEntity();
        game.registry.addComponent(child, Position{ .x = 10, .y = 0, .rotation = 0.5 });

        try game.hierarchy.setParent(child, parent);

        const wt = game.pos.getWorldTransform(child).?;
        try expect.equal(wt.rotation, 0.5);
        try expect.equal(wt.x, 110);
        try expect.equal(wt.y, 0);
    }

    test "getWorldTransform truncates at depth limit without crashing" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        // Build a chain of 34 entities (exceeds max_hierarchy_depth of 32)
        // The depth guard truncates the transform computation but still returns a result
        var prev = createEntityAt(&game, 0, 0);
        for (0..33) |_| {
            const child = createEntityAt(&game, 1, 1);
            game.hierarchy.setParent(child, prev) catch unreachable;
            prev = child;
        }
        // Should return a (truncated) transform, not crash from infinite recursion
        const result = game.pos.getWorldTransform(prev);
        try expect.toBeTrue(result != null);
    }
};

// ============================================
// SET WORLD POSITION
// ============================================

pub const SET_WORLD_POSITION = struct {
    test "setWorldPosition on root entity sets local directly" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 0, 0);
        game.pos.setWorldPosition(e, 42, 99);

        const pos = game.pos.getLocalPosition(e).?;
        try expect.equal(pos.x, 42);
        try expect.equal(pos.y, 99);
    }

    test "setWorldPosition on child computes correct local offset" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 100, 200);
        const child = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(child, parent);

        game.pos.setWorldPosition(child, 150, 250);

        const pos = game.pos.getLocalPosition(child).?;
        try expect.equal(pos.x, 50);
        try expect.equal(pos.y, 50);
    }

    test "setWorldPosition on child with rotated parent applies inverse rotation" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const half_pi = std.math.pi / 2.0;
        const parent = game.registry.createEntity();
        game.registry.addComponent(parent, Position{ .x = 100, .y = 0, .rotation = half_pi });

        const child = game.registry.createEntity();
        game.registry.addComponent(child, Position{ .x = 0, .y = 0 });
        try game.hierarchy.setParentWithOptions(child, parent, true, false);

        // Set world position to (100, 10) — with parent at (100,0) rotated π/2
        // Offset in world: (0, 10)
        // Inverse rotation of (0, 10) by -π/2:
        //   x = 0*cos(-π/2) - 10*sin(-π/2) ≈ 10
        //   y = 0*sin(-π/2) + 10*cos(-π/2) ≈ 0
        game.pos.setWorldPosition(child, 100, 10);

        const pos = game.pos.getLocalPosition(child).?;
        try expect.toBeTrue(@abs(pos.x - 10.0) < 0.001);
        try expect.toBeTrue(@abs(pos.y) < 0.001);
    }

    test "round-trip: setWorldPosition then getWorldPosition returns same coords" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 100, 200);
        const child = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(child, parent);

        game.pos.setWorldPosition(child, 300, 400);

        const world = game.pos.getWorldPosition(child).?;
        try expect.equal(world.x, 300);
        try expect.equal(world.y, 400);
    }
};
