//! Render Module Tests
//!
//! BDD-style tests using zspec for render components.

const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

// Note: These tests verify component structure only.
// Full integration tests with RenderPipeline require graphics backend.

test {
    zspec.runAll(@This());
}

pub const PositionTests = struct {
    test "defaults to origin" {
        const Position = @import("../src/components.zig").Position;
        const pos = Position{};
        try std.testing.expectEqual(@as(f32, 0), pos.x);
        try std.testing.expectEqual(@as(f32, 0), pos.y);
    }

    test "can be initialized with values" {
        const Position = @import("../src/components.zig").Position;
        const pos = Position{ .x = 100, .y = 200 };
        try std.testing.expectEqual(@as(f32, 100), pos.x);
        try std.testing.expectEqual(@as(f32, 200), pos.y);
    }

    test "toGfx converts to graphics position" {
        const Position = @import("../src/components.zig").Position;
        const pos = Position{ .x = 50, .y = 75 };
        const gfx_pos = pos.toGfx();
        try std.testing.expectEqual(@as(f32, 50), gfx_pos.x);
        try std.testing.expectEqual(@as(f32, 75), gfx_pos.y);
    }
};

pub const SpriteTests = struct {
    test "has sensible defaults" {
        const Sprite = @import("../src/components.zig").Sprite;
        const sprite = Sprite{};
        try std.testing.expectEqual(@as(f32, 1), sprite.scale);
        try std.testing.expectEqual(@as(f32, 0), sprite.rotation);
        try expect.toBeFalse(sprite.flip_x);
        try expect.toBeFalse(sprite.flip_y);
        try expect.toBeTrue(sprite.visible);
        try std.testing.expectEqual(@as(u8, 128), sprite.z_index);
    }

    test "defaults to center pivot" {
        const components = @import("../src/components.zig");
        const sprite = components.Sprite{};
        try std.testing.expectEqual(components.Pivot.center, sprite.pivot);
    }

    test "defaults to world layer" {
        const components = @import("../src/components.zig");
        const sprite = components.Sprite{};
        try std.testing.expectEqual(components.Layer.world, sprite.layer);
    }

    test "defaults to no sizing mode" {
        const components = @import("../src/components.zig");
        const sprite = components.Sprite{};
        try std.testing.expectEqual(components.SizeMode.none, sprite.size_mode);
    }
};

pub const ShapeTests = struct {
    test "circle constructor creates circle shape" {
        const Shape = @import("../src/components.zig").Shape;
        const shape = Shape.circle(50);
        switch (shape.shape) {
            .circle => |c| try std.testing.expectEqual(@as(f32, 50), c.radius),
            else => return error.ExpectedCircle,
        }
    }

    test "rectangle constructor creates rectangle shape" {
        const Shape = @import("../src/components.zig").Shape;
        const shape = Shape.rectangle(100, 50);
        switch (shape.shape) {
            .rectangle => |r| {
                try std.testing.expectEqual(@as(f32, 100), r.width);
                try std.testing.expectEqual(@as(f32, 50), r.height);
            },
            else => return error.ExpectedRectangle,
        }
    }

    test "line constructor creates line shape" {
        const Shape = @import("../src/components.zig").Shape;
        const shape = Shape.line(100, 50, 2);
        switch (shape.shape) {
            .line => |l| {
                try std.testing.expectEqual(@as(f32, 100), l.end.x);
                try std.testing.expectEqual(@as(f32, 50), l.end.y);
                try std.testing.expectEqual(@as(f32, 2), l.thickness);
            },
            else => return error.ExpectedLine,
        }
    }

    test "has sensible defaults" {
        const components = @import("../src/components.zig");
        const shape = components.Shape.circle(10);
        try std.testing.expectEqual(@as(u8, 128), shape.z_index);
        try expect.toBeTrue(shape.visible);
        try std.testing.expectEqual(components.Layer.world, shape.layer);
    }
};

pub const TextTests = struct {
    test "has sensible defaults" {
        const Text = @import("../src/components.zig").Text;
        const text = Text{};
        try std.testing.expectEqual(@as(f32, 16), text.size);
        try expect.toBeTrue(text.visible);
        try std.testing.expectEqual(@as(u8, 128), text.z_index);
    }

    test "defaults to world layer" {
        const components = @import("../src/components.zig");
        const text = components.Text{};
        try std.testing.expectEqual(components.Layer.world, text.layer);
    }
};

pub const VisualTypeTests = struct {
    test "has all expected variants" {
        const VisualType = @import("../src/components.zig").VisualType;
        try std.testing.expectEqual(VisualType.none, VisualType.none);
        try std.testing.expectEqual(VisualType.sprite, VisualType.sprite);
        try std.testing.expectEqual(VisualType.shape, VisualType.shape);
        try std.testing.expectEqual(VisualType.text, VisualType.text);
    }
};

pub const ComponentsRegistryTests = struct {
    test "exports Position type" {
        const Components = @import("../src/components.zig").Components;
        const pos: Components.Position = .{ .x = 10, .y = 20 };
        try std.testing.expectEqual(@as(f32, 10), pos.x);
        try std.testing.expectEqual(@as(f32, 20), pos.y);
    }

    test "exports Sprite type" {
        const Components = @import("../src/components.zig").Components;
        const sprite: Components.Sprite = .{};
        try std.testing.expectEqual(@as(f32, 1), sprite.scale);
    }

    test "exports Shape type" {
        const components = @import("../src/components.zig");
        const shape: components.Components.Shape = components.Shape.circle(10);
        _ = shape;
    }

    test "exports Text type" {
        const Components = @import("../src/components.zig").Components;
        const text: Components.Text = .{};
        try std.testing.expectEqual(@as(f32, 16), text.size);
    }
};
