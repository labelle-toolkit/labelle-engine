// Position Inheritance Interactive Demo (Declarative Syntax)
//
// Visual demonstration of position inheritance using declarative .parent syntax:
// - Parent-child relationships are defined in scenes/hierarchy_demo.zon
// - Arrow keys: Move parent (red circle)
// - Q/E: Rotate parent
// - D: Detach/reattach child from parent
// - Space: Reset positions
// - ESC: Quit

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;

var parent_entity: ?engine.Entity = null;
var child_entity: ?engine.Entity = null;
var grandchild_entity: ?engine.Entity = null;
var child_attached: bool = true; // Track if child is attached to parent

const MOVE_SPEED: f32 = 200.0;
const ROTATE_SPEED: f32 = 2.0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;

    std.debug.print("\n=== Position Inheritance Demo (Declarative Syntax) ===\n", .{});
    std.debug.print("Parent-child relationships are defined in the scene .zon file!\n", .{});
    std.debug.print("Controls:\n", .{});
    std.debug.print("  Arrow keys: Move parent (red)\n", .{});
    std.debug.print("  Q/E: Rotate parent (children orbit!)\n", .{});
    std.debug.print("  D: Detach/reattach child from parent\n", .{});
    std.debug.print("  Space: Reset positions\n", .{});
    std.debug.print("  ESC: Quit\n\n", .{});

    // Find entities by prefab name from scene
    for (scene.entities.items) |entity_instance| {
        if (entity_instance.prefab_name) |name| {
            if (std.mem.eql(u8, name, "parent_circle")) {
                parent_entity = entity_instance.entity;
            } else if (std.mem.eql(u8, name, "child_circle")) {
                child_entity = entity_instance.entity;
            } else if (std.mem.eql(u8, name, "grandchild_circle")) {
                grandchild_entity = entity_instance.entity;
            }
        }
    }

    // Hierarchy is now set up declaratively in the scene .zon file!
    // No need to call game.setParentWithOptions() here.
    if (parent_entity != null and child_entity != null and grandchild_entity != null) {
        std.debug.print("Found all prefab entities!\n", .{});
        std.debug.print("Hierarchy: Parent (red) -> Child (green) -> Grandchild (blue)\n", .{});
        std.debug.print("Rotation inheritance is enabled via .inherit_rotation = true\n\n", .{});
    } else {
        std.debug.print("Warning: Could not find all prefab entities\n", .{});
    }
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    const input = game.getInput();
    const parent = parent_entity orelse return;
    const child = child_entity orelse return;

    // Quit on ESC
    if (input.isKeyPressed(.escape)) {
        game.quit();
        return;
    }

    // Move parent with arrow keys
    var dx: f32 = 0;
    var dy: f32 = 0;

    if (input.isKeyDown(.right)) dx += MOVE_SPEED * dt;
    if (input.isKeyDown(.left)) dx -= MOVE_SPEED * dt;
    if (input.isKeyDown(.up)) dy += MOVE_SPEED * dt;
    if (input.isKeyDown(.down)) dy -= MOVE_SPEED * dt;

    if (dx != 0 or dy != 0) {
        game.moveLocalPosition(parent, dx, dy);
    }

    // Rotate parent with Q/E
    if (game.getLocalPosition(parent)) |pos| {
        var rotated = false;
        if (input.isKeyDown(.q)) {
            pos.rotation += ROTATE_SPEED * dt;
            rotated = true;
        }
        if (input.isKeyDown(.e)) {
            pos.rotation -= ROTATE_SPEED * dt;
            rotated = true;
        }
        if (rotated) {
            // Mark parent and children dirty so render pipeline picks up changes
            game.getPipeline().markPositionDirty(parent);
            game.getPipeline().markPositionDirty(child);
            if (grandchild_entity) |gc| {
                game.getPipeline().markPositionDirty(gc);
            }
        }
    }

    // Detach/reattach child with D
    if (input.isKeyPressed(.d)) {
        if (child_attached) {
            // Detach child from parent
            game.removeParent(child);
            child_attached = false;
            std.debug.print("Child DETACHED from parent (green circle now independent)\n", .{});
        } else {
            // Reattach child to parent
            game.setParentWithOptions(child, parent, true, false) catch |err| {
                std.debug.print("Failed to reattach child: {}\n", .{err});
                return;
            };
            child_attached = true;
            std.debug.print("Child REATTACHED to parent (green circle follows again)\n", .{});
        }
    }

    // Reset with Space
    if (input.isKeyPressed(.space)) {
        resetPositions(game);
        std.debug.print("Positions reset\n", .{});
    }
}

fn resetPositions(game: *Game) void {
    const parent = parent_entity orelse return;
    const child = child_entity orelse return;
    const grandchild = grandchild_entity orelse return;

    // Reattach child if detached
    if (!child_attached) {
        game.setParentWithOptions(child, parent, true, false) catch {};
        child_attached = true;
        std.debug.print("Child reattached during reset\n", .{});
    }

    // Reset parent position and rotation
    if (game.getLocalPosition(parent)) |pos| {
        pos.x = 400;
        pos.y = 300;
        pos.rotation = 0;
    }

    // Reset child local offset (from scene definition)
    game.setLocalPositionXY(child, 120, 0);

    // Reset grandchild local offset (from scene definition)
    game.setLocalPositionXY(grandchild, 70, 0);

    // Mark all dirty
    game.getPipeline().markPositionDirty(parent);
    game.getPipeline().markPositionDirty(child);
    game.getPipeline().markPositionDirty(grandchild);
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    std.debug.print("\nDemo ended.\n", .{});
}
