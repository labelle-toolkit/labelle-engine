//! Audio Types
//!
//! Shared types for the audio system, used across all backends.
//! These are backend-agnostic data types — the actual audio playback
//! is done via AudioInterface(Impl) from labelle-core.

/// Opaque handle for a loaded sound effect.
pub const SoundId = struct {
    index: u16,
    generation: u16,

    pub const invalid: SoundId = .{ .index = 0, .generation = 0 };

    pub fn isValid(self: SoundId) bool {
        return self.generation != 0;
    }
};

/// Opaque handle for a loaded music stream.
pub const MusicId = struct {
    index: u16,
    generation: u16,

    pub const invalid: MusicId = .{ .index = 0, .generation = 0 };

    pub fn isValid(self: MusicId) bool {
        return self.generation != 0;
    }
};

/// Audio loading errors
pub const AudioError = error{
    AudioNotSupported,
    LoadFailed,
    SlotsFull,
};
