//! Gesture Recognition Module
//!
//! High-level gesture detection built on top of raw touch input.
//! Supports: pinch, pan, swipe, tap, double-tap, long press, rotation.

const std = @import("std");
const input_types = @import("input_types.zig");
const Touch = input_types.Touch;
const TouchPhase = input_types.TouchPhase;
const MAX_TOUCHES = input_types.MAX_TOUCHES;

pub const SwipeDirection = enum { up, down, left, right };

pub const Pinch = struct {
    scale: f32,
    center_x: f32,
    center_y: f32,
    distance: f32,
};

pub const Pan = struct {
    delta_x: f32,
    delta_y: f32,
    x: f32,
    y: f32,
};

pub const Swipe = struct {
    direction: SwipeDirection,
    velocity: f32,
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
};

pub const Tap = struct {
    x: f32,
    y: f32,
};

pub const DoubleTap = struct {
    x: f32,
    y: f32,
};

pub const LongPress = struct {
    x: f32,
    y: f32,
    duration: f32,
};

pub const Rotation = struct {
    angle_delta: f32,
    angle: f32,
    center_x: f32,
    center_y: f32,
};

const TouchState = struct {
    id: u64 = 0,
    start_x: f32 = 0,
    start_y: f32 = 0,
    start_time: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    active: bool = false,
    was_in_multitouch: bool = false,
};

pub const Gestures = struct {
    const Self = @This();

    config: Config = .{},

    touch_states: [MAX_TOUCHES]TouchState = [_]TouchState{.{}} ** MAX_TOUCHES,
    active_touch_count: u32 = 0,

    last_pinch_distance: ?f32 = null,
    last_pinch_angle: ?f32 = null,
    pinch_start_distance: ?f32 = null,
    rotation_start_angle: ?f32 = null,

    last_tap_time: f32 = 0,
    last_tap_x: f32 = 0,
    last_tap_y: f32 = 0,
    pending_tap: ?Tap = null,
    tap_wait_timer: f32 = 0,

    current_pinch: ?Pinch = null,
    current_pan: ?Pan = null,
    current_swipe: ?Swipe = null,
    current_tap: ?Tap = null,
    current_double_tap: ?DoubleTap = null,
    current_long_press: ?LongPress = null,
    current_rotation: ?Rotation = null,

    total_time: f32 = 0,

    pub const Config = struct {
        swipe_threshold: f32 = 50.0,
        swipe_min_velocity: f32 = 200.0,
        swipe_max_duration: f32 = 0.5,
        long_press_duration: f32 = 0.5,
        double_tap_interval: f32 = 0.3,
        tap_max_movement: f32 = 20.0,
        tap_max_duration: f32 = 0.3,
        double_tap_max_distance: f32 = 40.0,
        pinch_threshold: f32 = 5.0,
        rotation_threshold: f32 = 0.05,
    };

    pub fn init() Self {
        return .{};
    }

    pub fn initWithConfig(config: Config) Self {
        return .{ .config = config };
    }

    pub fn updateWithTouches(self: *Self, touches: []const Touch, dt: f32) void {
        self.total_time += dt;

        self.current_pinch = null;
        self.current_pan = null;
        self.current_swipe = null;
        self.current_tap = null;
        self.current_double_tap = null;
        self.current_long_press = null;
        self.current_rotation = null;

        if (self.pending_tap) |_| {
            self.tap_wait_timer += dt;
            if (self.tap_wait_timer >= self.config.double_tap_interval) {
                self.current_tap = self.pending_tap;
                self.pending_tap = null;
                self.tap_wait_timer = 0;
            }
        }

        const touch_count: u32 = @intCast(touches.len);
        self.active_touch_count = touch_count;

        for (touches, 0..) |touch, i| {
            self.processTouch(touch, @intCast(i));
        }

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

        if (touch_count == 2) {
            self.detectPinchAndRotation(touches[0], touches[1]);
            for (&self.touch_states) |*state| {
                if (state.active and (state.id == touches[0].id or state.id == touches[1].id)) {
                    state.was_in_multitouch = true;
                }
            }
        } else {
            self.last_pinch_distance = null;
            self.last_pinch_angle = null;
            self.pinch_start_distance = null;
            self.rotation_start_angle = null;
        }
    }

    fn processTouch(self: *Self, touch: Touch, _: usize) void {
        switch (touch.phase) {
            .began => {
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
                if (self.findTouchState(touch.id)) |state| {
                    const move_dx = touch.x - state.last_x;
                    const move_dy = touch.y - state.last_y;

                    if (self.active_touch_count == 1 and (@abs(move_dx) > 0.5 or @abs(move_dy) > 0.5)) {
                        self.current_pan = .{
                            .delta_x = move_dx,
                            .delta_y = move_dy,
                            .x = touch.x,
                            .y = touch.y,
                        };
                    }

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

        if (state.was_in_multitouch) return;

        if (distance >= self.config.swipe_threshold and
            duration <= self.config.swipe_max_duration and
            duration > 0)
        {
            const velocity = distance / duration;
            if (velocity >= self.config.swipe_min_velocity and std.math.isFinite(velocity)) {
                const abs_dx = @abs(dx);
                const abs_dy = @abs(dy);
                const direction: SwipeDirection = if (abs_dx > abs_dy)
                    (if (dx > 0) .right else .left)
                else
                    (if (dy > 0) .down else .up);
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
                self.current_double_tap = .{ .x = touch.x, .y = touch.y };
                self.pending_tap = null;
                self.tap_wait_timer = 0;
            } else {
                self.pending_tap = .{ .x = touch.x, .y = touch.y };
                self.tap_wait_timer = 0;
            }

            self.last_tap_time = self.total_time;
            self.last_tap_x = touch.x;
            self.last_tap_y = touch.y;
        }
    }

    fn detectPinchAndRotation(self: *Self, touch1: Touch, touch2: Touch) void {
        const dx = touch2.x - touch1.x;
        const dy = touch2.y - touch1.y;
        const distance = @sqrt(dx * dx + dy * dy);
        const angle = std.math.atan2(dy, dx);
        const center_x = (touch1.x + touch2.x) / 2;
        const center_y = (touch1.y + touch2.y) / 2;

        if (self.last_pinch_distance) |last_dist| {
            const dist_change = @abs(distance - last_dist);
            if (dist_change > self.config.pinch_threshold) {
                const safe_last_dist = @max(last_dist, 1.0);
                self.current_pinch = .{
                    .scale = distance / safe_last_dist,
                    .center_x = center_x,
                    .center_y = center_y,
                    .distance = distance,
                };
            }
        }
        self.last_pinch_distance = distance;

        if (self.last_pinch_angle) |last_angle| {
            var angle_delta = angle - last_angle;
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

    pub fn getPinch(self: *const Self) ?Pinch {
        return self.current_pinch;
    }

    pub fn getPan(self: *const Self) ?Pan {
        return self.current_pan;
    }

    pub fn getSwipe(self: *const Self) ?Swipe {
        return self.current_swipe;
    }

    pub fn getTap(self: *const Self) ?Tap {
        return self.current_tap;
    }

    pub fn getDoubleTap(self: *const Self) ?DoubleTap {
        return self.current_double_tap;
    }

    pub fn getLongPress(self: *const Self) ?LongPress {
        return self.current_long_press;
    }

    pub fn getRotation(self: *const Self) ?Rotation {
        return self.current_rotation;
    }

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

