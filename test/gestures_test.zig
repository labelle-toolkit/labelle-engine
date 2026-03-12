const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Gestures = engine.Gestures;
const Touch = engine.Touch;

test "Gestures: init" {
    var gestures = Gestures.init();
    try testing.expect(gestures.getPinch() == null);
    try testing.expect(gestures.getPan() == null);
    try testing.expect(gestures.getSwipe() == null);
    try testing.expect(gestures.getTap() == null);
}

test "Gestures: tap detection" {
    var gestures = Gestures.init();

    const touch_began = [_]Touch{.{ .id = 1, .x = 100, .y = 100, .phase = .began }};
    gestures.updateWithTouches(&touch_began, 0.016);

    const touch_ended = [_]Touch{.{ .id = 1, .x = 100, .y = 100, .phase = .ended }};
    gestures.updateWithTouches(&touch_ended, 0.016);

    try testing.expect(gestures.pending_tap != null);

    const no_touch = [_]Touch{};
    gestures.updateWithTouches(&no_touch, 0.35);

    try testing.expect(gestures.getTap() != null);
}

test "Gestures: pinch detection" {
    var gestures = Gestures.init();

    const touches1 = [_]Touch{
        .{ .id = 1, .x = 100, .y = 100, .phase = .began },
        .{ .id = 2, .x = 200, .y = 100, .phase = .began },
    };
    gestures.updateWithTouches(&touches1, 0.016);

    const touches2 = [_]Touch{
        .{ .id = 1, .x = 50, .y = 100, .phase = .moved },
        .{ .id = 2, .x = 250, .y = 100, .phase = .moved },
    };
    gestures.updateWithTouches(&touches2, 0.016);

    const pinch = gestures.getPinch();
    try testing.expect(pinch != null);
    if (pinch) |p| {
        try testing.expect(p.scale > 1.0);
    }
}

test "Gestures: swipe detection" {
    var gestures = Gestures.init();
    gestures.config.swipe_threshold = 30;
    gestures.config.swipe_min_velocity = 100;

    const touch1 = [_]Touch{.{ .id = 1, .x = 100, .y = 100, .phase = .began }};
    gestures.updateWithTouches(&touch1, 0.016);

    const touch2 = [_]Touch{.{ .id = 1, .x = 200, .y = 100, .phase = .ended }};
    gestures.updateWithTouches(&touch2, 0.1);

    const swipe = gestures.getSwipe();
    try testing.expect(swipe != null);
    if (swipe) |s| {
        try testing.expect(s.direction == .right);
    }
}
