const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Entity = engine.Entity;

// Import components
const Foo = @import("../components/foo.zig").Foo;
const Bar = @import("../components/bar.zig").Bar;
const Baz = @import("../components/baz.zig").Baz;

pub fn init(game: *Game, scene: *Scene) void {
    const registry = game.getRegistry();

    // Validate that qux entity exists and has required components
    for (scene.entities.items) |entity_instance| {
        const entity = entity_instance.entity;

        // Check if entity has Foo component
        if (registry.tryGet(Foo, entity)) |foo| {
            std.debug.assert(foo.value == 42);
            std.debug.print("Foo.value = {} (expected 42)\n", .{foo.value});
        }

        // Check if entity has Bar component with child entities
        if (registry.tryGet(Bar, entity)) |bar| {
            std.debug.assert(bar.bazzes.len == 1);
            std.debug.print("Bar.bazzes.len = {} (expected 1)\n", .{bar.bazzes.len});

            // Verify the child entity has Baz component
            const child_entity = bar.bazzes[0];
            if (registry.tryGet(Baz, child_entity)) |baz| {
                std.debug.assert(baz.val == 7);
                std.debug.print("Child Baz.val = {} (expected 7)\n", .{baz.val});
            }

            // Verify child entity position (relative to parent)
            if (registry.tryGet(Position, child_entity)) |child_pos| {
                // Parent at (100, 200), child offset (0, 0) = child at (100, 200)
                std.debug.print("Child position = ({}, {})\n", .{ child_pos.x, child_pos.y });
            }
        }

        // Check entity position from scene
        if (registry.tryGet(Position, entity)) |pos| {
            std.debug.assert(pos.x == 100);
            std.debug.assert(pos.y == 200);
            std.debug.print("Entity position = ({}, {}) (expected 100, 200)\n", .{ pos.x, pos.y });
        }
    }

    std.debug.print("All validations passed!\n", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = game;
    _ = scene;
    _ = dt;
}
