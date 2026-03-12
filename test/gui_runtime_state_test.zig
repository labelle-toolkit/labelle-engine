const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const VisibilityState = engine.VisibilityState;
const ValueState = engine.ValueState;

test "VisibilityState: override and default" {
    var vs = VisibilityState.init(testing.allocator);
    defer vs.deinit();

    // Default: use fallback
    try testing.expect(vs.isVisible("score_label", true) == true);
    try testing.expect(vs.isVisible("score_label", false) == false);

    // Override
    try vs.setVisible("score_label", false);
    try testing.expect(vs.isVisible("score_label", true) == false);

    // Clear
    vs.clear();
    try testing.expect(vs.isVisible("score_label", true) == true);
}

test "ValueState: checkbox, slider, text" {
    var vs = ValueState.init(testing.allocator);
    defer vs.deinit();

    // Defaults
    try testing.expect(vs.getCheckbox("is_boss", false) == false);
    try testing.expect(vs.getSlider("health", 100) == 100);
    try testing.expectEqualStrings("default", vs.getText("name", "default"));

    // Set values
    try vs.setCheckbox("is_boss", true);
    try vs.setSlider("health", 50);
    try vs.setText("name", "Goblin");

    try testing.expect(vs.getCheckbox("is_boss", false) == true);
    try testing.expect(vs.getSlider("health", 100) == 50);
    try testing.expectEqualStrings("Goblin", vs.getText("name", "default"));

    // Overwrite text (should free old)
    try vs.setText("name", "Dragon");
    try testing.expectEqualStrings("Dragon", vs.getText("name", "default"));

    // Clear
    vs.clear();
    try testing.expect(vs.getCheckbox("is_boss", false) == false);
}
