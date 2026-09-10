const std = @import("std");
const animation = @import("animation");
const SpriteAnimation = @import("sprite_animation.zig").SpriteAnimation;

/// Named clips stall their animation clock under backpressure. Accepted beats
/// stay in the cursor; new wall time is not accumulated while a batch is still
/// pending. This deliberately slows overloaded playback rather than losing
/// cues or allocating an unbounded pending list. Existing queued cues survive
/// clip replacement and carry their original playback identity.
pub fn advance(game: anytype, entity: anytype, anim: *SpriteAnimation, dt: f32) bool {
    const G = @TypeOf(game.*);
    const old_frame = anim.frame;
    if (anim.marker_target_id == 0) anim.marker_target_id = game.nextAnimationIdentity();
    if (anim.marker_playback_id == 0) anim.marker_playback_id = game.nextAnimationIdentity();
    var sink = Sink(G){ .game = game, .entity = @intCast(entity), .anim = anim };
    const clip = animation.Clip{ .name = anim.clip, .frames = anim.frames, .markers = anim.markers };
    const mode: animation.BoundaryMode = @enumFromInt(@intFromEnum(anim.mode));
    var budget: animation.MarkerCursor.Budget = .{};
    // Pause freezes traversal, including deferred beats. A cue for a frame
    // already entered may still finish its queue handoff while paused.
    if (dt <= 0 or !std.math.isFinite(dt) or anim.fps <= 0 or !std.math.isFinite(anim.fps)) budget.frames = 0;
    // First finish any older batch, including initial frame zero. Do not
    // replenish budgets between the old and new portions of this update.
    const previous = anim.marker_cursor.pump(&clip, mode, budget, &sink) catch |err| {
        stalled(game, anim, err);
        return syncState(anim, old_frame);
    };
    if (previous.pending) {
        if (dt > 0) stalled(game, anim, error.MarkerBudgetExhausted);
        return syncState(anim, old_frame);
    }
    budget.frames -= previous.frames;
    budget.events -= previous.events;
    if (dt > 0 and std.math.isFinite(dt) and anim.fps > 0 and std.math.isFinite(anim.fps)) {
        anim.marker_cursor.offer(dt, anim.fps) catch |err| {
            stalled(game, anim, err);
            return syncState(anim, old_frame);
        };
        const result = anim.marker_cursor.pump(&clip, mode, budget, &sink) catch |err| {
            stalled(game, anim, err);
            return syncState(anim, old_frame);
        };
        if (result.pending) {
            stalled(game, anim, error.MarkerBudgetExhausted);
            return syncState(anim, old_frame);
        }
    }
    anim.marker_stalled = false;
    return syncState(anim, old_frame);
}

fn syncState(anim: *SpriteAnimation, old: u8) bool {
    anim.frame = anim.marker_cursor.frame;
    anim.forward = anim.marker_cursor.forward;
    anim.repetition = @intCast(@min(anim.marker_cursor.repetition, std.math.maxInt(u16)));
    anim.finished_emitted = anim.marker_cursor.completed;
    anim.timer = if (anim.fps > 0 and anim.marker_cursor.steps == 0) @floatCast(anim.marker_cursor.fraction / anim.fps) else 0;
    return anim.frame != old;
}

fn stalled(game: anytype, anim: *SpriteAnimation, err: anyerror) void {
    if (!anim.marker_stalled) game.log.warn("animation '{s}' clip '{s}' stalled: {s}; retaining pending crossings", .{ anim.definition, anim.clip, @errorName(err) });
    anim.marker_stalled = true;
}

fn Sink(comptime G: type) type {
    return struct {
        game: *G,
        entity: u64,
        anim: *const SpriteAnimation,
        pub fn emit(self: *@This(), event: animation.Occurrence) !void {
            switch (event.kind) {
                .marker => if (comptime G.engineEventWanted("engine__anim_marker")) {
                    try self.game.tryEmit(.{ .engine__anim_marker = .{
                        .entity = self.entity,
                        .target_id = self.anim.marker_target_id,
                        .playback_id = self.anim.marker_playback_id,
                        .sequence = event.sequence,
                        .definition = self.anim.definition,
                        .clip = self.anim.clip,
                        .marker = self.anim.markers[event.marker_index].name,
                        .marker_index = event.marker_index,
                        .frame = event.frame,
                        .repetition = event.repetition,
                    } });
                },
                .complete => if (comptime G.engineEventWanted("engine__anim_complete")) {
                    try self.game.tryEmit(.{ .engine__anim_complete = .{ .entity = @intCast(self.entity) } });
                },
                .loop => if (comptime G.engineEventWanted("engine__anim_loop")) {
                    try self.game.tryEmit(.{ .engine__anim_loop = .{ .entity = @intCast(self.entity), .repetition = @intCast(@min(event.repetition, std.math.maxInt(u16))) } });
                },
            }
        }
    };
}
