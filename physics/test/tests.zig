//! Physics Module Tests
//!
//! BDD-style tests using zspec for labelle-physics.

const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const physics = @import("labelle-physics");

const PWorld = physics.PhysicsWorld;
const RBody = physics.RigidBody;
const Coll = physics.Collider;

test {
    zspec.runAll(@This());
}

pub const PhysicsWorldTests = struct {
    test "can be initialized with gravity" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        // World should be initialized
        try expect.toBeTrue(world.entities().len == 0);
    }

    test "can create static bodies" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .static }, .{ .x = 100, .y = 200 });

        try expect.toBeTrue(world.entities().len == 1);
    }

    test "can create dynamic bodies" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .dynamic }, .{ .x = 100, .y = 100 });

        try expect.toBeTrue(world.entities().len == 1);
    }

    test "can add box colliders" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .dynamic }, .{ .x = 100, .y = 100 });
        try world.addCollider(entity_id, Coll{
            .shape = .{ .box = .{ .width = 50, .height = 50 } },
            .restitution = 0.5,
        });

        try expect.toBeTrue(world.entities().len == 1);
    }

    test "can add circle colliders" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .dynamic }, .{ .x = 100, .y = 100 });
        try world.addCollider(entity_id, Coll{
            .shape = .{ .circle = .{ .radius = 25 } },
            .restitution = 0.7,
        });

        try expect.toBeTrue(world.entities().len == 1);
    }

    test "updates positions during simulation" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .dynamic }, .{ .x = 100, .y = 100 });
        try world.addCollider(entity_id, Coll{
            .shape = .{ .box = .{ .width = 50, .height = 50 } },
        });

        const initial_pos = world.getPosition(entity_id).?;
        const initial_y = initial_pos[1];

        // Simulate for a bit
        var elapsed: f32 = 0;
        while (elapsed < 1.0) : (elapsed += 1.0 / 60.0) {
            world.update(1.0 / 60.0);
        }

        const final_pos = world.getPosition(entity_id).?;
        const final_y = final_pos[1];

        // Body should have fallen (Y increased due to gravity)
        try expect.toBeTrue(final_y > initial_y);
    }

    test "static bodies don't move" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .static }, .{ .x = 100, .y = 200 });
        try world.addCollider(entity_id, Coll{
            .shape = .{ .box = .{ .width = 100, .height = 20 } },
        });

        const initial_pos = world.getPosition(entity_id).?;

        // Simulate for a bit
        var elapsed: f32 = 0;
        while (elapsed < 1.0) : (elapsed += 1.0 / 60.0) {
            world.update(1.0 / 60.0);
        }

        const final_pos = world.getPosition(entity_id).?;

        // Static body should not have moved
        try std.testing.expectApproxEqAbs(initial_pos[0], final_pos[0], 0.001);
        try std.testing.expectApproxEqAbs(initial_pos[1], final_pos[1], 0.001);
    }

    test "can remove bodies" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .dynamic }, .{ .x = 100, .y = 100 });

        try expect.toBeTrue(world.entities().len == 1);

        world.destroyBody(entity_id);

        try expect.toBeTrue(world.entities().len == 0);
    }

    test "returns error for chain shapes" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .static }, .{ .x = 0, .y = 0 });

        const chain_collider = Coll{
            .shape = .{ .chain = .{ .vertices = &.{}, .loop = false } },
        };

        try std.testing.expectError(
            error.ChainShapeNotImplemented,
            world.addCollider(entity_id, chain_collider),
        );
    }

    test "can add box collider with offset" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .dynamic }, .{ .x = 100, .y = 100 });
        try world.addCollider(entity_id, Coll{
            .shape = .{ .box = .{ .width = 50, .height = 50 } },
            .offset = .{ 25, 0 }, // Offset to the right
        });

        try expect.toBeTrue(world.entities().len == 1);
    }

    test "can add box collider with offset and rotation" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .dynamic }, .{ .x = 100, .y = 100 });
        try world.addCollider(entity_id, Coll{
            .shape = .{ .box = .{ .width = 50, .height = 50 } },
            .offset = .{ 25, 0 },
            .angle = std.math.pi / 4.0, // 45 degree rotation
        });

        try expect.toBeTrue(world.entities().len == 1);
    }

    test "can add circle collider with offset" {
        var world = try PWorld.init(std.testing.allocator, .{ 0, 980 });
        defer world.deinit();

        const entity_id: u64 = 1;
        try world.createBody(entity_id, RBody{ .body_type = .dynamic }, .{ .x = 100, .y = 100 });
        try world.addCollider(entity_id, Coll{
            .shape = .{ .circle = .{ .radius = 25 } },
            .offset = .{ 50, 0 }, // Offset to the right
        });

        try expect.toBeTrue(world.entities().len == 1);
    }
};
