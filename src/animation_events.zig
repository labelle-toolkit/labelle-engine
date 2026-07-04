/// Animation events (#670) — per-frame markers + clip lifecycle events,
/// delivered through the game's buffered event bus (`game.emit`).
///
/// Today gameplay cannot react to "frame N of clip X was shown" without a
/// hand-rolled timer (see `worker_animation.zig`'s combat cadence). This
/// module defines the event payloads and the transport-agnostic scratch
/// buffer the pure animation `advance` methods append to; the engine
/// driver that ticks animations forwards them to `game.emit` (adding the
/// entity, which the component methods don't know).
///
/// Design follows bevy_spritesheet_animation: a small event vocabulary
/// (marker hit, clip end, loop end) carrying entity + clip + repetition
/// context, dispatched through the native event bus rather than closures
/// owned by the animation. Marker NAMES live in the `.zon` clip data;
/// their HANDLERS live in the game's `hooks/` files (PaperZD's
/// define-once/receive-everywhere).
///
/// ## Transient by design
/// All event bookkeeping (pending buffers, `finished_emitted` bits,
/// repetition counters) is runtime-only and never serialized — mirrors
/// the existing frame/timer save policy.

const std = @import("std");

/// Fired when a clip-frame carrying a marker becomes current.
/// `repetition` is the loop count at the moment it fired (saturating).
pub fn AnimMarkerHit(comptime Entity: type) type {
    return struct {
        entity: Entity,
        clip: u8,
        frame: u8,
        marker: []const u8,
        repetition: u16,
    };
}

/// Fired when a non-looping clip reaches its final frame (`AnimationState`
/// on a `.static`/one-shot clip) or a `.once` `SpriteAnimation` finishes.
/// Fires exactly once per play-through.
pub fn AnimClipEnd(comptime Entity: type) type {
    return struct {
        entity: Entity,
        clip: u8,
    };
}

/// Fired at every wrap of a looping clip (and at each `.ping_pong`
/// endpoint reversal). `repetition` is the saturating loop count.
pub fn AnimLoopEnd(comptime Entity: type) type {
    return struct {
        entity: Entity,
        clip: u8,
        repetition: u16,
    };
}

pub const PendingKind = enum(u8) { marker, clip_end, loop_end };

/// Entity-less intermediate produced by the pure `advance` methods (which
/// don't know the entity). The driver reads `PendingBuf.slice()` and emits
/// the matching `Anim*` payload, filling in the entity.
pub const PendingAnimEvent = struct {
    kind: PendingKind,
    clip: u8 = 0,
    /// For `.marker`: the slot the marker sits on. Else unused.
    frame: u8 = 0,
    /// For `.marker`: the marker name (borrowed from comptime clip data).
    marker: []const u8 = "",
    /// For `.marker`/`.loop_end`: the loop count when it fired.
    repetition: u16 = 0,
};

/// Max events one `advance` call can queue. A single tick crosses only a
/// handful of frames in practice; a pathological dt that would exceed this
/// is capped (the tail of markers/loop-ends is dropped) so the buffer and
/// the traversal both stay bounded. The saturating repetition counter is
/// still updated arithmetically across the full span, so `AnimLoopEnd`
/// counts stay accurate even when emission is capped.
pub const max_pending = 32;

/// Fixed-capacity append buffer (inline; `std.BoundedArray` was removed in
/// Zig 0.16). Overflow is silently capped — see `max_pending`.
pub const PendingBuf = struct {
    items: [max_pending]PendingAnimEvent = undefined,
    len: u8 = 0,

    /// Append if there is room; returns false when the buffer is full
    /// (caller may use this to note a capped tick).
    pub fn append(self: *PendingBuf, e: PendingAnimEvent) bool {
        if (self.len >= max_pending) return false;
        self.items[self.len] = e;
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const PendingBuf) []const PendingAnimEvent {
        return self.items[0..self.len];
    }

    pub fn clear(self: *PendingBuf) void {
        self.len = 0;
    }

    pub fn isFull(self: *const PendingBuf) bool {
        return self.len >= max_pending;
    }
};

/// Saturating u16 add — the repetition counter never wraps (a 60fps loop
/// of a 4-frame clip would overflow u16 in ~1.2h; saturate, don't wrap).
pub fn satAddU16(a: u16, b: u16) u16 {
    const sum: u32 = @as(u32, a) + @as(u32, b);
    return if (sum > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(sum);
}
