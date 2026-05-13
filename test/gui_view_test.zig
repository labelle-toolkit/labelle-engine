const std = @import("std");

const engine = @import("engine");
const ViewRegistry = engine.ViewRegistry;

test "ViewRegistry basic functionality" {
    const TestViews = ViewRegistry(.{
        .test_view = .{
            .name = "test_view",
            .elements = .{
                .{ .Label = .{ .text = "Hello" } },
            },
        },
    });

    try std.testing.expect(TestViews.has("test_view"));
    try std.testing.expect(!TestViews.has("nonexistent"));

    const view = TestViews.get("test_view");
    try std.testing.expectEqualStrings("test_view", view.name);
    try std.testing.expectEqual(@as(usize, 1), view.elements.len);
}

test "renderView falls back to default label widget when Gui lacks labelWidgetWithFont" {
    const TestViews = ViewRegistry(.{
        .font_view = .{
            .name = "font_view",
            .elements = .{
                .{ .Label = .{ .text = "Hello", .font = "title" } },
            },
        },
    });

    var game = engine.Game.init(std.testing.allocator);
    defer game.deinit();

    game.renderView(TestViews, "font_view");
}
