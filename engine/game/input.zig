// Input — mouse, touch, and gesture recognition in game coordinates (Y-up).
//
// This is a zero-bit field mixin for GameWith(Hooks). Methods access the parent
// Game struct via @fieldParentPtr("input_mixin", self).

const input_mod = @import("input");

pub fn InputMixin(comptime GameType: type) type {
    return struct {
        const Self = @This();

        fn game(self: *Self) *GameType {
            return @alignCast(@fieldParentPtr("input_mixin", self));
        }

        fn gameConst(self: *const Self) *const GameType {
            return @alignCast(@fieldParentPtr("input_mixin", self));
        }

        /// Transform Y coordinate from screen space (Y-down) to game space (Y-up)
        fn toGameY(self: *const Self, screen_y: f32) f32 {
            const g = self.gameConst();
            const screen_size = g.getScreenSize();
            return @as(f32, @floatFromInt(screen_size.height)) - screen_y;
        }

        // ── Mouse Input ───────────────────────────────────────────

        /// Get the current mouse position in game coordinates (Y-up).
        /// Use getInput().getMousePosition() for raw screen coordinates.
        pub fn getMousePosition(self: *const Self) input_mod.MousePosition {
            const g = self.gameConst();
            const raw = g.input.getMousePosition();
            return .{ .x = raw.x, .y = self.toGameY(raw.y) };
        }

        // ── Touch Input ───────────────────────────────────────────

        /// Get the number of active touch points.
        /// Returns 0 on desktop platforms without touch support.
        pub fn getTouchCount(self: *const Self) u32 {
            return self.gameConst().input.getTouchCount();
        }

        /// Get touch at index (0 to getTouchCount()-1) in game coordinates (Y-up).
        /// Returns null if index is out of bounds.
        pub fn getTouch(self: *const Self, index: u32) ?input_mod.Touch {
            const g = self.gameConst();
            if (g.input.getTouch(index)) |raw| {
                return .{
                    .id = raw.id,
                    .x = raw.x,
                    .y = self.toGameY(raw.y),
                    .phase = raw.phase,
                };
            }
            return null;
        }

        /// Check if there are any active touches.
        pub fn isTouching(self: *const Self) bool {
            return self.gameConst().input.getTouchCount() > 0;
        }

        // ── Gesture Recognition ───────────────────────────────────

        /// Update gesture recognition with current touch state.
        /// Called automatically in the game loop; manual call needed for custom loops.
        /// Touch coordinates are transformed to game space (Y-up) before gesture processing.
        pub fn updateGestures(self: *Self, dt: f32) void {
            const g = self.game();
            // Build touch array from input, using getTouch() for Y-coordinate transformation
            var touches: [input_mod.MAX_TOUCHES]input_mod.Touch = undefined;
            var touch_count: usize = 0;
            var i: u32 = 0;
            while (i < g.input.getTouchCount() and touch_count < input_mod.MAX_TOUCHES) : (i += 1) {
                if (self.getTouch(i)) |touch| {
                    touches[touch_count] = touch;
                    touch_count += 1;
                }
            }
            g.gestures.updateWithTouches(touches[0..touch_count], dt);
        }

        /// Get access to the gesture recognizer.
        pub fn getGestures(self: *Self) *input_mod.Gestures {
            return &self.game().gestures;
        }

        /// Get pinch gesture if detected this frame.
        pub fn getPinch(self: *const Self) ?input_mod.Pinch {
            return self.gameConst().gestures.getPinch();
        }

        /// Get pan gesture if detected this frame.
        pub fn getPan(self: *const Self) ?input_mod.Pan {
            return self.gameConst().gestures.getPan();
        }

        /// Get swipe gesture if detected this frame.
        pub fn getSwipe(self: *const Self) ?input_mod.Swipe {
            return self.gameConst().gestures.getSwipe();
        }

        /// Get tap gesture if detected this frame.
        pub fn getTap(self: *const Self) ?input_mod.Tap {
            return self.gameConst().gestures.getTap();
        }

        /// Get double tap gesture if detected this frame.
        pub fn getDoubleTap(self: *const Self) ?input_mod.DoubleTap {
            return self.gameConst().gestures.getDoubleTap();
        }

        /// Get long press gesture if detected this frame.
        pub fn getLongPress(self: *const Self) ?input_mod.LongPress {
            return self.gameConst().gestures.getLongPress();
        }

        /// Get rotation gesture if detected this frame.
        pub fn getRotation(self: *const Self) ?input_mod.Rotation {
            return self.gameConst().gestures.getRotation();
        }
    };
}
