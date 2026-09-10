const std = @import("std");
const Clip = @import("definition.zig").Clip;

/// Shared boundary vocabulary, also re-exported by engine.anim_timing.
pub const BoundaryMode = enum { loop, once, ping_pong };

pub const Occurrence = struct {
    kind: enum { marker, complete, loop },
    marker_index: u16 = 0,
    frame: u8,
    repetition: u64,
    sequence: u64,
};

/// Allocation-free, resumable crossing traversal. A sink either accepts one
/// occurrence or returns an error without accepting it. The cursor advances
/// its occurrence sequence only after success, so retries cannot duplicate it.
///
/// Time is offered only after the previous batch drains. Busy means the caller
/// must retain the offered delta or explicitly freeze its clock (backpressure),
/// never pretend the delta was accepted. At most 2^32 beats fit in one batch.
/// Each pump is bounded by BOTH entered frames and attempted event deliveries.
pub const MarkerCursor = struct {
    frame: u8 = 0,
    forward: bool = true,
    repetition: u64 = 0,
    sequence: u64 = 0,
    fraction: f64 = 0,
    steps: u64 = 0,
    marker_index: usize = 0,
    entering: bool = true,
    loop_pending: bool = false,
    complete_pending: bool = false,
    completed: bool = false,

    pub const Budget = struct { frames: usize = 256, events: usize = 64 };
    pub const Result = struct { frames: usize, events: usize, pending: bool };

    pub fn pending(self: *const MarkerCursor) bool {
        return self.steps != 0 or self.entering or self.loop_pending or self.complete_pending;
    }

    pub fn offer(self: *MarkerCursor, seconds: f64, fps: f64) !void {
        if (!std.math.isFinite(seconds) or seconds < 0 or !std.math.isFinite(fps) or fps <= 0)
            return error.InvalidTime;
        // The initial frame-zero visit can be drained together with first dt.
        if (self.steps != 0 or self.loop_pending or self.complete_pending or
            (self.entering and self.sequence != 0)) return error.Busy;
        if (self.completed) return;
        const beats = seconds * fps + self.fraction;
        if (!std.math.isFinite(beats) or beats >= 4294967296.0) return error.TimeOverflow;
        self.steps = @intFromFloat(@floor(beats));
        self.fraction = beats - @floor(beats);
    }

    pub fn pump(self: *MarkerCursor, clip: *const Clip, mode: BoundaryMode, budget: Budget, sink: anytype) !Result {
        if (clip.frames.len == 0 or clip.frames.len > 255 or self.frame >= clip.frames.len)
            return error.InvalidFrame;
        var result = Result{ .frames = 0, .events = 0, .pending = true };
        while (true) {
            if (self.loop_pending) {
                if (result.events == budget.events) return result;
                try self.send(sink, .loop, 0);
                self.loop_pending = false;
                result.events += 1;
            }
            if (self.entering) {
                while (self.marker_index < clip.markers.len) {
                    const index = self.marker_index;
                    if (clip.markers[index].frame == self.frame) {
                        if (result.events == budget.events) return result;
                        try self.send(sink, .marker, @intCast(index));
                        result.events += 1;
                    }
                    self.marker_index += 1;
                }
                self.entering = false;
                self.marker_index = 0;
                if (mode == .once and (if (self.forward) self.frame + 1 == clip.frames.len else self.frame == 0))
                    self.complete_pending = true;
            }
            if (self.complete_pending) {
                if (result.events == budget.events) return result;
                try self.send(sink, .complete, 0);
                self.complete_pending = false;
                self.completed = true;
                self.steps = 0;
                self.fraction = 0;
                result.events += 1;
            }
            if (self.steps == 0 or self.completed) {
                result.pending = false;
                return result;
            }
            if (result.frames == budget.frames) return result;
            const last: u8 = @intCast(clip.frames.len - 1);
            // Check overflow before committing the crossing, not afterwards.
            const boundary = if (self.forward) self.frame == last else self.frame == 0;
            if (mode != .once and boundary and self.repetition == std.math.maxInt(u64))
                return error.IdentityExhausted;
            self.steps -= 1;
            result.frames += 1;
            if (mode == .once and boundary) {
                self.complete_pending = true;
                continue;
            }
            if (boundary) {
                self.repetition += 1;
                self.loop_pending = true;
                switch (mode) {
                    .loop => self.frame = if (self.forward) 0 else last,
                    .ping_pong => {
                        self.forward = !self.forward;
                        // A single-frame ping-pong does not re-enter its only
                        // frame merely because its direction changes.
                        if (last == 0) continue;
                        self.frame = if (self.forward) 1 else last - 1;
                    },
                    .once => unreachable,
                }
            } else if (self.forward) {
                self.frame += 1;
            } else {
                self.frame -= 1;
            }
            self.entering = true;
        }
    }

    fn send(self: *MarkerCursor, sink: anytype, kind: @FieldType(Occurrence, "kind"), marker_index: u16) !void {
        if (self.sequence == std.math.maxInt(u64)) return error.IdentityExhausted;
        try sink.emit(Occurrence{
            .kind = kind,
            .marker_index = marker_index,
            .frame = self.frame,
            .repetition = self.repetition,
            .sequence = self.sequence,
        });
        self.sequence += 1;
    }
};
