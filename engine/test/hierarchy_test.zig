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
    // Note: pipeline.registry is set to null here. Callers must call
    // fixTestGamePointers() after createTestGame() to set it, because the
    // Game struct is returned by value and internal pointers would be stale.
    return game;
}

/// Fix internal pointers after the Game struct is in its final stack location.
/// Must be called after `createTestGame()` returns.
fn fixTestGamePointers(game: *Game) void {
    game.pipeline.registry = &game.registry;
}

/// Clean up all parent-child relationships to free Children component slices,
/// then deinit the registry and pipeline.
fn deinitTestGame(game: *Game) void {
    // Free all Children component allocations by removing parent relationships
    var view = game.registry.view(.{Parent});
    var iter = view.entityIterator();
    while (iter.next()) |child| {
        game.hierarchy.removeParent(child);
    }
    game.pipeline.deinit();
    game.registry.deinit();
}

/// Helper: create an entity with a Position component
fn createEntityAt(game: *Game, x: f32, y: f32) Entity {
    const e = game.registry.createEntity();
    game.registry.addComponent(e, Position{ .x = x, .y = y });
    return e;
}

// ============================================
// REMOVE PARENT
// ============================================

pub const REMOVE_PARENT = struct {
    pub const DEFAULT = struct {
        test "removeParent leaves local position unchanged" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 100, 200);
            const child = createEntityAt(&game, 30, 40);
            try game.hierarchy.setParent(child, parent);

            // Local position is still (30, 40), world would be (130, 240)
            game.hierarchy.removeParent(child);

            // Local position kept as-is — now it becomes the world position
            const pos = game.pos.getLocalPosition(child).?;
            try expect.equal(pos.x, 30);
            try expect.equal(pos.y, 40);
        }
    };

    pub const KEEP_TRANSFORM = struct {
        test "removeParentKeepTransform preserves world position" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 100, 200);
            const child = createEntityAt(&game, 30, 40);
            try game.hierarchy.setParent(child, parent);

            // World position should be (130, 240)
            const world_before = game.pos.getWorldPosition(child).?;
            try expect.equal(world_before.x, 130);
            try expect.equal(world_before.y, 240);

            game.hierarchy.removeParentKeepTransform(child);

            // After removeParent(true), local pos should equal the old world pos
            const pos = game.pos.getLocalPosition(child).?;
            try expect.equal(pos.x, 130);
            try expect.equal(pos.y, 240);

            // And world pos (now = local since root) should match
            const world_after = game.pos.getWorldPosition(child).?;
            try expect.equal(world_after.x, 130);
            try expect.equal(world_after.y, 240);
        }

        test "removeParentKeepTransform works for root entity (no-op)" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const e = createEntityAt(&game, 50, 60);

            // No parent — should not crash
            game.hierarchy.removeParentKeepTransform(e);

            const pos = game.pos.getLocalPosition(e).?;
            try expect.equal(pos.x, 50);
            try expect.equal(pos.y, 60);
        }

        test "removeParentKeepTransform preserves world position in deep hierarchy" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const grandparent = createEntityAt(&game, 10, 20);
            const parent = createEntityAt(&game, 30, 40);
            const child = createEntityAt(&game, 50, 60);

            try game.hierarchy.setParent(parent, grandparent);
            try game.hierarchy.setParent(child, parent);

            // World position: (10+30+50, 20+40+60) = (90, 120)
            const world_before = game.pos.getWorldPosition(child).?;
            try expect.equal(world_before.x, 90);
            try expect.equal(world_before.y, 120);

            // Remove child from parent, keeping world position
            game.hierarchy.removeParentKeepTransform(child);

            const pos = game.pos.getLocalPosition(child).?;
            try expect.equal(pos.x, 90);
            try expect.equal(pos.y, 120);
        }
    };
};

// ============================================
// SET PARENT WITH OPTIONS
// ============================================

pub const SET_PARENT_WITH_OPTIONS = struct {
    pub const DEFAULT = struct {
        test "setParentWithOptions leaves local position unchanged" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 100, 200);
            const child = createEntityAt(&game, 50, 60);

            try game.hierarchy.setParentWithOptions(child, parent, false, false);

            // Local position unchanged
            const pos = game.pos.getLocalPosition(child).?;
            try expect.equal(pos.x, 50);
            try expect.equal(pos.y, 60);

            // World position is parent + local = (150, 260)
            const world = game.pos.getWorldPosition(child).?;
            try expect.equal(world.x, 150);
            try expect.equal(world.y, 260);
        }
    };

    pub const KEEP_TRANSFORM = struct {
        test "setParentKeepTransform preserves world position" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 100, 200);
            const child = createEntityAt(&game, 50, 60);

            // Before parenting, world pos = local pos = (50, 60)
            try game.hierarchy.setParentKeepTransform(child, parent, false, false);

            // World position should still be (50, 60)
            const world = game.pos.getWorldPosition(child).?;
            try expect.equal(world.x, 50);
            try expect.equal(world.y, 60);

            // Local position should be adjusted: (50 - 100, 60 - 200) = (-50, -140)
            const pos = game.pos.getLocalPosition(child).?;
            try expect.equal(pos.x, -50);
            try expect.equal(pos.y, -140);
        }

        test "setParentKeepTransform preserves world position with deep parent" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const grandparent = createEntityAt(&game, 10, 20);
            const parent = createEntityAt(&game, 30, 40);
            try game.hierarchy.setParent(parent, grandparent);
            // Parent world pos = (10+30, 20+40) = (40, 60)

            const child = createEntityAt(&game, 100, 100);

            try game.hierarchy.setParentKeepTransform(child, parent, false, false);

            // World position should still be (100, 100)
            const world = game.pos.getWorldPosition(child).?;
            try expect.equal(world.x, 100);
            try expect.equal(world.y, 100);

            // Local offset = (100 - 40, 100 - 60) = (60, 40)
            const pos = game.pos.getLocalPosition(child).?;
            try expect.equal(pos.x, 60);
            try expect.equal(pos.y, 40);
        }
    };

    pub const INHERITANCE_FLAGS = struct {
        test "setParentWithOptions sets inherit_rotation flag" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 0, 0);
            const child = createEntityAt(&game, 10, 10);

            try game.hierarchy.setParentWithOptions(child, parent, true, false);

            const parent_comp = game.registry.getComponent(child, Parent).?;
            try expect.toBeTrue(parent_comp.inherit_rotation);
            try expect.toBeFalse(parent_comp.inherit_scale);
        }

        test "setParentWithOptions sets inherit_scale flag" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const parent = createEntityAt(&game, 0, 0);
            const child = createEntityAt(&game, 10, 10);

            try game.hierarchy.setParentWithOptions(child, parent, false, true);

            const parent_comp = game.registry.getComponent(child, Parent).?;
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
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 200, 100);
        const child = createEntityAt(&game, 50, 30);
        try game.hierarchy.setParent(child, parent);

        // World = (250, 130)
        const world_before = game.pos.getWorldPosition(child).?;

        // Detach keeping world position
        game.hierarchy.removeParentKeepTransform(child);
        const world_detached = game.pos.getWorldPosition(child).?;
        try expect.equal(world_detached.x, world_before.x);
        try expect.equal(world_detached.y, world_before.y);

        // Re-attach keeping world position
        try game.hierarchy.setParentKeepTransform(child, parent, false, false);
        const world_reattached = game.pos.getWorldPosition(child).?;
        try expect.equal(world_reattached.x, world_before.x);
        try expect.equal(world_reattached.y, world_before.y);

        // Local offset should be back to original
        const pos = game.pos.getLocalPosition(child).?;
        try expect.equal(pos.x, 50);
        try expect.equal(pos.y, 30);
    }

    test "reparent between two parents preserves world position" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent_a = createEntityAt(&game, 100, 0);
        const parent_b = createEntityAt(&game, 0, 100);
        const child = createEntityAt(&game, 20, 30);
        try game.hierarchy.setParent(child, parent_a);

        // World = (120, 30)
        const world_before = game.pos.getWorldPosition(child).?;
        try expect.equal(world_before.x, 120);
        try expect.equal(world_before.y, 30);

        // Detach with keep, re-attach to parent_b with keep
        game.hierarchy.removeParentKeepTransform(child);
        try game.hierarchy.setParentKeepTransform(child, parent_b, false, false);

        const world_after = game.pos.getWorldPosition(child).?;
        try expect.equal(world_after.x, 120);
        try expect.equal(world_after.y, 30);

        // Local offset from parent_b: (120 - 0, 30 - 100) = (120, -70)
        const pos = game.pos.getLocalPosition(child).?;
        try expect.equal(pos.x, 120);
        try expect.equal(pos.y, -70);
    }
};

// ============================================
// DIRTY PROPAGATION — marking parent dirty propagates to children
// ============================================

pub const DIRTY_PROPAGATION = struct {
    test "markPositionDirty on parent marks tracked child dirty" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const child = createEntityAt(&game, 10, 10);
        try game.hierarchy.setParent(child, parent);

        // Track both entities so they appear in the pipeline
        try game.pipeline.trackEntity(parent, .none);
        try game.pipeline.trackEntity(child, .none);

        // Clear dirty flags manually
        game.pipeline.tracked.getPtr(parent).?.position_dirty = false;
        game.pipeline.tracked.getPtr(child).?.position_dirty = false;

        // Mark parent dirty — child should also become dirty
        game.pipeline.markPositionDirty(parent);

        try expect.toBeTrue(game.pipeline.tracked.getPtr(parent).?.position_dirty);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(child).?.position_dirty);
    }

    test "markPositionDirty propagates through deep hierarchy" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const grandparent = createEntityAt(&game, 0, 0);
        const parent = createEntityAt(&game, 0, 0);
        const child = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(parent, grandparent);
        try game.hierarchy.setParent(child, parent);

        try game.pipeline.trackEntity(grandparent, .none);
        try game.pipeline.trackEntity(parent, .none);
        try game.pipeline.trackEntity(child, .none);

        // Clear dirty flags
        game.pipeline.tracked.getPtr(grandparent).?.position_dirty = false;
        game.pipeline.tracked.getPtr(parent).?.position_dirty = false;
        game.pipeline.tracked.getPtr(child).?.position_dirty = false;

        // Mark grandparent dirty — both parent and child should become dirty
        game.pipeline.markPositionDirty(grandparent);

        try expect.toBeTrue(game.pipeline.tracked.getPtr(grandparent).?.position_dirty);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(parent).?.position_dirty);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(child).?.position_dirty);
    }

    test "markPositionDirty skips untracked children but marks tracked grandchildren" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const middle = createEntityAt(&game, 0, 0); // not tracked
        const grandchild = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(middle, parent);
        try game.hierarchy.setParent(grandchild, middle);

        // Only track parent and grandchild (middle is untracked)
        try game.pipeline.trackEntity(parent, .none);
        try game.pipeline.trackEntity(grandchild, .none);

        game.pipeline.tracked.getPtr(parent).?.position_dirty = false;
        game.pipeline.tracked.getPtr(grandchild).?.position_dirty = false;

        game.pipeline.markPositionDirty(parent);

        try expect.toBeTrue(game.pipeline.tracked.getPtr(parent).?.position_dirty);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(grandchild).?.position_dirty);
    }

    test "markPositionDirty does not affect siblings" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const child_a = createEntityAt(&game, 0, 0);
        const child_b = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(child_a, parent);
        try game.hierarchy.setParent(child_b, parent);

        try game.pipeline.trackEntity(child_a, .none);
        try game.pipeline.trackEntity(child_b, .none);

        game.pipeline.tracked.getPtr(child_a).?.position_dirty = false;
        game.pipeline.tracked.getPtr(child_b).?.position_dirty = false;

        // Mark only child_a dirty — child_b should NOT be affected
        game.pipeline.markPositionDirty(child_a);

        try expect.toBeTrue(game.pipeline.tracked.getPtr(child_a).?.position_dirty);
        try expect.toBeFalse(game.pipeline.tracked.getPtr(child_b).?.position_dirty);
    }
};

// ============================================
// HIERARCHY FLAG UPDATE — setParent/removeParent update cached has_parent
// ============================================

pub const HIERARCHY_FLAG = struct {
    test "setParent updates has_parent flag on tracked entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const child = createEntityAt(&game, 0, 0);

        try game.pipeline.trackEntity(child, .none);
        try expect.toBeFalse(game.pipeline.tracked.getPtr(child).?.has_parent);

        try game.hierarchy.setParent(child, parent);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(child).?.has_parent);
    }

    test "removeParent clears has_parent flag on tracked entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const child = createEntityAt(&game, 0, 0);

        try game.pipeline.trackEntity(child, .none);
        try game.hierarchy.setParent(child, parent);
        try expect.toBeTrue(game.pipeline.tracked.getPtr(child).?.has_parent);

        game.hierarchy.removeParent(child);
        try expect.toBeFalse(game.pipeline.tracked.getPtr(child).?.has_parent);
    }
};

// ============================================
// ERROR CASES
// ============================================

pub const ERROR_CASES = struct {
    test "setParent(e, e) returns SelfParenting" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 0, 0);
        try std.testing.expectError(error.SelfParenting, game.hierarchy.setParent(e, e));
    }

    test "setParent creating cycle returns CircularHierarchy" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const a = createEntityAt(&game, 0, 0);
        const b = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(b, a);

        // Trying to make a a child of b creates a cycle: a→b→a
        try std.testing.expectError(error.CircularHierarchy, game.hierarchy.setParent(a, b));
    }

    test "setParent creating chain deeper than 32 returns HierarchyTooDeep" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        // Build a chain of 35 entities (indices 0..34).
        // Entity 0 is root; each subsequent entity parents to the previous one.
        // This creates 34 ancestor links from entities[34] to entities[0].
        var entities: [35]Entity = undefined;
        for (&entities, 0..) |*e, i| {
            e.* = createEntityAt(&game, 0, 0);
            if (i > 0) {
                try game.hierarchy.setParent(e.*, entities[i - 1]);
            }
        }

        // Trying to add a child to entities[34] walks 34 parent links,
        // hitting depth 33 which exceeds the limit of 32.
        const child = createEntityAt(&game, 0, 0);
        try std.testing.expectError(error.HierarchyTooDeep, game.hierarchy.setParent(child, entities[34]));
    }
};

// ============================================
// QUERY METHODS
// ============================================

pub const QUERY_METHODS = struct {
    test "getParent returns parent entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const child = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(child, parent);

        const got = game.hierarchy.getParent(child);
        try expect.toBeTrue(got != null);
        try expect.toBeTrue(got.? == parent);
    }

    test "getParent returns null for root" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 0, 0);
        try expect.toBeTrue(game.hierarchy.getParent(e) == null);
    }

    test "getChildren returns children slice" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const child1 = createEntityAt(&game, 0, 0);
        const child2 = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(child1, parent);
        try game.hierarchy.setParent(child2, parent);

        const children = game.hierarchy.getChildren(parent);
        try expect.equal(children.len, 2);
    }

    test "getChildren returns empty for childless entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 0, 0);
        const children = game.hierarchy.getChildren(e);
        try expect.equal(children.len, 0);
    }

    test "hasChildren returns true when entity has children" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const child = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(child, parent);

        try expect.toBeTrue(game.hierarchy.hasChildren(parent));
    }

    test "hasChildren returns false for childless entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 0, 0);
        try expect.toBeFalse(game.hierarchy.hasChildren(e));
    }

    test "isRoot returns true for unparented entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const e = createEntityAt(&game, 0, 0);
        try expect.toBeTrue(game.hierarchy.isRoot(e));
    }

    test "isRoot returns false for parented entity" {
        var game = createTestGame();
        fixTestGamePointers(&game);
        defer deinitTestGame(&game);

        const parent = createEntityAt(&game, 0, 0);
        const child = createEntityAt(&game, 0, 0);
        try game.hierarchy.setParent(child, parent);

        try expect.toBeFalse(game.hierarchy.isRoot(child));
    }
};
