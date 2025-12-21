//! Sokol Audio Backend
//!
//! No-op stub implementation. Sokol-zig does not include audio support.
//! All load functions return AudioNotSupported error.
//! All playback functions are no-ops.

const types = @import("types.zig");

pub const SoundId = types.SoundId;
pub const MusicId = types.MusicId;
pub const AudioError = types.AudioError;

const Self = @This();

/// Initialize the audio system (no-op)
pub fn init() Self {
    return .{};
}

/// Clean up the audio system (no-op)
pub fn deinit(self: *Self) void {
    _ = self;
}

/// Update audio system (no-op)
pub fn update(self: *Self) void {
    _ = self;
}

// ==================== Sound Effects ====================

/// Load a sound effect (not supported)
pub fn loadSound(self: *Self, path: [:0]const u8) AudioError!SoundId {
    _ = self;
    _ = path;
    return AudioError.AudioNotSupported;
}

/// Unload a sound effect (no-op)
pub fn unloadSound(self: *Self, sound: SoundId) void {
    _ = self;
    _ = sound;
}

/// Play a sound effect (no-op)
pub fn playSound(self: *Self, sound: SoundId) void {
    _ = self;
    _ = sound;
}

/// Stop a playing sound effect (no-op)
pub fn stopSound(self: *Self, sound: SoundId) void {
    _ = self;
    _ = sound;
}

/// Set volume for a sound effect (no-op)
pub fn setSoundVolume(self: *Self, sound: SoundId, volume: f32) void {
    _ = self;
    _ = sound;
    _ = volume;
}

/// Check if a sound effect is currently playing (always false)
pub fn isSoundPlaying(self: *const Self, sound: SoundId) bool {
    _ = self;
    _ = sound;
    return false;
}

// ==================== Music ====================

/// Load a music stream (not supported)
pub fn loadMusic(self: *Self, path: [:0]const u8) AudioError!MusicId {
    _ = self;
    _ = path;
    return AudioError.AudioNotSupported;
}

/// Unload a music stream (no-op)
pub fn unloadMusic(self: *Self, music: MusicId) void {
    _ = self;
    _ = music;
}

/// Start playing music (no-op)
pub fn playMusic(self: *Self, music: MusicId) void {
    _ = self;
    _ = music;
}

/// Stop playing music (no-op)
pub fn stopMusic(self: *Self, music: MusicId) void {
    _ = self;
    _ = music;
}

/// Pause music playback (no-op)
pub fn pauseMusic(self: *Self, music: MusicId) void {
    _ = self;
    _ = music;
}

/// Resume music playback (no-op)
pub fn resumeMusic(self: *Self, music: MusicId) void {
    _ = self;
    _ = music;
}

/// Set volume for music (no-op)
pub fn setMusicVolume(self: *Self, music: MusicId, volume: f32) void {
    _ = self;
    _ = music;
    _ = volume;
}

/// Check if music is currently playing (always false)
pub fn isMusicPlaying(self: *const Self, music: MusicId) bool {
    _ = self;
    _ = music;
    return false;
}

// ==================== Global ====================

/// Set master volume (no-op)
pub fn setMasterVolume(self: *Self, volume: f32) void {
    _ = self;
    _ = volume;
}

/// Check if audio is available (always false for sokol)
pub fn isAvailable(self: *const Self) bool {
    _ = self;
    return false;
}
