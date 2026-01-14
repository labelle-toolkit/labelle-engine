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
const Layer = engine.Layer;
const SizeMode = engine.SizeMode;
const Container = engine.Container;

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

    it("layer defaults to world", struct {
        pub fn t(_: void) !void {
            const sprite = Sprite{};
            try std.testing.expectEqual(Layer.world, sprite.layer);
        }
    }.t),

    it("converts to visual", struct {
        pub fn t(_: void) !void {
            const sprite = Sprite{ .scale_x = 2.0, .scale_y = 2.0, .z_index = 50 };
            const visual = sprite.toVisual();
            try std.testing.expectEqual(@as(f32, 2.0), visual.scale_x);
            try std.testing.expectEqual(@as(f32, 2.0), visual.scale_y);
            try std.testing.expectEqual(@as(i16, 50), visual.z_index);
        }
    }.t),

    it("toVisual includes layer", struct {
        pub fn t(_: void) !void {
            var sprite = Sprite{};
            sprite.layer = .ui;
            const visual = sprite.toVisual();
            try std.testing.expectEqual(Layer.ui, visual.layer);
        }
    }.t),

    it("size_mode defaults to none", struct {
        pub fn t(_: void) !void {
            const sprite = Sprite{};
            try std.testing.expectEqual(SizeMode.none, sprite.size_mode);
        }
    }.t),

    it("container defaults to null", struct {
        pub fn t(_: void) !void {
            const sprite = Sprite{};
            try std.testing.expectEqual(@as(?Container, null), sprite.container);
        }
    }.t),

    it("can set size_mode to cover", struct {
        pub fn t(_: void) !void {
            var sprite = Sprite{};
            sprite.size_mode = .cover;
            try std.testing.expectEqual(SizeMode.cover, sprite.size_mode);
        }
    }.t),

    it("can set container to viewport", struct {
        pub fn t(_: void) !void {
            var sprite = Sprite{};
            sprite.container = .viewport;
            try std.testing.expectEqual(Container.viewport, sprite.container.?);
        }
    }.t),

    it("toVisual includes size_mode", struct {
        pub fn t(_: void) !void {
            var sprite = Sprite{};
            sprite.size_mode = .stretch;
            const visual = sprite.toVisual();
            try std.testing.expectEqual(SizeMode.stretch, visual.size_mode);
        }
    }.t),

    it("toVisual includes container", struct {
        pub fn t(_: void) !void {
            var sprite = Sprite{};
            sprite.container = .camera_viewport;
            const visual = sprite.toVisual();
            try std.testing.expectEqual(Container.camera_viewport, visual.container.?);
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

    it("layer defaults to world", struct {
        pub fn t(_: void) !void {
            const shape = Shape.circle(50);
            try std.testing.expectEqual(Layer.world, shape.layer);
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

    it("toVisual includes layer", struct {
        pub fn t(_: void) !void {
            var shape = Shape.circle(30);
            shape.layer = .background;
            const visual = shape.toVisual();
            try std.testing.expectEqual(Layer.background, visual.layer);
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

    it("layer defaults to world", struct {
        pub fn t(_: void) !void {
            const text = Text{};
            try std.testing.expectEqual(Layer.world, text.layer);
        }
    }.t),

    it("toVisual includes layer", struct {
        pub fn t(_: void) !void {
            var text = Text{};
            text.layer = .ui;
            const visual = text.toVisual();
            try std.testing.expectEqual(Layer.ui, visual.layer);
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
