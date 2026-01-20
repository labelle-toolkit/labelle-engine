const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const ecs = @import("ecs");
const Game = engine.Game;
const Shape = engine.Shape;
const Sprite = engine.Sprite;

test {
    zspec.runAll(@This());
}

// =============================================================================
// Issue #265: setGizmoEntityVisible should use set() instead of add()
// =============================================================================
//
// The bug: When toggling gizmo visibility, the code used registry.add() to
// update the component. But add() asserts that the entity doesn't already
// have the component. Since we're toggling visibility on an existing component,
// this caused a panic: "assert(!self.contains(entity)) - assertion failure"
//
// The fix: Use registry.set() which handles both adding new components and
// updating existing ones.
//
// These tests verify the correct behavior of set() for component updates.

pub const SET_VS_ADD_BEHAVIOR = struct {
    const TestVisual = struct {
        visible: bool = true,
        value: i32 = 0,
    };

    test "set() can update an existing component without error" {
        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        const entity = registry.create();

        // Add initial component
        registry.add(entity, TestVisual{ .visible = true, .value = 1 });

        // Verify it was added
        const initial = registry.tryGet(TestVisual, entity);
        try expect.toBeTrue(initial != null);
        try expect.toBeTrue(initial.?.visible);
        try expect.equal(initial.?.value, 1);

        // Use set() to update - this should NOT panic (unlike add())
        registry.set(entity, TestVisual{ .visible = false, .value = 2 });

        // Verify it was updated
        const updated = registry.tryGet(TestVisual, entity);
        try expect.toBeTrue(updated != null);
        try expect.toBeFalse(updated.?.visible);
        try expect.equal(updated.?.value, 2);
    }

    test "set() can toggle visibility multiple times" {
        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        const entity = registry.create();

        // Add initial component with visible = true
        registry.add(entity, TestVisual{ .visible = true });

        // Toggle to false
        var comp = registry.tryGet(TestVisual, entity).?.*;
        comp.visible = false;
        registry.set(entity, comp);
        try expect.toBeFalse(registry.tryGet(TestVisual, entity).?.visible);

        // Toggle back to true
        comp = registry.tryGet(TestVisual, entity).?.*;
        comp.visible = true;
        registry.set(entity, comp);
        try expect.toBeTrue(registry.tryGet(TestVisual, entity).?.visible);

        // Toggle to false again
        comp = registry.tryGet(TestVisual, entity).?.*;
        comp.visible = false;
        registry.set(entity, comp);
        try expect.toBeFalse(registry.tryGet(TestVisual, entity).?.visible);
    }

    test "set() works on entity that does not have component (adds it)" {
        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        const entity = registry.create();

        // Entity has no TestVisual yet
        try expect.toBeTrue(registry.tryGet(TestVisual, entity) == null);

        // set() should add it
        registry.set(entity, TestVisual{ .visible = false, .value = 42 });

        // Verify it was added
        const comp = registry.tryGet(TestVisual, entity);
        try expect.toBeTrue(comp != null);
        try expect.toBeFalse(comp.?.visible);
        try expect.equal(comp.?.value, 42);
    }

    test "visibility toggle pattern matches setGizmoEntityVisible fix" {
        // This test mirrors the exact pattern used in setGizmoEntityVisible
        var registry = ecs.Registry.init(std.testing.allocator);
        defer registry.deinit();

        const entity = registry.create();

        // Simulate initial gizmo creation with visible component
        registry.add(entity, Shape.circle(10));

        // Simulate toggling visibility (the fixed code path)
        if (registry.tryGet(Shape, entity)) |comp| {
            var updated = comp.*;
            const new_visibility = !updated.visible; // toggle
            if (updated.visible != new_visibility) {
                updated.visible = new_visibility;
                // This is the FIX: use set() instead of add()
                registry.set(entity, updated);
            }
        }

        // Verify the toggle worked
        try expect.toBeFalse(registry.tryGet(Shape, entity).?.visible);

        // Toggle again
        if (registry.tryGet(Shape, entity)) |comp| {
            var updated = comp.*;
            updated.visible = true;
            registry.set(entity, updated);
        }

        try expect.toBeTrue(registry.tryGet(Shape, entity).?.visible);
    }
};

// =============================================================================
// Issue #266: renderStandaloneGizmos should use drawShapeWorld for world space
// =============================================================================
//
// The bug: Standalone gizmos drawn with game.drawLine() etc. were rendered in
// screen space instead of world space. When the camera moved, the gizmos stayed
// fixed on screen instead of moving with the world.
//
// The fix: Use drawShapeWorld() instead of drawShape() in renderStandaloneGizmos()
// so gizmos are transformed through the camera system.
//
// These tests verify the Game API exports the correct methods.

pub const STANDALONE_GIZMO_API = struct {
    test "Game has renderStandaloneGizmos method" {
        try expect.toBeTrue(@hasDecl(Game, "renderStandaloneGizmos"));
    }

    test "Game has drawGizmo method" {
        try expect.toBeTrue(@hasDecl(Game, "drawGizmo"));
    }

    test "Game has drawLine method" {
        try expect.toBeTrue(@hasDecl(Game, "drawLine"));
    }

    test "Game has drawArrow method" {
        try expect.toBeTrue(@hasDecl(Game, "drawArrow"));
    }

    test "Game has drawRay method" {
        try expect.toBeTrue(@hasDecl(Game, "drawRay"));
    }

    test "Game has drawCircle method" {
        try expect.toBeTrue(@hasDecl(Game, "drawCircle"));
    }

    test "Game has drawRect method" {
        try expect.toBeTrue(@hasDecl(Game, "drawRect"));
    }

    test "Game has clearGizmos method" {
        try expect.toBeTrue(@hasDecl(Game, "clearGizmos"));
    }

    test "Game has GizmoShape type for standalone gizmos" {
        try expect.toBeTrue(@hasDecl(Game, "GizmoShape"));
    }
};

pub const GIZMO_VISIBILITY_API = struct {
    test "Game has setGizmosEnabled method" {
        try expect.toBeTrue(@hasDecl(Game, "setGizmosEnabled"));
    }

    test "Game has areGizmosEnabled method" {
        try expect.toBeTrue(@hasDecl(Game, "areGizmosEnabled"));
    }
};

// =============================================================================
// RetainedEngine world-space drawing API
// =============================================================================
//
// These tests verify that the retained engine exposes both screen-space and
// world-space drawing methods, which is essential for the #266 fix.

pub const RETAINED_ENGINE_DRAW_API = struct {
    const RetainedEngine = engine.RetainedEngine;

    test "RetainedEngine has drawShapeWorld method (world-space, camera-transformed)" {
        try expect.toBeTrue(@hasDecl(RetainedEngine, "drawShapeWorld"));
    }

    test "RetainedEngine has drawShapeScreen method (screen-space, fixed)" {
        try expect.toBeTrue(@hasDecl(RetainedEngine, "drawShapeScreen"));
    }

    test "RetainedEngine has drawShape method (legacy, screen-space)" {
        try expect.toBeTrue(@hasDecl(RetainedEngine, "drawShape"));
    }

    test "RetainedEngine has drawShapeWorldRotated method" {
        try expect.toBeTrue(@hasDecl(RetainedEngine, "drawShapeWorldRotated"));
    }

    test "RetainedEngine has drawShapeScreenRotated method" {
        try expect.toBeTrue(@hasDecl(RetainedEngine, "drawShapeScreenRotated"));
    }
};
