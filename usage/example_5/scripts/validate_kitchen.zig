const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Entity = engine.Entity;

// Import components
const Children = @import("../components/children.zig").Children;
const Workstation = @import("../components/workstation.zig").Workstation;
const Movement_node = @import("../components/movement_node.zig").Movement_node;

pub fn init(game: *Game, scene: *Scene) void {
    const registry = game.getRegistry();

    std.debug.assert(scene.entities.items.len > 0);

    var found_kitchen = false;

    // Find and validate the kitchen prefab entity
    for (scene.entities.items) |entity_instance| {
        const prefab_name = entity_instance.prefab_name orelse continue;
        if (!std.mem.eql(u8, prefab_name, "kitchen")) continue;

        found_kitchen = true;
        const kitchen_entity = entity_instance.entity;

        // Check kitchen position
        if (registry.tryGet(Position, kitchen_entity)) |pos| {
            std.debug.assert(pos.x == 100);
            std.debug.assert(pos.y == 100);
            std.debug.print("Kitchen position = ({}, {}) (expected 100, 100)\n", .{ pos.x, pos.y });
        } else {
            @panic("Expected Position component on kitchen entity");
        }

        // Check Children component for workstation
        if (registry.tryGet(Children, kitchen_entity)) |children| {
            std.debug.assert(children.items.len == 1);
            std.debug.print("Kitchen has {} child (expected 1 workstation)\n", .{children.items.len});

            const workstation_entity = children.items[0];

            // Verify workstation has Workstation component
            if (registry.tryGet(Workstation, workstation_entity)) |ws| {
                std.debug.assert(std.mem.eql(u8, ws.station_type, "prep_counter"));
                std.debug.assert(ws.is_active == true);
                std.debug.print("Workstation type = '{s}' (expected 'prep_counter')\n", .{ws.station_type});

                // Verify workstation has 3 movement nodes
                std.debug.assert(ws.movement_nodes.len == 3);
                std.debug.print("Workstation has {} movement nodes (expected 3)\n", .{ws.movement_nodes.len});

                // Verify each movement node
                for (ws.movement_nodes, 0..) |node_entity, i| {
                    if (registry.tryGet(Movement_node, node_entity)) |node| {
                        std.debug.assert(node.id == i + 1);
                        std.debug.assert(node.walkable == true);
                        std.debug.print("  Movement_node {} - id={}, walkable={}\n", .{ i, node.id, node.walkable });
                    } else {
                        @panic("Expected Movement_node component on movement node entity");
                    }

                    // Verify node positions (relative to workstation at 150, 130)
                    if (registry.tryGet(Position, node_entity)) |node_pos| {
                        std.debug.print("  Movement_node {} position = ({}, {})\n", .{ i, node_pos.x, node_pos.y });
                    } else {
                        @panic("Expected Position component on movement node entity");
                    }
                }
            } else {
                @panic("Expected Workstation component on workstation entity");
            }

            // Verify workstation position (from Position component: 50, 30)
            if (registry.tryGet(Position, workstation_entity)) |ws_pos| {
                std.debug.assert(ws_pos.x == 50);
                std.debug.assert(ws_pos.y == 30);
                std.debug.print("Workstation position = ({}, {}) (expected 50, 30)\n", .{ ws_pos.x, ws_pos.y });
            } else {
                @panic("Expected Position component on workstation entity");
            }
        } else {
            @panic("Expected Children component on kitchen entity");
        }
    }

    if (!found_kitchen) {
        @panic("No kitchen prefab entity found in scene");
    }

    std.debug.print("All kitchen validations passed!\n", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = game;
    _ = scene;
    _ = dt;
}
