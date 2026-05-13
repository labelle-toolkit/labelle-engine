const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const GameConfig = engine.GameConfig;
const MockEcsBackend = engine.MockEcsBackend;
const StubAudio = engine.StubAudio;
const StubInput = engine.StubInput;
const StubLogSink = engine.StubLogSink;
const StubRender = engine.StubRender;
const ViewRegistry = engine.ViewRegistry;

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool { return false; }
    pub fn names() []const []const u8 { return &.{}; }
};

const CountingGui = struct {
    var label_calls: u32 = 0;

    pub fn reset() void {
        label_calls = 0;
    }

    pub fn begin() void {}
    pub fn end() void {}
    pub fn wantsMouse() bool { return false; }
    pub fn wantsKeyboard() bool { return false; }

    pub fn labelWidget(
        _: [:0]const u8,
        _: i32,
        _: i32,
        _: i32,
        _: u8,
        _: u8,
        _: u8,
    ) void {
        label_calls += 1;
    }

    pub fn buttonWidget(_: u32, _: [:0]const u8, _: i32, _: i32, _: i32, _: i32) bool { return false; }
    pub fn progressBarWidget(_: i32, _: i32, _: i32, _: i32, _: f32, _: u8, _: u8, _: u8) void {}
    pub fn panelWidget(_: i32, _: i32, _: i32, _: i32) void {}
    pub fn checkboxWidget(_: u32, _: [:0]const u8, _: i32, _: i32, _: bool) bool { return false; }
    pub fn sliderWidget(_: u32, _: i32, _: i32, _: i32, _: i32, value: f32, _: f32, _: f32) f32 { return value; }
};

const TestGame = GameConfig(
    StubRender(u32),
    MockEcsBackend(u32),
    StubInput,
    StubAudio,
    CountingGui,
    void,
    StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

test "ViewRegistry basic functionality" {
    const TestViews = ViewRegistry(.{
        .test_view = .{
            .name = "test_view",
            .elements = .{
                .{ .Label = .{ .text = "Hello" } },
            },
        },
    });

    try testing.expect(TestViews.has("test_view"));
    try testing.expect(!TestViews.has("nonexistent"));

    const view = TestViews.get("test_view");
    try testing.expectEqualStrings("test_view", view.name);
    try testing.expectEqual(@as(usize, 1), view.elements.len);
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

    CountingGui.reset();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    game.renderView(TestViews, "font_view");
    try testing.expectEqual(@as(u32, 1), CountingGui.label_calls);
}
