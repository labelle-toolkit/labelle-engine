const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const ecs = @import("ecs");
const loader = engine.scene.loader;

test {
    zspec.runAll(@This());
}

// ============================================
// DECLARATIVE PARENT-CHILD SCENE FORMAT (RFC #243)
// ============================================

pub const DECLARATIVE_PARENT = struct {
    // Scene with .parent field on entities
    const scene_with_parent = .{
        .name = "parent_test",
        .entities = .{
            .{
                .name = "parent_entity",
                .components = .{
                    .Position = .{ .x = 100, .y = 200 },
                    .Shape = .{ .shape = .{ .circle = .{ .radius = 50 } } },
                },
            },
            .{
                .name = "child_entity",
                .parent = "parent_entity",
                .components = .{
                    .Position = .{ .x = 10, .y = 20 },
                    .Shape = .{ .shape = .{ .circle = .{ .radius = 25 } } },
                },
            },
        },
    };

    // Scene with child defined BEFORE parent (forward reference)
    const scene_with_forward_ref = .{
        .name = "forward_ref_test",
        .entities = .{
            .{
                .name = "child_first",
                .parent = "parent_later",
                .components = .{
                    .Position = .{ .x = 0, .y = 0 },
                    .Shape = .{ .shape = .{ .circle = .{ .radius = 10 } } },
                },
            },
            .{
                .name = "parent_later",
                .components = .{
                    .Position = .{ .x = 50, .y = 50 },
                    .Shape = .{ .shape = .{ .circle = .{ .radius = 30 } } },
                },
            },
        },
    };

    // Scene with inheritance flags
    const scene_with_inheritance = .{
        .name = "inheritance_test",
        .entities = .{
            .{
                .name = "rotating_parent",
                .components = .{
                    .Position = .{ .x = 0, .y = 0 },
                    .Shape = .{ .shape = .{ .circle = .{ .radius = 50 } } },
                },
            },
            .{
                .name = "inheriting_child",
                .parent = "rotating_parent",
                .inherit_rotation = true,
                .inherit_scale = true,
                .components = .{
                    .Position = .{ .x = 30, .y = 0 },
                    .Shape = .{ .shape = .{ .circle = .{ .radius = 15 } } },
                },
            },
        },
    };

    // Scene with parent referenced by ID
    const scene_with_id_parent = .{
        .name = "id_parent_test",
        .entities = .{
            .{
                .id = "unique_parent",
                .name = "parent_entity",
                .components = .{
                    .Position = .{ .x = 0, .y = 0 },
                    .Shape = .{ .shape = .{ .circle = .{ .radius = 50 } } },
                },
            },
            .{
                .name = "child_by_id",
                .parent = "unique_parent",
                .components = .{
                    .Position = .{ .x = 10, .y = 10 },
                    .Shape = .{ .shape = .{ .circle = .{ .radius = 20 } } },
                },
            },
        },
    };

    pub const SCENE_FORMAT = struct {
        test "entity can have .parent field" {
            const child = scene_with_parent.entities[1];
            try expect.toBeTrue(@hasField(@TypeOf(child), "parent"));
            try expect.toBeTrue(std.mem.eql(u8, child.parent, "parent_entity"));
        }

        test "entity without .parent has no parent field" {
            const parent = scene_with_parent.entities[0];
            try expect.toBeFalse(@hasField(@TypeOf(parent), "parent"));
        }

        test "child defined before parent has .parent field (forward ref)" {
            const child = scene_with_forward_ref.entities[0];
            try expect.toBeTrue(@hasField(@TypeOf(child), "parent"));
            try expect.toBeTrue(std.mem.eql(u8, child.parent, "parent_later"));
        }

        test "entity can have .inherit_rotation flag" {
            const child = scene_with_inheritance.entities[1];
            try expect.toBeTrue(@hasField(@TypeOf(child), "inherit_rotation"));
            try expect.toBeTrue(child.inherit_rotation);
        }

        test "entity can have .inherit_scale flag" {
            const child = scene_with_inheritance.entities[1];
            try expect.toBeTrue(@hasField(@TypeOf(child), "inherit_scale"));
            try expect.toBeTrue(child.inherit_scale);
        }

        test "entity without inheritance flags has no inherit fields" {
            const child = scene_with_parent.entities[1];
            try expect.toBeFalse(@hasField(@TypeOf(child), "inherit_rotation"));
            try expect.toBeFalse(@hasField(@TypeOf(child), "inherit_scale"));
        }

        test "parent can be referenced by id" {
            const child = scene_with_id_parent.entities[1];
            try expect.toBeTrue(@hasField(@TypeOf(child), "parent"));
            try expect.toBeTrue(std.mem.eql(u8, child.parent, "unique_parent"));
        }

        test "parent entity can have explicit id" {
            const parent = scene_with_id_parent.entities[0];
            try expect.toBeTrue(@hasField(@TypeOf(parent), "id"));
            try expect.toBeTrue(std.mem.eql(u8, parent.id, "unique_parent"));
        }
    };

    pub const REFERENCE_CONTEXT = struct {
        test "ReferenceContext resolves by name" {
            var ctx = loader.ReferenceContext.init(std.testing.allocator);
            defer ctx.deinit();

            const dummy_entity: ecs.Entity = @bitCast(@as(ecs.EntityBits, 42));
            try ctx.registerNamed("my_parent", dummy_entity);

            const resolved = ctx.resolveByName("my_parent");
            try expect.toBeTrue(resolved != null);
        }

        test "ReferenceContext resolves by id" {
            var ctx = loader.ReferenceContext.init(std.testing.allocator);
            defer ctx.deinit();

            const dummy_entity: ecs.Entity = @bitCast(@as(ecs.EntityBits, 42));
            try ctx.registerId("unique_id", dummy_entity);

            const resolved = ctx.resolveById("unique_id");
            try expect.toBeTrue(resolved != null);
        }

        test "ReferenceContext id resolution takes priority in fallback" {
            var ctx = loader.ReferenceContext.init(std.testing.allocator);
            defer ctx.deinit();

            const entity_by_id: ecs.Entity = @bitCast(@as(ecs.EntityBits, 1));
            const entity_by_name: ecs.Entity = @bitCast(@as(ecs.EntityBits, 2));

            try ctx.registerId("shared_key", entity_by_id);
            try ctx.registerNamed("shared_key", entity_by_name);

            // ID should take priority when both match
            const by_id = ctx.resolveById("shared_key");
            try expect.toBeTrue(by_id != null);

            const by_name = ctx.resolveByName("shared_key");
            try expect.toBeTrue(by_name != null);
        }

        test "ReferenceContext returns null for unknown name" {
            var ctx = loader.ReferenceContext.init(std.testing.allocator);
            defer ctx.deinit();

            const resolved = ctx.resolveByName("nonexistent");
            try expect.toBeTrue(resolved == null);
        }

        test "ReferenceContext can queue pending parent" {
            var ctx = loader.ReferenceContext.init(std.testing.allocator);
            defer ctx.deinit();

            const child: ecs.Entity = @bitCast(@as(ecs.EntityBits, 1));
            try ctx.addPendingParent(.{
                .child_entity = child,
                .parent_key = "my_parent",
                .inherit_rotation = true,
                .inherit_scale = false,
            });

            try expect.equal(ctx.pending_parents.items.len, 1);
            try expect.toBeTrue(ctx.pending_parents.items[0].inherit_rotation);
            try expect.toBeFalse(ctx.pending_parents.items[0].inherit_scale);
        }
    };
};
