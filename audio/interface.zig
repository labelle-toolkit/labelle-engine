//! Audio Interface
//!
//! Provides a unified audio API with compile-time backend selection.
//! The backend is chosen at build time based on the graphics backend.
//!
//! Note: All backends have audio support. Raylib uses its native audio
//! system; sokol and SDL use the miniaudio backend via zaudio. The
//! AudioNotSupported error is only returned if audio initialization fails.
//!
//! Usage:
//!   const audio = @import("audio");
//!   var aud = audio.Audio.init();
//!   const sound = try aud.loadSound("assets/jump.wav");
//!   aud.playSound(sound);

const build_options = @import("build_options");

// Re-export types
pub const types = @import("types.zig");
pub const SoundId = types.SoundId;
pub const MusicId = types.MusicId;
pub const AudioError = types.AudioError;

/// Graphics backend selection (enum type)
pub const Backend = build_options.@"build.Backend";

/// The current graphics backend (enum value)
pub const backend: Backend = build_options.backend;

/// Creates a validated audio interface from an implementation type.
/// The implementation must provide all required methods.
pub fn AudioInterface(comptime Impl: type) type {
    // Compile-time validation: ensure Impl has all required methods
    comptime {
        const required_fns = .{
            "init",           "deinit",         "update",
            "loadSound",      "unloadSound",    "playSound",      "stopSound",      "setSoundVolume", "isSoundPlaying",
            "loadMusic",      "unloadMusic",    "playMusic",      "stopMusic",      "pauseMusic",     "resumeMusic",    "setMusicVolume", "isMusicPlaying",
            "setMasterVolume", "isAvailable",
        };
        for (required_fns) |name| {
            if (!@hasDecl(Impl, name)) {
                @compileError("Audio backend must have " ++ name ++ " method");
            }
        }
    }

    return struct {
        const Self = @This();

        /// The underlying implementation type
        pub const Implementation = Impl;

        impl: Impl,

        /// Initialize the audio system
        pub fn init() Self {
            return .{ .impl = Impl.init() };
        }

        /// Clean up the audio system
        pub fn deinit(self: *Self) void {
            self.impl.deinit();
        }

        /// Update the audio system (must be called each frame for music streaming)
        pub fn update(self: *Self) void {
            self.impl.update();
        }

        // ==================== Sound Effects ====================

        /// Load a sound effect from file
        pub fn loadSound(self: *Self, path: [:0]const u8) AudioError!SoundId {
            return self.impl.loadSound(path);
        }

        /// Unload a sound effect
        pub fn unloadSound(self: *Self, sound: SoundId) void {
            self.impl.unloadSound(sound);
        }

        /// Play a sound effect
        pub fn playSound(self: *Self, sound: SoundId) void {
            self.impl.playSound(sound);
        }

        /// Stop a playing sound effect
        pub fn stopSound(self: *Self, sound: SoundId) void {
            self.impl.stopSound(sound);
        }

        /// Set volume for a sound effect (0.0 to 1.0)
        pub fn setSoundVolume(self: *Self, sound: SoundId, volume: f32) void {
            self.impl.setSoundVolume(sound, volume);
        }

        /// Check if a sound effect is currently playing
        pub fn isSoundPlaying(self: *const Self, sound: SoundId) bool {
            return self.impl.isSoundPlaying(sound);
        }

        // ==================== Music ====================

        /// Load a music stream from file
        pub fn loadMusic(self: *Self, path: [:0]const u8) AudioError!MusicId {
            return self.impl.loadMusic(path);
        }

        /// Unload a music stream
        pub fn unloadMusic(self: *Self, music: MusicId) void {
            self.impl.unloadMusic(music);
        }

        /// Start playing music
        pub fn playMusic(self: *Self, music: MusicId) void {
            self.impl.playMusic(music);
        }

        /// Stop playing music
        pub fn stopMusic(self: *Self, music: MusicId) void {
            self.impl.stopMusic(music);
        }

        /// Pause music playback
        pub fn pauseMusic(self: *Self, music: MusicId) void {
            self.impl.pauseMusic(music);
        }

        /// Resume music playback
        pub fn resumeMusic(self: *Self, music: MusicId) void {
            self.impl.resumeMusic(music);
        }

        /// Set volume for music (0.0 to 1.0)
        pub fn setMusicVolume(self: *Self, music: MusicId, volume: f32) void {
            self.impl.setMusicVolume(music, volume);
        }

        /// Check if music is currently playing
        pub fn isMusicPlaying(self: *const Self, music: MusicId) bool {
            return self.impl.isMusicPlaying(music);
        }

        // ==================== Global ====================

        /// Set master volume (0.0 to 1.0)
        pub fn setMasterVolume(self: *Self, volume: f32) void {
            self.impl.setMasterVolume(volume);
        }

        /// Check if audio is available on this backend
        pub fn isAvailable(self: *const Self) bool {
            return self.impl.isAvailable();
        }
    };
}

// Select and validate audio backend based on graphics backend
// Raylib has its own audio system; sokol, SDL, and bgfx use miniaudio via zaudio
const BackendImpl = switch (backend) {
    .raylib => @import("raylib_audio.zig"),
    .sokol => @import("miniaudio_audio.zig"),
    .sdl => @import("miniaudio_audio.zig"),
    .bgfx => @import("miniaudio_audio.zig"),
};

/// The Audio type for the selected backend
pub const Audio = AudioInterface(BackendImpl);
