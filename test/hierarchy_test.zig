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
const Children = engine.render.components.Children;

test {
    zspec.runAll(@This());
}

/// Create a minimal Game instance for hierarchy testing.
/// Only `allocator`, `registry`, and `pipeline` are valid — hierarchy methods
/// don't touch anything else. `markPositionDirty` is a no-op for untracked entities.
fn createTestGame() Game {
    const alloc = std.testing.allocator;
    var game: Game = undefined;
    game.allocator = alloc;
    game.registry = ecs.Registry.init(alloc);
    // Pipeline with undefined engine pointer — safe because markPositionDirty
    // only does a hashmap lookup on `tracked` and never dereferences `engine`.
    game.pipeline = RenderPipeline.init(alloc, undefined);
    return game;
}

/// Clean up all parent-child relationships to free Children component slices,
/// then deinit the registry and pipeline.
fn deinitTestGame(game: *Game) void {
    // Free all Children component allocations by removing parent relationships
    var view = game.registry.view(.{Parent});
    var iter = view.entityIterator();
    while (iter.next()) |child| {
        game.removeParent(child, false);
    }
    game.pipeline.deinit();
    game.registry.deinit();
}

/// Helper: create an entity with a Position component
fn createEntityAt(game: *Game, x: f32, y: f32) Entity {
    const e = game.registry.create();
    game.registry.add(e, Position{ .x = x, .y = y });
    return e;
}

// ============================================
// REMOVE PARENT — keep_world_position
// ============================================

pub const REMOVE_PARENT = struct {
    pub const KEEP_WORLD_POSITION_FALSE = struct {
        test "removeParent(false) leaves local position unchanged" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 100, 200);
            const child = createEntityAt(&game, 30, 40);
            try game.setParent(child, parent);

            // Local position is still (30, 40), world would be (130, 240)
            game.removeParent(child, false);

            // Local position kept as-is — now it becomes the world position
            const pos = game.getLocalPosition(child).?;
            try expect.equal(pos.x, 30);
            try expect.equal(pos.y, 40);
        }
    };

    pub const KEEP_WORLD_POSITION_TRUE = struct {
        test "removeParent(true) preserves world position" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 100, 200);
            const child = createEntityAt(&game, 30, 40);
            try game.setParent(child, parent);

            // World position should be (130, 240)
            const world_before = game.getWorldPosition(child).?;
            try expect.equal(world_before.x, 130);
            try expect.equal(world_before.y, 240);

            game.removeParent(child, true);

            // After removeParent(true), local pos should equal the old world pos
            const pos = game.getLocalPosition(child).?;
            try expect.equal(pos.x, 130);
            try expect.equal(pos.y, 240);

            // And world pos (now = local since root) should match
            const world_after = game.getWorldPosition(child).?;
            try expect.equal(world_after.x, 130);
            try expect.equal(world_after.y, 240);
        }

        test "removeParent(true) works for root entity (no-op)" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const e = createEntityAt(&game, 50, 60);

            // No parent — should not crash
            game.removeParent(e, true);

            const pos = game.getLocalPosition(e).?;
            try expect.equal(pos.x, 50);
            try expect.equal(pos.y, 60);
        }

        test "removeParent(true) preserves world position in deep hierarchy" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const grandparent = createEntityAt(&game, 10, 20);
            const parent = createEntityAt(&game, 30, 40);
            const child = createEntityAt(&game, 50, 60);

            try game.setParent(parent, grandparent);
            try game.setParent(child, parent);

            // World position: (10+30+50, 20+40+60) = (90, 120)
            const world_before = game.getWorldPosition(child).?;
            try expect.equal(world_before.x, 90);
            try expect.equal(world_before.y, 120);

            // Remove child from parent, keeping world position
            game.removeParent(child, true);

            const pos = game.getLocalPosition(child).?;
            try expect.equal(pos.x, 90);
            try expect.equal(pos.y, 120);
        }
    };
};

// ============================================
// SET PARENT WITH OPTIONS — keep_world_position
// ============================================

pub const SET_PARENT_WITH_OPTIONS = struct {
    pub const KEEP_WORLD_POSITION_FALSE = struct {
        test "setParentWithOptions(false) leaves local position unchanged" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 100, 200);
            const child = createEntityAt(&game, 50, 60);

            try game.setParentWithOptions(child, parent, false, false, false);

            // Local position unchanged
            const pos = game.getLocalPosition(child).?;
            try expect.equal(pos.x, 50);
            try expect.equal(pos.y, 60);

            // World position is parent + local = (150, 260)
            const world = game.getWorldPosition(child).?;
            try expect.equal(world.x, 150);
            try expect.equal(world.y, 260);
        }
    };

    pub const KEEP_WORLD_POSITION_TRUE = struct {
        test "setParentWithOptions(true) preserves world position" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 100, 200);
            const child = createEntityAt(&game, 50, 60);

            // Before parenting, world pos = local pos = (50, 60)
            try game.setParentWithOptions(child, parent, false, false, true);

            // World position should still be (50, 60)
            const world = game.getWorldPosition(child).?;
            try expect.equal(world.x, 50);
            try expect.equal(world.y, 60);

            // Local position should be adjusted: (50 - 100, 60 - 200) = (-50, -140)
            const pos = game.getLocalPosition(child).?;
            try expect.equal(pos.x, -50);
            try expect.equal(pos.y, -140);
        }

        test "setParentWithOptions(true) preserves world position with deep parent" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const grandparent = createEntityAt(&game, 10, 20);
            const parent = createEntityAt(&game, 30, 40);
            try game.setParent(parent, grandparent);
            // Parent world pos = (10+30, 20+40) = (40, 60)

            const child = createEntityAt(&game, 100, 100);

            try game.setParentWithOptions(child, parent, false, false, true);

            // World position should still be (100, 100)
            const world = game.getWorldPosition(child).?;
            try expect.equal(world.x, 100);
            try expect.equal(world.y, 100);

            // Local offset = (100 - 40, 100 - 60) = (60, 40)
            const pos = game.getLocalPosition(child).?;
            try expect.equal(pos.x, 60);
            try expect.equal(pos.y, 40);
        }
    };

    pub const INHERITANCE_FLAGS = struct {
        test "setParentWithOptions sets inherit_rotation flag" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 0, 0);
            const child = createEntityAt(&game, 10, 10);

            try game.setParentWithOptions(child, parent, true, false, false);

            const parent_comp = game.registry.tryGet(Parent, child).?;
            try expect.toBeTrue(parent_comp.inherit_rotation);
            try expect.toBeFalse(parent_comp.inherit_scale);
        }

        test "setParentWithOptions sets inherit_scale flag" {
            var game = createTestGame();
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 0, 0);
            const child = createEntityAt(&game, 10, 10);

            try game.setParentWithOptions(child, parent, false, true, false);

            const parent_comp = game.registry.tryGet(Parent, child).?;
            try expect.toBeFalse(parent_comp.inherit_rotation);
            try expect.toBeTrue(parent_comp.inherit_scale);
        }
    };
};

// ============================================
// ROUND-TRIP: detach then re-attach
// ============================================

pub const ROUND_TRIP = struct {
    test "detach and re-attach preserves world position" {
        var game = createTestGame();
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 200, 100);
        const child = createEntityAt(&game, 50, 30);
        try game.setParent(child, parent);

        // World = (250, 130)
        const world_before = game.getWorldPosition(child).?;

        // Detach keeping world position
        game.removeParent(child, true);
        const world_detached = game.getWorldPosition(child).?;
        try expect.equal(world_detached.x, world_before.x);
        try expect.equal(world_detached.y, world_before.y);

        // Re-attach keeping world position
        try game.setParentWithOptions(child, parent, false, false, true);
        const world_reattached = game.getWorldPosition(child).?;
        try expect.equal(world_reattached.x, world_before.x);
        try expect.equal(world_reattached.y, world_before.y);

        // Local offset should be back to original
        const pos = game.getLocalPosition(child).?;
        try expect.equal(pos.x, 50);
        try expect.equal(pos.y, 30);
    }

    test "reparent between two parents preserves world position" {
        var game = createTestGame();
        defer deinitTestGame(&game);

        const parent_a = createEntityAt(&game, 100, 0);
        const parent_b = createEntityAt(&game, 0, 100);
        const child = createEntityAt(&game, 20, 30);
        try game.setParent(child, parent_a);

        // World = (120, 30)
        const world_before = game.getWorldPosition(child).?;
        try expect.equal(world_before.x, 120);
        try expect.equal(world_before.y, 30);

        // Detach with keep, re-attach to parent_b with keep
        game.removeParent(child, true);
        try game.setParentWithOptions(child, parent_b, false, false, true);

        const world_after = game.getWorldPosition(child).?;
        try expect.equal(world_after.x, 120);
        try expect.equal(world_after.y, 30);

        // Local offset from parent_b: (120 - 0, 30 - 100) = (120, -70)
        const pos = game.getLocalPosition(child).?;
        try expect.equal(pos.x, 120);
        try expect.equal(pos.y, -70);
    }
};
