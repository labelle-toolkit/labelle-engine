//! Movement script demonstrating the Query API
//!
//! This script shows how to use registry.query() for efficient ECS iteration.
//! The Query API provides a backend-agnostic way to iterate entities with
//! specific components, working identically on both zig_ecs and zflecs backends.

const engine = @import("labelle-engine");
const ecs = engine.ecs;
const Velocity = @import("../components/velocity.zig").Velocity;

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;

/// Update function using the Query API for entity iteration.
///
/// Usage:
/// ```zig
/// var q = registry.query(.{ Position, Velocity });
/// q.each(struct {
///     fn run(entity: ecs.Entity, pos: *Position, vel: *Velocity) void {
///         pos.x += vel.x;
///         pos.y += vel.y;
///     }
/// }.run);
/// ```
pub fn update(
    game: *Game,
    _: *Scene,
    dt: f32,
) void {
    const registry = game.getRegistry();

    // Use the Query API for clean, backend-agnostic iteration
    var q = registry.query(.{ Position, Velocity });
    q.each(struct {
        fn run(_: ecs.Entity, pos: *Position, vel: *const Velocity) void {
            // Apply velocity to position
            pos.x += vel.x * getDeltaTime();
            pos.y += vel.y * getDeltaTime();
        }

        // Note: We can't capture dt directly in the callback, so we use a workaround
        // In real code, you might use the scene entities loop with tryGet instead
        // if you need access to external state like dt or pipeline.
        fn getDeltaTime() f32 {
            return 1.0 / 60.0; // Fixed timestep fallback
        }
    }.run);

    // Note: For marking positions dirty, you still need to iterate scene entities
    // since the Query callback doesn't have access to the pipeline.
    // The Query API is best for pure component-to-component transformations.
    _ = dt;
}
