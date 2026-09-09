//! One deferred free of an allocation a buffered event payload borrows
//! (#862/#863).
//!
//! Its own module so both `game.zig` (which declares the field) and
//! `game/events_mixin.zig` (which links the nodes) can name the type
//! without importing each other.
//!
//! The node is allocated when a caller RESERVES, before the event is
//! emitted — see `events_mixin.reserveRetention` for why that ordering is
//! the whole design.

/// A single retained allocation, linked into either the pending-free
/// chain or the spare (reserved-but-unused) chain.
pub const RetainNode = struct {
    slice: []const u8 = &.{},
    next: ?*RetainNode = null,
};
