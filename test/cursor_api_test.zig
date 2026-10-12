const std = @import("std");
const engine = @import("engine");
const testing = std.testing;
const FakeWindow = struct {
    var visible = true;
    var over = true;
    var available = true;
    pub fn setCursorVisible(value: bool) bool {
        if (!available) return false;
        visible = value;
        return true;
    }
    pub fn isCursorOverWindow() bool {
        return over;
    }
};

test "cursor API is safe without binding and with older backends" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try testing.expect(!game.setCursorVisible(false));
    try testing.expect(!game.isCursorOverWindow());
    game.bindCursorWindow(struct {});
    try testing.expect(!game.setCursorVisible(false));
    try testing.expect(!game.isCursorOverWindow());
}

test "cursor API forwards immediately, reports failures, and restores on rebind/deinit" {
    FakeWindow.visible = true;
    FakeWindow.available = true;
    FakeWindow.over = true;
    var game = engine.Game.init(testing.allocator);
    var disposed = false;
    defer if (!disposed) game.deinit();
    game.bindCursorWindow(FakeWindow);
    try testing.expect(game.isCursorOverWindow());
    try testing.expect(game.setCursorVisible(false));
    try testing.expect(!FakeWindow.visible);
    FakeWindow.over = false;
    try testing.expect(!game.isCursorOverWindow());
    game.bindCursorWindow(struct {});
    try testing.expect(FakeWindow.visible);
    game.bindCursorWindow(FakeWindow);
    FakeWindow.available = false;
    try testing.expect(!game.setCursorVisible(false));
    try testing.expect(FakeWindow.visible);
    FakeWindow.available = true;
    try testing.expect(game.setCursorVisible(false));
    game.deinit();
    disposed = true;
    try testing.expect(FakeWindow.visible);
}
