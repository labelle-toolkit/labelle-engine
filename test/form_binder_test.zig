const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const FormBinder = engine.FormBinder;

test "FormBinder: checkbox binding" {
    const TestForm = struct {
        enabled: bool = false,
        count: f32 = 0,
    };

    var form = TestForm{};
    const Binder = FormBinder(TestForm, "test");
    const binder = Binder.init(&form);

    try testing.expect(!form.enabled);
    const handled = binder.handleEvent(.{ .checkbox_changed = .{
        .element_id = "test.enabled",
        .value = true,
    } });
    try testing.expect(handled);
    try testing.expect(form.enabled);
}

test "FormBinder: slider binding" {
    const TestForm = struct { health: f32 = 100 };

    var form = TestForm{};
    const binder = FormBinder(TestForm, "form").init(&form);

    _ = binder.handleEvent(.{ .slider_changed = .{
        .element_id = "form.health",
        .value = 50,
    } });
    try testing.expect(form.health == 50);
}

test "FormBinder: custom setter" {
    const TestForm = struct {
        health: f32 = 100,
        pub fn setHealth(self: *@This(), value: f32) void {
            self.health = @min(value, 200);
        }
    };

    var form = TestForm{};
    const binder = FormBinder(TestForm, "f").init(&form);

    _ = binder.handleEvent(.{ .slider_changed = .{
        .element_id = "f.health",
        .value = 999,
    } });
    try testing.expect(form.health == 200);
}

test "FormBinder: ignores wrong form prefix" {
    const TestForm = struct { x: f32 = 0 };

    var form = TestForm{};
    const binder = FormBinder(TestForm, "my_form").init(&form);

    const handled = binder.handleEvent(.{ .slider_changed = .{
        .element_id = "other_form.x",
        .value = 5,
    } });
    try testing.expect(!handled);
    try testing.expect(form.x == 0);
}

test "FormBinder: visibility rules" {
    const TestForm = struct {
        is_boss: bool = false,

        pub const VisibilityRules = struct {
            boss_health: void = {},
            boss_name: void = {},
        };

        pub fn isVisible(self: *const @This(), element_id: []const u8) bool {
            if (std.mem.startsWith(u8, element_id, "boss_")) return self.is_boss;
            return true;
        }
    };

    var form = TestForm{};
    const binder = FormBinder(TestForm, "f").init(&form);

    try testing.expect(!binder.evaluateVisibility("boss_health"));

    form.is_boss = true;
    try testing.expect(binder.evaluateVisibility("boss_health"));

    var vis = try binder.updateVisibility(testing.allocator);
    defer vis.deinit();
    try testing.expect(vis.get("boss_health").? == true);
    try testing.expect(vis.get("boss_name").? == true);
}
