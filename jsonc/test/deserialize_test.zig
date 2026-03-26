const std = @import("std");
const expect = @import("zspec").expect;
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const deserialize = jsonc.deserialize;
const JsoncParser = jsonc.JsoncParser;
const ComponentRegistry = jsonc.ComponentRegistry;
const component = jsonc.component;

fn parseAndDeserialize(comptime T: type, input: []const u8) !T {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var p = JsoncParser.init(arena.allocator(), input);
    const val = try p.parse();
    return deserialize(T, val, arena.allocator());
}

// ── Test types ──

const Position = struct { x: i32 = 0, y: i32 = 0 };
const Color = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 };
const BodyType = enum { static, dynamic, kinematic };
const RigidBody = struct { body_type: BodyType = .static };
const ShapeKind = union(enum) {
    circle: struct { radius: f32 },
    rectangle: struct { width: f32, height: f32 },
};
const Shape = struct { shape: ShapeKind, color: Color = .{} };
const Collider = struct { shape: ShapeKind, restitution: f32 = 0.0, friction: f32 = 0.0 };
const WorkstationType = enum { hydroponics, water_well, butcher };
const Workstation = struct { workstation_type: WorkstationType, process_duration: i32 = 1 };
const AcceptedItems = struct { Water: bool = false, Vegetable: bool = false };
const Storage = struct { accepted_items: AcceptedItems = .{} };
const Worker = struct {};
const OptionalName = struct { name: ?[]const u8 = null, x: i32 = 0 };

pub const DeserializeSpec = struct {
    pub const structs = struct {
        test "deserializes struct with all fields" {
            const pos = try parseAndDeserialize(Position,
                \\{ "x": 50, "y": 100 }
            );
            try expect.equal(pos.x, 50);
            try expect.equal(pos.y, 100);
        }

        test "uses defaults for missing fields" {
            const pos = try parseAndDeserialize(Position,
                \\{ "x": 42 }
            );
            try expect.equal(pos.x, 42);
            try expect.equal(pos.y, 0);
        }

        test "deserializes empty struct (marker component)" {
            _ = try parseAndDeserialize(Worker, "{}");
        }

        test "deserializes nested structs" {
            const shape = try parseAndDeserialize(Shape,
                \\{ "shape": { "circle": { "radius": 30 } }, "color": { "r": 255, "g": 100, "b": 100 } }
            );
            try expect.equal(shape.color.r, 255);
            try expect.equal(shape.color.g, 100);
        }

        test "returns error for non-object value" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const val = Value{ .integer = 42 };
            try expect.err(
                jsonc.DeserializeError,
                deserialize(Position, val, arena.allocator()),
                error.TypeMismatch,
            );
        }
    };

    pub const enums = struct {
        test "deserializes enum from string (JSONC)" {
            const rb = try parseAndDeserialize(RigidBody,
                \\{ "body_type": "dynamic" }
            );
            try expect.equal(rb.body_type, BodyType.dynamic);
        }

        test "returns error for unknown enum value" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(),
                \\{ "body_type": "flying" }
            );
            const val = try p.parse();
            try expect.err(
                jsonc.DeserializeError,
                deserialize(RigidBody, val, arena.allocator()),
                error.UnknownEnumValue,
            );
        }
    };

    pub const unions = struct {
        test "deserializes tagged union (circle)" {
            const shape = try parseAndDeserialize(ShapeKind,
                \\{ "circle": { "radius": 30 } }
            );
            switch (shape) {
                .circle => |c| try expect.approx_eq(c.radius, 30.0, 0.001),
                else => return error.TypeMismatch,
            }
        }

        test "deserializes tagged union (rectangle)" {
            const shape = try parseAndDeserialize(ShapeKind,
                \\{ "rectangle": { "width": 780, "height": 20 } }
            );
            switch (shape) {
                .rectangle => |r| {
                    try expect.approx_eq(r.width, 780.0, 0.001);
                    try expect.approx_eq(r.height, 20.0, 0.001);
                },
                else => return error.TypeMismatch,
            }
        }

        test "returns error for unknown union field" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(),
                \\{ "triangle": { "base": 10 } }
            );
            const val = try p.parse();
            try expect.err(
                jsonc.DeserializeError,
                deserialize(ShapeKind, val, arena.allocator()),
                error.UnknownUnionField,
            );
        }
    };

    pub const coercion = struct {
        test "integer to float coercion" {
            // JSON "30" is integer, but radius is f32
            const shape = try parseAndDeserialize(ShapeKind,
                \\{ "circle": { "radius": 30 } }
            );
            switch (shape) {
                .circle => |c| try expect.approx_eq(c.radius, 30.0, 0.001),
                else => return error.TypeMismatch,
            }
        }

        test "float to integer coercion" {
            const pos = try parseAndDeserialize(Position,
                \\{ "x": 10.0, "y": 20.0 }
            );
            try expect.equal(pos.x, 10);
            try expect.equal(pos.y, 20);
        }
    };

    pub const optionals = struct {
        test "deserializes null as null optional" {
            const val = try parseAndDeserialize(OptionalName,
                \\{ "name": null, "x": 5 }
            );
            try expect.to_be_null(val.name);
            try expect.equal(val.x, 5);
        }

        test "deserializes present optional" {
            const val = try parseAndDeserialize(OptionalName,
                \\{ "name": "player", "x": 10 }
            );
            try expect.equal(val.name.?, "player");
        }

        test "uses default null for missing optional" {
            const val = try parseAndDeserialize(OptionalName,
                \\{ "x": 7 }
            );
            try expect.to_be_null(val.name);
            try expect.equal(val.x, 7);
        }
    };

    pub const booleans = struct {
        test "deserializes bool fields" {
            const storage = try parseAndDeserialize(Storage,
                \\{ "accepted_items": { "Water": true } }
            );
            try expect.equal(storage.accepted_items.Water, true);
            try expect.equal(storage.accepted_items.Vegetable, false);
        }
    };

    pub const floats = struct {
        test "deserializes float fields" {
            const col = try parseAndDeserialize(Collider,
                \\{ "shape": { "circle": { "radius": 30 } }, "restitution": 0.9, "friction": 0.1 }
            );
            try expect.approx_eq(col.restitution, 0.9, 0.001);
            try expect.approx_eq(col.friction, 0.1, 0.001);
        }
    };

    pub const negative_integers = struct {
        test "deserializes negative integers" {
            const pos = try parseAndDeserialize(Position,
                \\{ "x": -20, "y": 0 }
            );
            try expect.equal(pos.x, -20);
        }
    };

    pub const slices = struct {
        test "deserializes slice of strings" {
            const Scripts = struct { names: []const []const u8 = &.{} };
            const val = try parseAndDeserialize(Scripts,
                \\{ "names": ["physics", "camera", "save"] }
            );
            try expect.equal(val.names.len, 3);
            try expect.equal(val.names[0], "physics");
            try expect.equal(val.names[2], "save");
        }

        test "deserializes slice of structs" {
            const Positions = struct { items: []const Position = &.{} };
            const val = try parseAndDeserialize(Positions,
                \\{ "items": [{ "x": 1, "y": 2 }, { "x": 3, "y": 4 }] }
            );
            try expect.equal(val.items.len, 2);
            try expect.equal(val.items[0].x, 1);
            try expect.equal(val.items[1].y, 4);
        }
    };
};

pub const ComponentRegistrySpec = struct {
    const TestRegistry = ComponentRegistry(.{
        component("Position", Position),
        component("Color", Color),
        component("RigidBody", RigidBody),
        component("Shape", Shape),
        component("Worker", Worker),
    });

    pub const has = struct {
        test "returns true for registered components" {
            try expect.equal(TestRegistry.has("Position"), true);
            try expect.equal(TestRegistry.has("Shape"), true);
            try expect.equal(TestRegistry.has("Worker"), true);
        }

        test "returns false for unknown components" {
            try expect.equal(TestRegistry.has("NonExistent"), false);
        }
    };

    pub const count = struct {
        test "returns number of registered components" {
            try expect.equal(TestRegistry.count(), 5);
        }
    };

    pub const names = struct {
        test "returns all registered names" {
            const all = TestRegistry.names();
            try expect.equal(all[0], "Position");
            try expect.equal(all[4], "Worker");
        }
    };

    pub const deserializeByName = struct {
        test "deserializes known component" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(),
                \\{ "x": 42, "y": 99 }
            );
            const val = try p.parse();
            const result = (try TestRegistry.deserializeByName("Position", val, arena.allocator())).?;
            const pos = result.as(Position);
            try expect.equal(pos.x, 42);
            try expect.equal(pos.y, 99);
        }

        test "returns null for unknown component" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(), "{}");
            const val = try p.parse();
            const result = try TestRegistry.deserializeByName("Unknown", val, arena.allocator());
            try expect.to_be_null(result);
        }

        test "deserializes entity components from scene data" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var p = JsoncParser.init(arena.allocator(),
                \\{
                \\    "Position": { "x": 400, "y": 580 },
                \\    "RigidBody": { "body_type": "static" },
                \\}
            );
            const val = try p.parse();
            const obj = val.asObject().?;

            const pos = (try TestRegistry.deserializeByName("Position", obj.get("Position").?, arena.allocator())).?.as(Position);
            try expect.equal(pos.x, 400);

            const rb = (try TestRegistry.deserializeByName("RigidBody", obj.get("RigidBody").?, arena.allocator())).?.as(RigidBody);
            try expect.equal(rb.body_type, BodyType.static);
        }
    };
};
