const std = @import("std");
const expect = @import("zspec").expect;
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const JsoncParser = jsonc.JsoncParser;
const deserialize = jsonc.deserialize;
const scene_loader = jsonc.scene_loader;
const Scene = scene_loader.Scene;
const Entity = scene_loader.Entity;
const PrefabCache = scene_loader.PrefabCache;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn parseJsonc(allocator: std.mem.Allocator, source: []const u8) !Value {
    var p = JsoncParser.init(allocator, source);
    return p.parse();
}

// ── loadSceneFromValue ──

pub const loadSceneFromValue = struct {
    pub const minimal_scene = struct {
        test "parses name and scripts" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{
                \\    "name": "test_scene",
                \\    "scripts": ["script_a", "script_b"],
                \\    "entities": [
                \\        { "components": { "Position": { "x": 10, "y": 20 } } },
                \\        { "components": { "Position": { "x": 30, "y": 40 }, "Worker": {} } }
                \\    ]
                \\}
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");

            try expect.equal(scene.name, "test_scene");
            try expect.equal(scene.scripts.len, 2);
            try expect.equal(scene.scripts[0], "script_a");
            try expect.equal(scene.scripts[1], "script_b");
            try expect.equal(scene.entities.len, 2);
        }

        test "parses entity components" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{
                \\    "name": "test_scene",
                \\    "scripts": [],
                \\    "entities": [
                \\        { "components": { "Position": { "x": 10, "y": 20 } } },
                \\        { "components": { "Position": { "x": 30, "y": 40 }, "Worker": {} } }
                \\    ]
                \\}
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");

            const e0 = scene.entities[0];
            try expect.to_be_null(e0.prefab);
            try expect.equal(e0.components.len, 1);
            try expect.equal(e0.components[0].name, "Position");

            const e1 = scene.entities[1];
            try expect.equal(e1.components.len, 2);
            try expect.to_be_true(e1.hasComponent("Position"));
            try expect.to_be_true(e1.hasComponent("Worker"));
        }
    };

    pub const camera = struct {
        test "parses camera config with integer coordinates" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{
                \\    "name": "cam_scene",
                \\    "scripts": [],
                \\    "camera": { "x": 400, "y": 300 },
                \\    "entities": []
                \\}
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");

            try expect.not_null(scene.camera);
            try expect.approx_eq(scene.camera.?.x, 400.0, 0.001);
            try expect.approx_eq(scene.camera.?.y, 300.0, 0.001);
        }

        test "parses camera config with float zoom" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{
                \\    "name": "zoom_scene",
                \\    "scripts": [],
                \\    "camera": { "x": 0, "y": 0, "zoom": 2.5 },
                \\    "entities": []
                \\}
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");

            try expect.not_null(scene.camera);
            try expect.approx_eq(scene.camera.?.zoom, 2.5, 0.001);
        }

        test "returns null camera when not specified" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{ "name": "no_cam", "scripts": [], "entities": [] }
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");

            try expect.to_be_null(scene.camera);
        }
    };

    pub const defaults = struct {
        test "uses unnamed when name is missing" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{ "scripts": [], "entities": [] }
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");

            try expect.equal(scene.name, "unnamed");
        }

        test "returns InvalidScene for non-object root" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc, "42");
            const result = scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");
            try expect.err(result, error.InvalidScene);
        }
    };

    pub const prefab_references = struct {
        test "entities store prefab name" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{
                \\    "name": "main",
                \\    "scripts": [],
                \\    "entities": [
                \\        { "prefab": "worker", "components": { "Position": { "x": 0, "y": 0 } } },
                \\        { "prefab": "worker", "components": { "Position": { "x": 50, "y": 0 } } },
                \\        { "prefab": "ship_carcase", "components": { "Position": { "x": 0, "y": 0 } } }
                \\    ]
                \\}
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");

            try expect.equal(scene.entities.len, 3);
            try expect.equal(scene.entities[0].prefab.?, "worker");
        }

        test "getEntitiesByPrefab filters correctly" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{
                \\    "name": "main",
                \\    "scripts": [],
                \\    "entities": [
                \\        { "prefab": "worker", "components": { "Position": { "x": 0, "y": 0 } } },
                \\        { "prefab": "worker", "components": { "Position": { "x": 50, "y": 0 } } },
                \\        { "prefab": "ship_carcase", "components": { "Position": { "x": 0, "y": 0 } } }
                \\    ]
                \\}
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");
            const workers = scene.getEntitiesByPrefab("worker");

            try expect.equal(workers.len, 2);
        }

        test "getEntitiesByPrefab returns empty for no matches" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{ "name": "main", "scripts": [], "entities": [] }
            );
            const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");
            const result = scene.getEntitiesByPrefab("nonexistent");

            try expect.equal(result.len, 0);
        }
    };

    pub const includes = struct {
        test "skips missing include files gracefully" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{
                \\    "name": "main",
                \\    "scripts": [],
                \\    "include": ["floor1.jsonc", "floor2.jsonc"],
                \\    "entities": [
                \\        { "components": { "Camera": {} } }
                \\    ]
                \\}
            );
            var prefab_cache = PrefabCache.init(alloc, "nonexistent");
            const scene = try scene_loader.loadSceneInner(alloc, val, &prefab_cache, "nonexistent_dir", 0);

            try expect.equal(scene.name, "main");
            try expect.equal(scene.entities.len, 1);
            try expect.to_be_true(scene.entities[0].hasComponent("Camera"));
        }

        test "depth protection succeeds at max depth" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{ "name": "deep", "scripts": [], "entities": [] }
            );
            var prefab_cache = PrefabCache.init(alloc, "nonexistent");
            _ = try scene_loader.loadSceneInner(alloc, val, &prefab_cache, ".", 16);
        }

        test "depth protection fails beyond max depth" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const val = try parseJsonc(alloc,
                \\{ "name": "deep", "scripts": [], "entities": [] }
            );
            var prefab_cache = PrefabCache.init(alloc, "nonexistent");
            const result = scene_loader.loadSceneInner(alloc, val, &prefab_cache, ".", 17);
            try expect.err(result, error.IncludeDepthExceeded);
        }
    };
};

// ── loadEntity ──

pub const loadEntity_spec = struct {
    pub const component_merging = struct {
        test "scene adds components to prefab" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const prefab_val = try parseJsonc(alloc,
                \\{ "components": { "Worker": {}, "ClosestMovementNode": {}, "NeedsClosestNode": {} } }
            );
            var cache = PrefabCache.init(alloc, "nonexistent");
            try cache.put("worker", prefab_val);

            const entity_val = try parseJsonc(alloc,
                \\{ "prefab": "worker", "components": { "Position": { "x": 50, "y": 100 } } }
            );
            const entity = try scene_loader.loadEntity(alloc, entity_val, &cache);

            try expect.equal(entity.prefab.?, "worker");
            try expect.equal(entity.components.len, 4);
            try expect.to_be_true(entity.hasComponent("Worker"));
            try expect.to_be_true(entity.hasComponent("ClosestMovementNode"));
            try expect.to_be_true(entity.hasComponent("NeedsClosestNode"));
            try expect.to_be_true(entity.hasComponent("Position"));
            try expect.equal(entity.getComponent("Position").?.asObject().?.getInteger("x").?, 50);
        }

        test "scene overrides existing prefab component" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const prefab_val = try parseJsonc(alloc,
                \\{ "components": { "Position": { "x": 0, "y": 0 }, "Worker": {} } }
            );
            var cache = PrefabCache.init(alloc, "nonexistent");
            try cache.put("worker", prefab_val);

            const entity_val = try parseJsonc(alloc,
                \\{ "prefab": "worker", "components": { "Position": { "x": 200, "y": 300 } } }
            );
            const entity = try scene_loader.loadEntity(alloc, entity_val, &cache);

            try expect.equal(entity.components.len, 2);
            const pos = entity.getComponent("Position").?.asObject().?;
            try expect.equal(pos.getInteger("x").?, 200);
            try expect.equal(pos.getInteger("y").?, 300);
        }
    };

    pub const inline_components = struct {
        test "entity without prefab has inline components only" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var cache = PrefabCache.init(alloc, "nonexistent");
            const entity_val = try parseJsonc(alloc,
                \\{
                \\    "components": {
                \\        "Position": { "x": 400, "y": 580 },
                \\        "Shape": { "shape": { "rectangle": { "width": 780, "height": 20 } } },
                \\        "RigidBody": { "body_type": "static" }
                \\    }
                \\}
            );
            const entity = try scene_loader.loadEntity(alloc, entity_val, &cache);

            try expect.to_be_null(entity.prefab);
            try expect.equal(entity.components.len, 3);
            try expect.to_be_true(entity.hasComponent("Position"));
            try expect.to_be_true(entity.hasComponent("Shape"));
            try expect.to_be_true(entity.hasComponent("RigidBody"));
            try expect.to_be_false(entity.hasChildren());
        }

        test "returns InvalidEntity for non-object entity" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var cache = PrefabCache.init(alloc, "nonexistent");
            const val = try parseJsonc(alloc, "42");
            const result = scene_loader.loadEntity(alloc, val, &cache);
            try expect.err(result, error.InvalidEntity);
        }
    };

    pub const children = struct {
        test "prefab with children spawns child entities" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const prefab_val = try parseJsonc(alloc,
                \\{
                \\    "components": { "Room": {} },
                \\    "children": [
                \\        { "prefab": "water_well_workstation", "components": { "Position": { "x": 78, "y": 47 } } },
                \\        { "prefab": "movement_node", "components": { "Position": { "x": 23, "y": 93 } } },
                \\        { "prefab": "movement_node", "components": { "Position": { "x": 76, "y": 93 } } },
                \\        { "prefab": "movement_node", "components": { "Position": { "x": 129, "y": 93 } } }
                \\    ]
                \\}
            );
            var cache = PrefabCache.init(alloc, "nonexistent");
            try cache.put("water_well", prefab_val);

            const entity_val = try parseJsonc(alloc,
                \\{ "prefab": "water_well", "components": { "Position": { "x": 0, "y": 0 } } }
            );
            const entity = try scene_loader.loadEntity(alloc, entity_val, &cache);

            try expect.equal(entity.prefab.?, "water_well");
            try expect.to_be_true(entity.hasComponent("Room"));
            try expect.to_be_true(entity.hasComponent("Position"));
            try expect.to_be_true(entity.hasChildren());
            try expect.equal(entity.children.len, 4);
            try expect.equal(entity.children[0].prefab.?, "water_well_workstation");
            try expect.equal(entity.children[1].prefab.?, "movement_node");

            const ws_pos = entity.children[0].getComponent("Position").?.asObject().?;
            try expect.equal(ws_pos.getInteger("x").?, 78);
            try expect.equal(ws_pos.getInteger("y").?, 47);
        }

        test "prefab children and entity children merge" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            const prefab_val = try parseJsonc(alloc,
                \\{
                \\    "components": { "Room": {} },
                \\    "children": [
                \\        { "components": { "Position": { "x": 10, "y": 10 }, "Wall": {} } },
                \\        { "components": { "Position": { "x": 20, "y": 20 }, "Wall": {} } }
                \\    ]
                \\}
            );
            var cache = PrefabCache.init(alloc, "nonexistent");
            try cache.put("room", prefab_val);

            const entity_val = try parseJsonc(alloc,
                \\{
                \\    "prefab": "room",
                \\    "components": { "Position": { "x": 0, "y": 0 } },
                \\    "children": [
                \\        { "components": { "Position": { "x": 50, "y": 50 }, "Decoration": {} } }
                \\    ]
                \\}
            );
            const entity = try scene_loader.loadEntity(alloc, entity_val, &cache);

            // 2 from prefab + 1 from entity = 3 children
            try expect.equal(entity.children.len, 3);
            try expect.to_be_true(entity.children[0].hasComponent("Wall"));
            try expect.to_be_true(entity.children[1].hasComponent("Wall"));
            try expect.to_be_true(entity.children[2].hasComponent("Decoration"));
        }

        test "nested prefab composition — prefab children reference other prefabs" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var cache = PrefabCache.init(alloc, "nonexistent");

            // movement_node prefab
            try cache.put("movement_node", try parseJsonc(alloc,
                \\{ "components": { "MovementNode": {}, "Walkable": {} } }
            ));

            // workstation prefab with children (storages)
            try cache.put("water_well_workstation", try parseJsonc(alloc,
                \\{
                \\    "components": { "Workstation": { "workstation_type": "water_well" } },
                \\    "children": [
                \\        { "components": { "Position": { "x": 0, "y": -20 }, "Ios": {} } },
                \\        { "components": { "Position": { "x": -55, "y": 0 }, "Eos": {} } }
                \\    ]
                \\}
            ));

            // room prefab uses both
            try cache.put("water_well", try parseJsonc(alloc,
                \\{
                \\    "components": { "Room": {} },
                \\    "children": [
                \\        { "prefab": "water_well_workstation", "components": { "Position": { "x": 78, "y": 47 } } },
                \\        { "prefab": "movement_node", "components": { "Position": { "x": 23, "y": 93 } } }
                \\    ]
                \\}
            ));

            const entity_val = try parseJsonc(alloc,
                \\{ "prefab": "water_well", "components": { "Position": { "x": 0, "y": 0 } } }
            );
            const entity = try scene_loader.loadEntity(alloc, entity_val, &cache);

            // Room has 2 children
            try expect.equal(entity.children.len, 2);

            // First child is workstation with its own children (storages)
            const ws = entity.children[0];
            try expect.equal(ws.prefab.?, "water_well_workstation");
            try expect.to_be_true(ws.hasComponent("Workstation"));
            try expect.to_be_true(ws.hasComponent("Position"));
            try expect.equal(ws.children.len, 2); // ios + eos
            try expect.to_be_true(ws.children[0].hasComponent("Ios"));
            try expect.to_be_true(ws.children[1].hasComponent("Eos"));

            // Second child is movement_node (no children)
            const mn = entity.children[1];
            try expect.equal(mn.prefab.?, "movement_node");
            try expect.to_be_true(mn.hasComponent("MovementNode"));
            try expect.to_be_true(mn.hasComponent("Walkable"));
            try expect.to_be_true(mn.hasComponent("Position"));
            try expect.to_be_false(mn.hasChildren());
        }
    };
};

// ── flattenEntities ──

pub const flattenEntities_spec = struct {
    test "parent refs children, children ref parent" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        var cache = PrefabCache.init(alloc, "nonexistent");

        const prefab_val = try parseJsonc(alloc,
            \\{
            \\    "components": { "Room": {} },
            \\    "children": [
            \\        { "components": { "Wall": {}, "Position": { "x": 10, "y": 0 } } },
            \\        { "components": { "Door": {}, "Position": { "x": 50, "y": 0 } } }
            \\    ]
            \\}
        );
        // Load entity directly — prefab components come from the value itself
        const parent_entity = try scene_loader.loadEntity(alloc, prefab_val, &cache);
        try expect.equal(parent_entity.children.len, 2);

        const flat = try scene_loader.flattenEntities(alloc, &.{parent_entity});

        // Flat: parent(0), wall(1), door(2)
        try expect.equal(flat.len, 3);

        // Parent has no parent_index
        try expect.to_be_null(flat[0].parent_index);
        // Parent's children_indices point to wall and door
        try expect.equal(flat[0].children_indices.len, 2);
        try expect.equal(flat[0].children_indices[0], 1);
        try expect.equal(flat[0].children_indices[1], 2);

        // Wall (index 1) points back to parent
        try expect.equal(flat[1].parent_index.?, 0);
        try expect.to_be_true(flat[1].hasComponent("Wall"));
        try expect.equal(flat[1].children_indices.len, 0);

        // Door (index 2) points back to parent
        try expect.equal(flat[2].parent_index.?, 0);
        try expect.to_be_true(flat[2].hasComponent("Door"));
        try expect.equal(flat[2].children_indices.len, 0);
    }

    test "nested grandchildren" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        var cache = PrefabCache.init(alloc, "nonexistent");

        try cache.put("leaf", try parseJsonc(alloc,
            \\{ "components": { "Leaf": {} } }
        ));

        try cache.put("branch", try parseJsonc(alloc,
            \\{ "components": { "Branch": {} }, "children": [{ "prefab": "leaf", "components": {} }] }
        ));

        const root_val = try parseJsonc(alloc,
            \\{
            \\    "components": { "Root": {} },
            \\    "children": [
            \\        { "prefab": "branch", "components": {} }
            \\    ]
            \\}
        );
        const root = try scene_loader.loadEntity(alloc, root_val, &cache);
        const flat = try scene_loader.flattenEntities(alloc, &.{root});

        // Flat: root(0), branch(1), leaf(2)
        try expect.equal(flat.len, 3);

        // Root -> [branch]
        try expect.to_be_null(flat[0].parent_index);
        try expect.equal(flat[0].children_indices.len, 1);
        try expect.equal(flat[0].children_indices[0], 1);

        // Branch -> [leaf], parent = root
        try expect.equal(flat[1].parent_index.?, 0);
        try expect.equal(flat[1].children_indices.len, 1);
        try expect.equal(flat[1].children_indices[0], 2);

        // Leaf, parent = branch, no children
        try expect.equal(flat[2].parent_index.?, 1);
        try expect.equal(flat[2].children_indices.len, 0);
    }

    test "multiple top-level entities flatten correctly" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        var cache = PrefabCache.init(alloc, "nonexistent");

        const e1 = try scene_loader.loadEntity(alloc, try parseJsonc(alloc,
            \\{ "components": { "A": {} } }
        ), &cache);
        const e2 = try scene_loader.loadEntity(alloc, try parseJsonc(alloc,
            \\{ "components": { "B": {} } }
        ), &cache);

        const flat = try scene_loader.flattenEntities(alloc, &.{ e1, e2 });

        try expect.equal(flat.len, 2);
        try expect.to_be_null(flat[0].parent_index);
        try expect.to_be_null(flat[1].parent_index);
        try expect.to_be_true(flat[0].hasComponent("A"));
        try expect.to_be_true(flat[1].hasComponent("B"));
    }
};

// ── end-to-end with deserialization ──

pub const end_to_end = struct {
    test "parse scene and deserialize components" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        const Position = struct { x: i32 = 0, y: i32 = 0 };
        const BodyType = enum { static, dynamic };
        const RigidBody = struct { body_type: BodyType = .static };
        const ShapeKind = union(enum) {
            circle: struct { radius: f32 },
            rectangle: struct { width: f32, height: f32 },
        };
        const Shape = struct { shape: ShapeKind };

        const val = try parseJsonc(alloc,
            \\{
            \\    "name": "bouncing_ball",
            \\    "scripts": ["physics"],
            \\    "camera": { "x": 400, "y": 300 },
            \\    "entities": [
            \\        {
            \\            "components": {
            \\                "Position": { "x": 400, "y": 580 },
            \\                "Shape": { "shape": { "rectangle": { "width": 780, "height": 20 } } },
            \\                "RigidBody": { "body_type": "static" }
            \\            }
            \\        },
            \\        {
            \\            "components": {
            \\                "Position": { "x": 400, "y": 150 },
            \\                "Shape": { "shape": { "circle": { "radius": 30 } } },
            \\                "RigidBody": { "body_type": "dynamic" }
            \\            }
            \\        }
            \\    ]
            \\}
        );
        const scene = try scene_loader.loadSceneFromValue(alloc, val, "nonexistent", ".");

        try expect.equal(scene.name, "bouncing_ball");
        try expect.equal(scene.entities.len, 2);

        const floor = scene.entities[0];
        const floor_pos = try deserialize(Position, floor.getComponent("Position").?, alloc);
        try expect.equal(floor_pos.x, 400);
        try expect.equal(floor_pos.y, 580);

        const floor_shape = try deserialize(Shape, floor.getComponent("Shape").?, alloc);
        switch (floor_shape.shape) {
            .rectangle => |r| {
                try expect.approx_eq(r.width, 780.0, 0.001);
                try expect.approx_eq(r.height, 20.0, 0.001);
            },
            else => return error.TypeMismatch,
        }

        const ball = scene.entities[1];
        const ball_rb = try deserialize(RigidBody, ball.getComponent("RigidBody").?, alloc);
        try expect.equal(ball_rb.body_type, BodyType.dynamic);
    }
};

// ── PrefabCache ──

pub const PrefabCache_spec = struct {
    test "put and get returns cached value" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        var cache = PrefabCache.init(alloc, "nonexistent");
        const val = try parseJsonc(alloc,
            \\{ "components": { "Worker": {} } }
        );
        try cache.put("worker", val);

        const result = try cache.get("worker");
        try expect.not_null(result);
    }

    test "get returns null for unknown prefab with missing directory" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        var cache = PrefabCache.init(alloc, "/tmp/nonexistent_prefab_dir_12345");
        const result = try cache.get("nonexistent_prefab");
        try expect.to_be_null(result);
    }
};
