const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Sprite = engine.Sprite;
const Entity = engine.Entity;

// Import components
const Parent_data = @import("../components/parent_data.zig").Parent_data;
const Children = @import("../components/children.zig").Children;
const Child_data = @import("../components/child_data.zig").Child_data;

pub fn init(game: *Game, scene: *Scene) void {
    const registry = game.getRegistry();

    std.debug.assert(scene.entities.items.len > 0);

    var found_qux = false;

    // Find and validate the qux prefab entity
    for (scene.entities.items) |entity_instance| {
        // Only validate entities from the "qux" prefab
        const prefab_name = entity_instance.prefab_name orelse continue;
        if (!std.mem.eql(u8, prefab_name, "qux")) continue;

        found_qux = true;
        const entity = entity_instance.entity;

        // Check Parent_data component
        if (registry.tryGet(Parent_data, entity)) |parent_data| {
            std.debug.assert(parent_data.value == 42);
            std.debug.print("Parent_data.value = {} (expected 42)\n", .{parent_data.value});
        } else {
            @panic("Expected Parent_data component on qux entity");
        }

        // Check Children component with child entities
        if (registry.tryGet(Children, entity)) |children| {
            std.debug.assert(children.items.len == 1);
            std.debug.print("Children.items.len = {} (expected 1)\n", .{children.items.len});

            // Verify the child entity has Child_data component
            const child_entity = children.items[0];
            if (registry.tryGet(Child_data, child_entity)) |child_data| {
                std.debug.assert(child_data.val == 7);
                std.debug.print("Child_data.val = {} (expected 7)\n", .{child_data.val});
            } else {
                @panic("Expected Child_data component on child entity");
            }

            // Verify child entity has Sprite component (from prefab reference)
            if (registry.tryGet(Sprite, child_entity)) |sprite| {
                std.debug.assert(std.mem.eql(u8, sprite.sprite_name, "child_node"));
                std.debug.print("Child Sprite = {s} (expected child_node)\n", .{sprite.sprite_name});
            } else {
                @panic("Expected Sprite component on child entity (prefab reference)");
            }

            // Verify child entity position (parent at 100,200 + local position offset 20,30 = 120,230)
            if (registry.tryGet(Position, child_entity)) |child_pos| {
                std.debug.assert(child_pos.x == 120);
                std.debug.assert(child_pos.y == 230);
                std.debug.print("Child position = ({}, {}) (expected 120, 230)\n", .{ child_pos.x, child_pos.y });
            } else {
                @panic("Expected Position component on child entity");
            }
        } else {
            @panic("Expected Children component on qux entity");
        }

        // Check entity position
        if (registry.tryGet(Position, entity)) |pos| {
            std.debug.assert(pos.x == 100);
            std.debug.assert(pos.y == 200);
            std.debug.print("Entity position = ({}, {}) (expected 100, 200)\n", .{ pos.x, pos.y });
        } else {
            @panic("Expected Position component on qux entity");
        }
    }

    if (!found_qux) {
        @panic("No qux prefab entity found in scene");
    }

    std.debug.print("All validations passed!\n", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = game;
    _ = scene;
    _ = dt;
}
