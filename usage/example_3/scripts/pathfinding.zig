// Pathfinding demo script - shows an entity moving along a path
//
// This script creates a grid of nodes and moves a player entity between corners.
// Uses the script lifecycle hooks (init/update/deinit) for proper resource management.
const std = @import("std");
const engine = @import("labelle-engine");
const pathfinding = @import("labelle-pathfinding");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Shape = engine.Shape;
const Color = engine.Color;

// Entity ID for the moving character
const EntityId = u32;
const PLAYER_ID: EntityId = 1;

// Pathfinding engine configuration
const PFConfig = struct {
    pub const Entity = EntityId;
    pub const Context = void;
};
const PFEngine = pathfinding.PathfindingEngine(PFConfig);

// Grid configuration
const GRID_SIZE: usize = 8;
const CELL_SIZE: f32 = 60.0;
const GRID_OFFSET_X: f32 = 100.0;
const GRID_OFFSET_Y: f32 = 60.0;

// Target corners to cycle through
const corners = [_]u32{
    @intCast((GRID_SIZE - 1) * GRID_SIZE + GRID_SIZE - 1), // bottom-right
    @intCast((GRID_SIZE - 1) * GRID_SIZE), // bottom-left
    0, // top-left
    GRID_SIZE - 1, // top-right
};

// Script state (module-level for persistence across update calls)
var pf_engine: ?PFEngine = null;
var current_corner: usize = 0;
var player_entity: ?engine.Entity = null;
var node_entities: [GRID_SIZE * GRID_SIZE]engine.Entity = undefined;
var target_entity: ?engine.Entity = null;
var time_at_target: f32 = 0.0;

// Convert grid position to screen position
fn gridToScreen(gx: usize, gy: usize) struct { x: f32, y: f32 } {
    return .{
        .x = GRID_OFFSET_X + @as(f32, @floatFromInt(gx)) * CELL_SIZE,
        .y = GRID_OFFSET_Y + @as(f32, @floatFromInt(gy)) * CELL_SIZE,
    };
}

// Convert node ID to grid position
fn nodeToGrid(node: u32) struct { x: usize, y: usize } {
    return .{
        .x = node % GRID_SIZE,
        .y = node / GRID_SIZE,
    };
}

/// Called when the scene loads
pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    const allocator = game.allocator;

    // Initialize pathfinding engine
    pf_engine = PFEngine.init(allocator) catch |err| {
        std.debug.print("Failed to initialize pathfinding engine: {}\n", .{err});
        return;
    };
    var pf = &pf_engine.?;

    // Create grid nodes and their visual representations
    for (0..GRID_SIZE) |y| {
        for (0..GRID_SIZE) |x| {
            const node_id: u32 = @intCast(y * GRID_SIZE + x);
            const pos = gridToScreen(x, y);
            pf.addNode(node_id, pos.x, pos.y) catch continue;

            // Create visual node (small gray circle)
            const ecs_entity = game.createEntity();
            game.addPosition(ecs_entity, Position{ .x = pos.x, .y = pos.y });
            game.addShape(ecs_entity, Shape.circle(10.0)) catch continue;
            if (game.getComponent(Shape, ecs_entity)) |shape| {
                shape.color = Color{ .r = 80, .g = 80, .b = 80, .a = 255 };
            }
            node_entities[node_id] = ecs_entity;
        }
    }

    // Connect nodes in a grid pattern (omnidirectional for grid-based movement)
    pf.connectNodes(.{ .omnidirectional = .{
        .max_distance = CELL_SIZE * 1.5, // Slightly more than cell size to catch neighbors
        .max_connections = 4, // 4-directional movement
    } }) catch |err| {
        std.debug.print("Failed to connect nodes: {}\n", .{err});
        return;
    };
    pf.rebuildPaths() catch |err| {
        std.debug.print("Failed to rebuild paths: {}\n", .{err});
        return;
    };

    // Create player entity at top-left
    const start_pos = gridToScreen(0, 0);
    pf.registerEntity(PLAYER_ID, start_pos.x, start_pos.y, 120.0) catch |err| {
        std.debug.print("Failed to register player: {}\n", .{err});
        return;
    };

    // Create visual player (larger blue circle)
    player_entity = game.createEntity();
    game.addPosition(player_entity.?, Position{ .x = start_pos.x, .y = start_pos.y });
    game.addShape(player_entity.?, Shape.circle(22.0)) catch return;
    if (game.getComponent(Shape, player_entity.?)) |shape| {
        shape.color = Color{ .r = 50, .g = 150, .b = 255, .a = 255 };
    }

    // Request initial path to first corner
    pf.requestPath(PLAYER_ID, corners[0]) catch {};

    // Highlight initial target
    target_entity = node_entities[corners[0]];
    if (game.getComponent(Shape, target_entity.?)) |shape| {
        shape.color = Color{ .r = 255, .g = 200, .b = 50, .a = 255 };
        shape.shape.circle.radius = 14.0;
    }

    std.debug.print("Pathfinding Demo started!\n", .{});
    std.debug.print("Grid: {}x{} nodes\n", .{ GRID_SIZE, GRID_SIZE });
    std.debug.print("Entity will move between corners.\n", .{});
}

/// Called every frame
pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    var pf = &(pf_engine orelse return);
    const pe = player_entity orelse return;

    // Update pathfinding simulation
    pf.tick({}, dt);

    // Update player visual position from pathfinding
    if (pf.getPosition(PLAYER_ID)) |pos| {
        game.setPosition(pe, Position{ .x = pos.x, .y = pos.y });
    }

    // Check if we reached the target
    if (!pf.isMoving(PLAYER_ID)) {
        time_at_target += dt;

        // Wait a bit at each corner before moving to next
        if (time_at_target > 0.5) {
            // Reset previous target highlight
            if (target_entity) |te| {
                if (game.getComponent(Shape, te)) |shape| {
                    shape.color = Color{ .r = 80, .g = 80, .b = 80, .a = 255 };
                    shape.shape.circle.radius = 10.0;
                }
            }

            // Move to next corner
            current_corner = (current_corner + 1) % corners.len;
            const new_target = corners[current_corner];
            pf.requestPath(PLAYER_ID, new_target) catch {};
            time_at_target = 0.0;

            const grid_pos = nodeToGrid(new_target);
            std.debug.print("Moving to corner ({}, {})\n", .{ grid_pos.x, grid_pos.y });

            // Highlight new target
            target_entity = node_entities[new_target];
            if (game.getComponent(Shape, target_entity.?)) |shape| {
                shape.color = Color{ .r = 255, .g = 200, .b = 50, .a = 255 };
                shape.shape.circle.radius = 14.0;
            }
        }
    }
}

/// Called when the scene unloads - clean up pathfinding resources
pub fn deinit(game: *Game, scene: *Scene) void {
    _ = scene;

    // Clean up pathfinding engine
    if (pf_engine) |*pf| {
        pf.deinit();
        pf_engine = null;
    }

    // Destroy visual entities created by this script
    // Only cleanup if init succeeded (player_entity was set)
    if (player_entity != null) {
        const registry = game.getRegistry();

        // Destroy player entity
        registry.destroy(player_entity.?);

        // Destroy grid node entities
        for (node_entities) |node_ent| {
            registry.destroy(node_ent);
        }
    }

    // Reset state for potential scene reload
    player_entity = null;
    target_entity = null;
    current_corner = 0;
    time_at_target = 0.0;

    std.debug.print("Pathfinding script cleanup complete.\n", .{});
}
