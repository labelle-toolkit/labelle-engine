const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;

var ball_entity: ?engine.Entity = null;
var square_entity: ?engine.Entity = null;
var attached: bool = true;
var direction: f32 = 1.0;

const SPEED: f32 = 300.0;
const MIN_X: f32 = 50.0;
const MAX_X: f32 = 750.0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;

    for (scene.entities.items) |entity_instance| {
        if (entity_instance.prefab_name) |name| {
            if (std.mem.eql(u8, name, "parent_circle")) {
                ball_entity = entity_instance.entity;
            } else if (std.mem.eql(u8, name, "square")) {
                square_entity = entity_instance.entity;
            }
        }
    }
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    const input = game.getInput();
    const ball = ball_entity orelse return;
    const square = square_entity orelse return;

    if (input.isKeyPressed(.escape)) {
        game.quit();
        return;
    }

    // Toggle parent binding with space (preserves world position)
    if (input.isKeyPressed(.space)) {
        if (attached) {
            game.removeParentKeepTransform(square);
            attached = false;
        } else {
            game.setParentKeepTransform(square, ball, false, false) catch {};
            attached = true;
        }
    }

    // Bounce ball left-right
    if (game.getLocalPosition(ball)) |pos| {
        pos.x += SPEED * direction * dt;
        if (pos.x >= MAX_X) {
            pos.x = MAX_X;
            direction = -1.0;
        } else if (pos.x <= MIN_X) {
            pos.x = MIN_X;
            direction = 1.0;
        }
        game.getPipeline().markPositionDirty(ball);
    }
}
