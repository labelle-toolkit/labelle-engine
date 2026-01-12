//! Gesture Recognition Module
//!
//! Provides high-level gesture detection built on top of raw touch input.
//! Supports common mobile gestures: pinch, pan, swipe, tap, double-tap,
//! long press, and rotation.
//!
//! Usage:
//!   var gestures = Gestures.init();
//!   // In update loop:
//!   gestures.update(touch_count, getTouchFn, dt);
//!   if (gestures.getPinch()) |pinch| {
//!       camera.zoom *= pinch.scale;
//!   }

const std = @import("std");
const types = @import("types.zig");
const Touch = types.Touch;
const TouchPhase = types.TouchPhase;
const MAX_TOUCHES = types.MAX_TOUCHES;

/// Swipe direction
pub const SwipeDirection = enum {
    up,
    down,
    left,
    right,
};

/// Pinch gesture data
pub const Pinch = struct {
    /// Scale factor relative to last frame (>1 = zoom in, <1 = zoom out)
    scale: f32,
    /// Center point X between the two fingers
    center_x: f32,
    /// Center point Y between the two fingers
    center_y: f32,
    /// Current distance between fingers
    distance: f32,
};

/// Pan gesture data (single finger drag)
pub const Pan = struct {
    /// Movement delta X since last frame
    delta_x: f32,
    /// Movement delta Y since last frame
    delta_y: f32,
    /// Current X position
    x: f32,
    /// Current Y position
    y: f32,
};

/// Swipe gesture data
pub const Swipe = struct {
    /// Direction of the swipe
    direction: SwipeDirection,
    /// Velocity in pixels per second
    velocity: f32,
    /// Start position X
    start_x: f32,
    /// Start position Y
    start_y: f32,
    /// End position X
    end_x: f32,
    /// End position Y
    end_y: f32,
};

/// Tap gesture data
pub const Tap = struct {
    /// X position of the tap
    x: f32,
    /// Y position of the tap
    y: f32,
};

/// Double tap gesture data
pub const DoubleTap = struct {
    /// X position of the double tap
    x: f32,
    /// Y position of the double tap
    y: f32,
};

/// Long press gesture data
pub const LongPress = struct {
    /// X position of the long press
    x: f32,
    /// Y position of the long press
    y: f32,
    /// Duration the touch has been held
    duration: f32,
};

/// Rotation gesture data (two-finger twist)
pub const Rotation = struct {
    /// Angle change in radians since last frame
    angle_delta: f32,
    /// Total angle in radians since gesture started
    angle: f32,
    /// Center point X between the two fingers
    center_x: f32,
    /// Center point Y between the two fingers
    center_y: f32,
};

/// Internal touch tracking state
const TouchState = struct {
    id: u64 = 0,
    start_x: f32 = 0,
    start_y: f32 = 0,
    start_time: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    active: bool = false,
    /// Set to true when this touch participates in a multi-touch gesture (pinch/rotation)
    was_in_multitouch: bool = false,
};

/// Gesture recognizer that processes raw touch input
pub const Gestures = struct {
    const Self = @This();

    // Configuration
    config: Config = .{},

    // Internal state
    touch_states: [MAX_TOUCHES]TouchState = [_]TouchState{.{}} ** MAX_TOUCHES,
    active_touch_count: u32 = 0,

    // Pinch/Rotation state
    last_pinch_distance: ?f32 = null,
    last_pinch_angle: ?f32 = null,
    pinch_start_distance: ?f32 = null,
    rotation_start_angle: ?f32 = null,

    // Tap detection state
    last_tap_time: f32 = 0,
    last_tap_x: f32 = 0,
    last_tap_y: f32 = 0,
    pending_tap: ?Tap = null,
    tap_wait_timer: f32 = 0,

    // Current frame gesture results
    current_pinch: ?Pinch = null,
    current_pan: ?Pan = null,
    current_swipe: ?Swipe = null,
    current_tap: ?Tap = null,
    current_double_tap: ?DoubleTap = null,
    current_long_press: ?LongPress = null,
    current_rotation: ?Rotation = null,

    // Time tracking
    total_time: f32 = 0,

    /// Configuration for gesture detection thresholds
    pub const Config = struct {
        /// Minimum distance in pixels for a swipe to be recognized
        swipe_threshold: f32 = 50.0,
        /// Minimum velocity in pixels/sec for a swipe
        swipe_min_velocity: f32 = 200.0,
        /// Maximum duration in seconds for a swipe gesture
        swipe_max_duration: f32 = 0.5,
        /// Duration in seconds for long press detection
        long_press_duration: f32 = 0.5,
        /// Maximum interval in seconds between taps for double-tap
        double_tap_interval: f32 = 0.3,
        /// Maximum movement in pixels during tap (to distinguish from drag)
        tap_max_movement: f32 = 20.0,
        /// Maximum tap duration in seconds
        tap_max_duration: f32 = 0.3,
        /// Maximum distance between taps for double-tap recognition
        double_tap_max_distance: f32 = 40.0,
        /// Minimum distance change for pinch to register
        pinch_threshold: f32 = 5.0,
        /// Minimum angle change in radians for rotation to register
        rotation_threshold: f32 = 0.05,
    };

    /// Initialize the gesture recognizer
    pub fn init() Self {
        return .{};
    }

    /// Initialize with custom configuration
    pub fn initWithConfig(config: Config) Self {
        return .{ .config = config };
    }

    /// Update gesture recognition with current touch state
    /// Call this once per frame with the current touch data
    pub fn update(
        self: *Self,
        touch_count: u32,
        comptime getTouchFn: fn (u32) ?Touch,
        dt: f32,
    ) void {
        self.updateInternal(touch_count, struct {
            fn get(index: u32) ?Touch {
                return getTouchFn(index);
            }
        }.get, dt);
    }


    /// Update with a slice of touches (simplest API)
    pub fn updateWithTouches(self: *Self, touches: []const Touch, dt: f32) void {
        self.total_time += dt;

        // Clear current frame results
        self.current_pinch = null;
        self.current_pan = null;
        self.current_swipe = null;
        self.current_tap = null;
        self.current_double_tap = null;
        self.current_long_press = null;
        self.current_rotation = null;

        // Process tap wait timer (for distinguishing tap from double-tap)
        if (self.pending_tap) |_| {
            self.tap_wait_timer += dt;
            if (self.tap_wait_timer >= self.config.double_tap_interval) {
                // No second tap came, emit the single tap
                self.current_tap = self.pending_tap;
                self.pending_tap = null;
                self.tap_wait_timer = 0;
            }
        }

        // Update touch states
        const touch_count: u32 = @intCast(touches.len);
        self.active_touch_count = touch_count;

        // Process each touch
        for (touches, 0..) |touch, i| {
            self.processTouch(touch, @intCast(i));
        }

        // Mark inactive touches
        for (&self.touch_states) |*state| {
            var found = false;
            for (touches) |touch| {
                if (state.active and state.id == touch.id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                state.active = false;
            }
        }

        // Detect multi-touch gestures
        if (touch_count == 2) {
            self.detectPinchAndRotation(touches[0], touches[1]);
            // Mark both touches as participating in multi-touch gesture
            // This prevents false taps when lifting fingers after a pinch
            for (&self.touch_states) |*state| {
                if (state.active and (state.id == touches[0].id or state.id == touches[1].id)) {
                    state.was_in_multitouch = true;
                }
            }
        } else {
            // Reset pinch/rotation state when not two fingers
            self.last_pinch_distance = null;
            self.last_pinch_angle = null;
            self.pinch_start_distance = null;
            self.rotation_start_angle = null;
        }

        // Detect single-touch gestures
        if (touch_count == 1) {
            self.detectPan(touches[0]);
        }
    }

    fn updateInternal(
        self: *Self,
        touch_count: u32,
        comptime getTouchFn: fn (u32) ?Touch,
        dt: f32,
    ) void {
        // Build touch slice
        var touches_buf: [MAX_TOUCHES]Touch = undefined;
        var actual_count: usize = 0;
        var i: u32 = 0;
        while (i < touch_count and actual_count < MAX_TOUCHES) : (i += 1) {
            if (getTouchFn(i)) |touch| {
                touches_buf[actual_count] = touch;
                actual_count += 1;
            }
        }
        self.updateWithTouches(touches_buf[0..actual_count], dt);
    }

    fn processTouch(self: *Self, touch: Touch, index: usize) void {
        _ = index; // Index is unreliable; look up by touch.id instead

        switch (touch.phase) {
            .began => {
                // Find an available slot for new touch
                for (&self.touch_states) |*state| {
                    if (!state.active) {
                        state.* = .{
                            .id = touch.id,
                            .start_x = touch.x,
                            .start_y = touch.y,
                            .start_time = self.total_time,
                            .last_x = touch.x,
                            .last_y = touch.y,
                            .active = true,
                        };
                        break;
                    }
                }
            },
            .moved => {
                // Find state by touch.id
                if (self.findTouchState(touch.id)) |state| {
                    // Check for long press (touch held without much movement)
                    const dx = touch.x - state.start_x;
                    const dy = touch.y - state.start_y;
                    const movement = @sqrt(dx * dx + dy * dy);
                    const duration = self.total_time - state.start_time;

                    if (movement < self.config.tap_max_movement and
                        duration >= self.config.long_press_duration and
                        self.active_touch_count == 1)
                    {
                        self.current_long_press = .{
                            .x = touch.x,
                            .y = touch.y,
                            .duration = duration,
                        };
                    }

                    state.last_x = touch.x;
                    state.last_y = touch.y;
                }
            },
            .ended => {
                if (self.findTouchState(touch.id)) |state| {
                    self.processTouchEnd(touch, state);
                    state.active = false;
                }
            },
            .cancelled => {
                if (self.findTouchState(touch.id)) |state| {
                    state.active = false;
                }
            },
        }
    }

    /// Find touch state by touch ID
    fn findTouchState(self: *Self, touch_id: u64) ?*TouchState {
        for (&self.touch_states) |*state| {
            if (state.active and state.id == touch_id) {
                return state;
            }
        }
        return null;
    }

    fn processTouchEnd(self: *Self, touch: Touch, state: *const TouchState) void {
        const dx = touch.x - state.start_x;
        const dy = touch.y - state.start_y;
        const distance = @sqrt(dx * dx + dy * dy);
        const duration = self.total_time - state.start_time;

        // Skip tap/swipe detection if this touch was part of a multi-touch gesture
        // (e.g., pinch or rotation). This prevents false taps when lifting fingers
        // after a pinch gesture, while still allowing independent taps when another
        // finger is merely held down.
        if (state.was_in_multitouch) return;

        // Check for swipe
        if (distance >= self.config.swipe_threshold and
            duration <= self.config.swipe_max_duration)
        {
            const velocity = distance / duration;
            if (velocity >= self.config.swipe_min_velocity) {
                const direction = self.getSwipeDirection(dx, dy);
                self.current_swipe = .{
                    .direction = direction,
                    .velocity = velocity,
                    .start_x = state.start_x,
                    .start_y = state.start_y,
                    .end_x = touch.x,
                    .end_y = touch.y,
                };
                return;
            }
        }

        // Check for tap
        if (distance < self.config.tap_max_movement and
            duration < self.config.tap_max_duration)
        {
            const time_since_last_tap = self.total_time - self.last_tap_time;
            const tap_distance = @sqrt(
                (touch.x - self.last_tap_x) * (touch.x - self.last_tap_x) +
                    (touch.y - self.last_tap_y) * (touch.y - self.last_tap_y),
            );

            if (self.pending_tap != null and
                time_since_last_tap < self.config.double_tap_interval and
                tap_distance < self.config.double_tap_max_distance)
            {
                // Double tap detected
                self.current_double_tap = .{
                    .x = touch.x,
                    .y = touch.y,
                };
                self.pending_tap = null;
                self.tap_wait_timer = 0;
            } else {
                // Potential single tap - wait to see if double tap follows
                self.pending_tap = .{
                    .x = touch.x,
                    .y = touch.y,
                };
                self.tap_wait_timer = 0;
            }

            self.last_tap_time = self.total_time;
            self.last_tap_x = touch.x;
            self.last_tap_y = touch.y;
        }
    }

    fn getSwipeDirection(self: *const Self, dx: f32, dy: f32) SwipeDirection {
        _ = self;
        const abs_dx = @abs(dx);
        const abs_dy = @abs(dy);

        if (abs_dx > abs_dy) {
            return if (dx > 0) .right else .left;
        } else {
            return if (dy > 0) .down else .up;
        }
    }

    fn detectPinchAndRotation(self: *Self, touch1: Touch, touch2: Touch) void {
        const dx = touch2.x - touch1.x;
        const dy = touch2.y - touch1.y;
        const distance = @sqrt(dx * dx + dy * dy);
        const angle = std.math.atan2(dy, dx);
        const center_x = (touch1.x + touch2.x) / 2;
        const center_y = (touch1.y + touch2.y) / 2;

        // Pinch detection
        if (self.last_pinch_distance) |last_dist| {
            const dist_change = @abs(distance - last_dist);
            if (dist_change > self.config.pinch_threshold) {
                // Guard against division by zero when fingers overlap
                // Use a minimum denominator to prevent infinity
                const min_distance = 1.0; // 1 pixel minimum
                const safe_last_dist = @max(last_dist, min_distance);
                const scale = distance / safe_last_dist;
                self.current_pinch = .{
                    .scale = scale,
                    .center_x = center_x,
                    .center_y = center_y,
                    .distance = distance,
                };
            }
        } else {
            self.pinch_start_distance = distance;
        }
        self.last_pinch_distance = distance;

        // Rotation detection
        if (self.last_pinch_angle) |last_angle| {
            var angle_delta = angle - last_angle;
            // Normalize angle delta to [-PI, PI]
            while (angle_delta > std.math.pi) angle_delta -= 2 * std.math.pi;
            while (angle_delta < -std.math.pi) angle_delta += 2 * std.math.pi;

            if (@abs(angle_delta) > self.config.rotation_threshold) {
                const start_angle = self.rotation_start_angle orelse angle;
                var total_angle = angle - start_angle;
                while (total_angle > std.math.pi) total_angle -= 2 * std.math.pi;
                while (total_angle < -std.math.pi) total_angle += 2 * std.math.pi;

                self.current_rotation = .{
                    .angle_delta = angle_delta,
                    .angle = total_angle,
                    .center_x = center_x,
                    .center_y = center_y,
                };
            }
        } else {
            self.rotation_start_angle = angle;
        }
        self.last_pinch_angle = angle;
    }

    fn detectPan(self: *Self, touch: Touch) void {
        if (touch.phase != .moved) return;

        // Find the touch state
        for (&self.touch_states) |*state| {
            if (state.active and state.id == touch.id) {
                const dx = touch.x - state.last_x;
                const dy = touch.y - state.last_y;

                // Only emit pan if there's actual movement
                if (@abs(dx) > 0.5 or @abs(dy) > 0.5) {
                    self.current_pan = .{
                        .delta_x = dx,
                        .delta_y = dy,
                        .x = touch.x,
                        .y = touch.y,
                    };
                }
                break;
            }
        }
    }

    // =========================================================================
    // Public Gesture Getters
    // =========================================================================

    /// Get pinch gesture if detected this frame
    pub fn getPinch(self: *const Self) ?Pinch {
        return self.current_pinch;
    }

    /// Get pan gesture if detected this frame
    pub fn getPan(self: *const Self) ?Pan {
        return self.current_pan;
    }

    /// Get swipe gesture if detected this frame
    pub fn getSwipe(self: *const Self) ?Swipe {
        return self.current_swipe;
    }

    /// Get tap gesture if detected this frame
    pub fn getTap(self: *const Self) ?Tap {
        return self.current_tap;
    }

    /// Get double tap gesture if detected this frame
    pub fn getDoubleTap(self: *const Self) ?DoubleTap {
        return self.current_double_tap;
    }

    /// Get long press gesture if detected this frame
    pub fn getLongPress(self: *const Self) ?LongPress {
        return self.current_long_press;
    }

    /// Get rotation gesture if detected this frame
    pub fn getRotation(self: *const Self) ?Rotation {
        return self.current_rotation;
    }

    // =========================================================================
    // Configuration Methods
    // =========================================================================

    /// Set swipe threshold (minimum distance in pixels)
    pub fn setSwipeThreshold(self: *Self, threshold: f32) void {
        self.config.swipe_threshold = threshold;
    }

    /// Set long press duration (in seconds)
    pub fn setLongPressDuration(self: *Self, duration: f32) void {
        self.config.long_press_duration = duration;
    }

    /// Set double tap interval (max seconds between taps)
    pub fn setDoubleTapInterval(self: *Self, interval: f32) void {
        self.config.double_tap_interval = interval;
    }

    /// Set pinch threshold (minimum distance change in pixels)
    pub fn setPinchThreshold(self: *Self, threshold: f32) void {
        self.config.pinch_threshold = threshold;
    }

    /// Set rotation threshold (minimum angle change in radians)
    pub fn setRotationThreshold(self: *Self, threshold: f32) void {
        self.config.rotation_threshold = threshold;
    }

    /// Reset all gesture state
    pub fn reset(self: *Self) void {
        self.touch_states = [_]TouchState{.{}} ** MAX_TOUCHES;
        self.active_touch_count = 0;
        self.last_pinch_distance = null;
        self.last_pinch_angle = null;
        self.pinch_start_distance = null;
        self.rotation_start_angle = null;
        self.last_tap_time = 0;
        self.last_tap_x = 0;
        self.last_tap_y = 0;
        self.pending_tap = null;
        self.tap_wait_timer = 0;
        self.current_pinch = null;
        self.current_pan = null;
        self.current_swipe = null;
        self.current_tap = null;
        self.current_double_tap = null;
        self.current_long_press = null;
        self.current_rotation = null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Gestures: init" {
    var gestures = Gestures.init();
    try std.testing.expect(gestures.getPinch() == null);
    try std.testing.expect(gestures.getPan() == null);
    try std.testing.expect(gestures.getSwipe() == null);
    try std.testing.expect(gestures.getTap() == null);
}

test "Gestures: tap detection" {
    var gestures = Gestures.init();

    // Simulate tap: began -> ended quickly without movement
    const touch_began = [_]Touch{.{
        .id = 1,
        .x = 100,
        .y = 100,
        .phase = .began,
    }};
    gestures.updateWithTouches(&touch_began, 0.016);

    const touch_ended = [_]Touch{.{
        .id = 1,
        .x = 100,
        .y = 100,
        .phase = .ended,
    }};
    gestures.updateWithTouches(&touch_ended, 0.016);

    // Tap is pending (waiting for potential double-tap)
    try std.testing.expect(gestures.pending_tap != null);

    // Wait for double-tap timeout
    const no_touch = [_]Touch{};
    gestures.updateWithTouches(&no_touch, 0.35);

    // Now tap should be emitted
    try std.testing.expect(gestures.getTap() != null);
}

test "Gestures: pinch detection" {
    var gestures = Gestures.init();

    // Two fingers start
    const touches1 = [_]Touch{
        .{ .id = 1, .x = 100, .y = 100, .phase = .began },
        .{ .id = 2, .x = 200, .y = 100, .phase = .began },
    };
    gestures.updateWithTouches(&touches1, 0.016);

    // Fingers move apart (zoom in)
    const touches2 = [_]Touch{
        .{ .id = 1, .x = 50, .y = 100, .phase = .moved },
        .{ .id = 2, .x = 250, .y = 100, .phase = .moved },
    };
    gestures.updateWithTouches(&touches2, 0.016);

    const pinch = gestures.getPinch();
    try std.testing.expect(pinch != null);
    if (pinch) |p| {
        try std.testing.expect(p.scale > 1.0); // Zoom in
    }
}

test "Gestures: swipe detection" {
    var gestures = Gestures.init();
    gestures.config.swipe_threshold = 30;
    gestures.config.swipe_min_velocity = 100;

    // Touch began
    const touch1 = [_]Touch{.{
        .id = 1,
        .x = 100,
        .y = 100,
        .phase = .began,
    }};
    gestures.updateWithTouches(&touch1, 0.016);

    // Quick swipe right
    const touch2 = [_]Touch{.{
        .id = 1,
        .x = 200,
        .y = 100,
        .phase = .ended,
    }};
    gestures.updateWithTouches(&touch2, 0.1); // 100px in 0.1s = 1000px/s

    const swipe = gestures.getSwipe();
    try std.testing.expect(swipe != null);
    if (swipe) |s| {
        try std.testing.expect(s.direction == .right);
    }
}
