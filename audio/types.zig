//! Audio Types
//!
//! Shared types for the audio system, used across all backends.

/// Opaque handle for a loaded sound effect.
/// Sounds are loaded entirely into memory and are suitable for short audio clips.
pub const SoundId = struct {
    index: u16,
    generation: u16,

    pub const invalid: SoundId = .{ .index = 0, .generation = 0 };

    pub fn isValid(self: SoundId) bool {
        return self.generation != 0;
    }
};

/// Opaque handle for a loaded music stream.
/// Music is streamed from disk and is suitable for longer audio tracks.
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
    /// Audio system failed to initialize
    AudioNotSupported,
    /// Failed to load audio file
    LoadFailed,
    /// Maximum number of sounds/music reached
    SlotsFull,
};
