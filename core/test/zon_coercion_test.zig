//! ZON Coercion Tests
//!
//! Tests for comptime coercion of anonymous .zon structs to typed structs,
//! including tagged union coercion.

const std = @import("std");
const zon = @import("engine-utils").zon;

// ============================================================================
// Test Types
// ============================================================================

/// Simple struct for basic tests
const SimpleStruct = struct {
    x: f32,
    y: f32,
    name: []const u8 = "default",
};

/// Struct with nested struct
const NestedStruct = struct {
    position: SimpleStruct,
    scale: f32 = 1.0,
};

/// Tagged union for shape types (like physics Shape)
const Shape = union(enum) {
    box: struct {
        width: f32,
        height: f32,
    },
    circle: struct {
        radius: f32,
    },
    point: void,
};

/// Tagged union with default values in payload
const ShapeWithDefaults = union(enum) {
    box: struct {
        width: f32,
        height: f32,
        rotation: f32 = 0.0,
    },
    circle: struct {
        radius: f32,
        segments: u32 = 32,
    },
};

/// State machine union with void variants
const State = union(enum) {
    idle,
    running,
    jumping: struct {
        velocity: f32,
    },
    attacking: struct {
        damage: f32,
        cooldown: f32 = 0.5,
    },
};

/// Component with a union field
const Collider = struct {
    shape: Shape,
    friction: f32 = 0.3,
    restitution: f32 = 0.0,
};

/// Struct with array field
const Polygon = struct {
    vertices: [4][2]f32,
    closed: bool = true,
};

// ============================================================================
// Basic Struct Coercion Tests
// ============================================================================

test "coerceValue: simple struct with all fields" {
    const data = .{ .x = 10.0, .y = 20.0, .name = "test" };
    const result = zon.coerceValue(SimpleStruct, data);

    try std.testing.expectEqual(@as(f32, 10.0), result.x);
    try std.testing.expectEqual(@as(f32, 20.0), result.y);
    try std.testing.expectEqualStrings("test", result.name);
}

test "coerceValue: simple struct with default field" {
    const data = .{ .x = 10.0, .y = 20.0 };
    const result = zon.coerceValue(SimpleStruct, data);

    try std.testing.expectEqual(@as(f32, 10.0), result.x);
    try std.testing.expectEqual(@as(f32, 20.0), result.y);
    try std.testing.expectEqualStrings("default", result.name);
}

test "coerceValue: nested struct" {
    const data = .{
        .position = .{ .x = 5.0, .y = 15.0 },
        .scale = 2.0,
    };
    const result = zon.coerceValue(NestedStruct, data);

    try std.testing.expectEqual(@as(f32, 5.0), result.position.x);
    try std.testing.expectEqual(@as(f32, 15.0), result.position.y);
    try std.testing.expectEqual(@as(f32, 2.0), result.scale);
}

// ============================================================================
// Tagged Union Coercion Tests
// ============================================================================

test "coerceValue: union with box variant" {
    const data = .{ .box = .{ .width = 50.0, .height = 30.0 } };
    const result = zon.coerceValue(Shape, data);

    try std.testing.expectEqual(Shape.box, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(f32, 50.0), result.box.width);
    try std.testing.expectEqual(@as(f32, 30.0), result.box.height);
}

test "coerceValue: union with circle variant" {
    const data = .{ .circle = .{ .radius = 25.0 } };
    const result = zon.coerceValue(Shape, data);

    try std.testing.expectEqual(Shape.circle, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(f32, 25.0), result.circle.radius);
}

test "coerceValue: union with void variant via enum literal" {
    const data = .point;
    const result = zon.coerceValue(Shape, data);

    try std.testing.expectEqual(Shape.point, std.meta.activeTag(result));
}

test "coerceValue: state union with void variant" {
    const idle_data = .idle;
    const idle_result = zon.coerceValue(State, idle_data);
    try std.testing.expectEqual(State.idle, std.meta.activeTag(idle_result));

    const running_data = .running;
    const running_result = zon.coerceValue(State, running_data);
    try std.testing.expectEqual(State.running, std.meta.activeTag(running_result));
}

test "coerceValue: state union with payload variant" {
    const data = .{ .jumping = .{ .velocity = 100.0 } };
    const result = zon.coerceValue(State, data);

    try std.testing.expectEqual(State.jumping, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(f32, 100.0), result.jumping.velocity);
}

test "coerceValue: state union with payload and defaults" {
    const data = .{ .attacking = .{ .damage = 50.0 } };
    const result = zon.coerceValue(State, data);

    try std.testing.expectEqual(State.attacking, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(f32, 50.0), result.attacking.damage);
    try std.testing.expectEqual(@as(f32, 0.5), result.attacking.cooldown);
}

// ============================================================================
// Union with Default Values in Payload
// ============================================================================

test "coerceValue: union payload with default values" {
    const box_data = .{ .box = .{ .width = 100.0, .height = 50.0 } };
    const box_result = zon.coerceValue(ShapeWithDefaults, box_data);

    try std.testing.expectEqual(@as(f32, 100.0), box_result.box.width);
    try std.testing.expectEqual(@as(f32, 50.0), box_result.box.height);
    try std.testing.expectEqual(@as(f32, 0.0), box_result.box.rotation); // default

    const circle_data = .{ .circle = .{ .radius = 30.0 } };
    const circle_result = zon.coerceValue(ShapeWithDefaults, circle_data);

    try std.testing.expectEqual(@as(f32, 30.0), circle_result.circle.radius);
    try std.testing.expectEqual(@as(u32, 32), circle_result.circle.segments); // default
}

test "coerceValue: union payload overriding defaults" {
    const data = .{ .box = .{ .width = 100.0, .height = 50.0, .rotation = 45.0 } };
    const result = zon.coerceValue(ShapeWithDefaults, data);

    try std.testing.expectEqual(@as(f32, 100.0), result.box.width);
    try std.testing.expectEqual(@as(f32, 50.0), result.box.height);
    try std.testing.expectEqual(@as(f32, 45.0), result.box.rotation);
}

// ============================================================================
// Struct with Union Field
// ============================================================================

test "coerceValue: struct containing union field" {
    const data = .{
        .shape = .{ .box = .{ .width = 32.0, .height = 32.0 } },
        .friction = 0.5,
    };
    const result = zon.coerceValue(Collider, data);

    try std.testing.expectEqual(Shape.box, std.meta.activeTag(result.shape));
    try std.testing.expectEqual(@as(f32, 32.0), result.shape.box.width);
    try std.testing.expectEqual(@as(f32, 32.0), result.shape.box.height);
    try std.testing.expectEqual(@as(f32, 0.5), result.friction);
    try std.testing.expectEqual(@as(f32, 0.0), result.restitution); // default
}

test "coerceValue: struct with union using defaults" {
    const data = .{
        .shape = .{ .circle = .{ .radius = 20.0 } },
    };
    const result = zon.coerceValue(Collider, data);

    try std.testing.expectEqual(Shape.circle, std.meta.activeTag(result.shape));
    try std.testing.expectEqual(@as(f32, 20.0), result.shape.circle.radius);
    try std.testing.expectEqual(@as(f32, 0.3), result.friction); // default
    try std.testing.expectEqual(@as(f32, 0.0), result.restitution); // default
}

// ============================================================================
// Array Coercion Tests
// ============================================================================

test "coerceValue: fixed-size array from tuple" {
    const data = .{
        .vertices = .{
            .{ 0.0, 0.0 },
            .{ 100.0, 0.0 },
            .{ 100.0, 100.0 },
            .{ 0.0, 100.0 },
        },
    };
    const result = zon.coerceValue(Polygon, data);

    try std.testing.expectEqual(@as(f32, 0.0), result.vertices[0][0]);
    try std.testing.expectEqual(@as(f32, 0.0), result.vertices[0][1]);
    try std.testing.expectEqual(@as(f32, 100.0), result.vertices[1][0]);
    try std.testing.expectEqual(@as(f32, 100.0), result.vertices[2][1]);
    try std.testing.expect(result.closed);
}

// ============================================================================
// Slice Coercion Tests
// ============================================================================

const SliceHolder = struct {
    values: []const f32,
    name: []const u8 = "unnamed",
};

test "coerceValue: slice from tuple" {
    const data = .{
        .values = .{ 1.0, 2.0, 3.0, 4.0, 5.0 },
        .name = "test",
    };
    const result = zon.coerceValue(SliceHolder, data);

    try std.testing.expectEqual(@as(usize, 5), result.values.len);
    try std.testing.expectEqual(@as(f32, 1.0), result.values[0]);
    try std.testing.expectEqual(@as(f32, 5.0), result.values[4]);
    try std.testing.expectEqualStrings("test", result.name);
}

// ============================================================================
// Complex Nested Union Tests
// ============================================================================

const NestedUnion = union(enum) {
    simple: struct {
        value: f32,
    },
    complex: struct {
        inner: Shape,
        scale: f32 = 1.0,
    },
};

test "coerceValue: nested union within union payload" {
    const data = .{
        .complex = .{
            .inner = .{ .circle = .{ .radius = 15.0 } },
            .scale = 2.0,
        },
    };
    const result = zon.coerceValue(NestedUnion, data);

    try std.testing.expectEqual(NestedUnion.complex, std.meta.activeTag(result));
    try std.testing.expectEqual(Shape.circle, std.meta.activeTag(result.complex.inner));
    try std.testing.expectEqual(@as(f32, 15.0), result.complex.inner.circle.radius);
    try std.testing.expectEqual(@as(f32, 2.0), result.complex.scale);
}

// ============================================================================
// Build Helpers
// ============================================================================

test "buildStruct: basic struct building" {
    const data = .{ .x = 1.0, .y = 2.0, .name = "built" };
    const result = zon.buildStruct(SimpleStruct, data);

    try std.testing.expectEqual(@as(f32, 1.0), result.x);
    try std.testing.expectEqual(@as(f32, 2.0), result.y);
    try std.testing.expectEqualStrings("built", result.name);
}

test "tupleToSlice: converts tuple to slice" {
    const tuple = .{ 10.0, 20.0, 30.0 };
    const slice = zon.tupleToSlice(f32, tuple);

    try std.testing.expectEqual(@as(usize, 3), slice.len);
    try std.testing.expectEqual(@as(f32, 10.0), slice[0]);
    try std.testing.expectEqual(@as(f32, 20.0), slice[1]);
    try std.testing.expectEqual(@as(f32, 30.0), slice[2]);
}
