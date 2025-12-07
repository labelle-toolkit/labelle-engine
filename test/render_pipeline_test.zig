const std = @import("std");
const zspec = @import("zspec");
const describe = zspec.describe;
const it = zspec.it;

const engine = @import("labelle-engine");
const Position = engine.Position;
const Sprite = engine.Sprite;
const Shape = engine.Shape;
const Text = engine.Text;
const RenderPipeline = engine.RenderPipeline;
const Color = engine.Color;

test "render_pipeline_test" {
    zspec.runAll(@This());
}

const position_spec = describe("Position component", .{
    it("defaults to origin", struct {
        pub fn t(_: void) !void {
            const pos = Position{};
            try std.testing.expectEqual(@as(f32, 0), pos.x);
            try std.testing.expectEqual(@as(f32, 0), pos.y);
        }
    }.t),

    it("converts to gfx position", struct {
        pub fn t(_: void) !void {
            const pos = Position{ .x = 100, .y = 200 };
            const gfx_pos = pos.toGfx();
            try std.testing.expectEqual(@as(f32, 100), gfx_pos.x);
            try std.testing.expectEqual(@as(f32, 200), gfx_pos.y);
        }
    }.t),
});

const sprite_spec = describe("Sprite component", .{
    it("has default values", struct {
        pub fn t(_: void) !void {
            const sprite = Sprite{};
            try std.testing.expectEqual(@as(f32, 1), sprite.scale);
            try std.testing.expectEqual(@as(f32, 0), sprite.rotation);
            try std.testing.expectEqual(false, sprite.flip_x);
            try std.testing.expectEqual(false, sprite.flip_y);
            try std.testing.expectEqual(true, sprite.visible);
        }
    }.t),

    it("converts to visual", struct {
        pub fn t(_: void) !void {
            const sprite = Sprite{ .scale = 2.0, .z_index = 50 };
            const visual = sprite.toVisual();
            try std.testing.expectEqual(@as(f32, 2.0), visual.scale);
            try std.testing.expectEqual(@as(u8, 50), visual.z_index);
        }
    }.t),
});

const shape_spec = describe("Shape component", .{
    it("creates circle with helper", struct {
        pub fn t(_: void) !void {
            const shape = Shape.circle(50);
            try std.testing.expectEqual(@as(f32, 50), shape.shape.circle.radius);
        }
    }.t),

    it("creates rectangle with helper", struct {
        pub fn t(_: void) !void {
            const shape = Shape.rectangle(100, 200);
            try std.testing.expectEqual(@as(f32, 100), shape.shape.rectangle.width);
            try std.testing.expectEqual(@as(f32, 200), shape.shape.rectangle.height);
        }
    }.t),

    it("creates line with helper", struct {
        pub fn t(_: void) !void {
            const shape = Shape.line(50, 100, 2);
            try std.testing.expectEqual(@as(f32, 50), shape.shape.line.end.x);
            try std.testing.expectEqual(@as(f32, 100), shape.shape.line.end.y);
            try std.testing.expectEqual(@as(f32, 2), shape.shape.line.thickness);
        }
    }.t),

    it("converts to visual", struct {
        pub fn t(_: void) !void {
            var shape = Shape.circle(30);
            shape.z_index = 10;
            shape.color = Color.red;
            const visual = shape.toVisual();
            try std.testing.expectEqual(@as(u8, 10), visual.z_index);
            try std.testing.expectEqual(@as(u8, 255), visual.color.r);
            try std.testing.expectEqual(@as(u8, 0), visual.color.g);
        }
    }.t),
});

const text_spec = describe("Text component", .{
    it("has default values", struct {
        pub fn t(_: void) !void {
            const text = Text{};
            try std.testing.expectEqual(@as(f32, 16), text.size);
            try std.testing.expectEqual(true, text.visible);
        }
    }.t),
});

const exports_spec = describe("render_pipeline module exports", .{
    it("exports RenderPipeline type", struct {
        pub fn t(_: void) !void {
            try std.testing.expect(@TypeOf(RenderPipeline) != void);
        }
    }.t),

    it("exports Position type", struct {
        pub fn t(_: void) !void {
            try std.testing.expect(@TypeOf(Position) != void);
        }
    }.t),

    it("exports Sprite type", struct {
        pub fn t(_: void) !void {
            try std.testing.expect(@TypeOf(Sprite) != void);
        }
    }.t),

    it("exports Shape type", struct {
        pub fn t(_: void) !void {
            try std.testing.expect(@TypeOf(Shape) != void);
        }
    }.t),

    it("exports Text type", struct {
        pub fn t(_: void) !void {
            try std.testing.expect(@TypeOf(Text) != void);
        }
    }.t),
});
