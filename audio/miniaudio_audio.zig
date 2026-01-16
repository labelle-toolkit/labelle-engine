//! Miniaudio Audio Backend
//!
//! Full audio implementation using zaudio/miniaudio.
//! Used for sokol and SDL backends which don't have built-in audio.
//! Supports both sound effects (loaded into memory) and music (streamed).

const std = @import("std");
const zaudio = @import("zaudio");
const types = @import("types.zig");

pub const SoundId = types.SoundId;
pub const MusicId = types.MusicId;
pub const AudioError = types.AudioError;

const Self = @This();

// Maximum number of sounds and music tracks
const MAX_SOUNDS = 64;
const MAX_MUSIC = 8;

/// Sound slot with generation counter for handle validation
const SoundSlot = struct {
    sound: ?*zaudio.Sound,
    generation: u16,
    active: bool,
};

/// Music slot with generation counter for handle validation
const MusicSlot = struct {
    sound: ?*zaudio.Sound,
    generation: u16,
    active: bool,
    pause_frame: u64, // Cursor position when paused (for resume)
};

/// zaudio engine
engine: ?*zaudio.Engine,
/// Allocator for zaudio
allocator: std.mem.Allocator,
/// Sound slots array
sounds: [MAX_SOUNDS]SoundSlot,
/// Music slots array
music: [MAX_MUSIC]MusicSlot,
/// Next generation counter for sounds
sound_generation: u16,
/// Next generation counter for music
music_generation: u16,
/// Whether audio was successfully initialized
initialized: bool,

/// Initialize the audio system
pub fn init() Self {
    const allocator = @import("../platform.zig").getDefaultAllocator();

    var self = Self{
        .engine = null,
        .allocator = allocator,
        .sounds = undefined,
        .music = undefined,
        .sound_generation = 1,
        .music_generation = 1,
        .initialized = false,
    };

    // Initialize all slots as inactive
    self.sounds = std.mem.zeroes([MAX_SOUNDS]SoundSlot);
    self.music = std.mem.zeroes([MAX_MUSIC]MusicSlot);

    // Initialize zaudio
    zaudio.init(allocator);

    // Create audio engine
    self.engine = zaudio.Engine.create(null) catch {
        // Audio initialization failed, but we don't want to crash
        // isAvailable() will return false
        return self;
    };

    self.initialized = true;
    return self;
}

/// Clean up the audio system
pub fn deinit(self: *Self) void {
    // Unload all sounds
    for (&self.sounds) |*slot| {
        if (slot.active) {
            if (slot.sound) |sound| {
                sound.destroy();
            }
            slot.active = false;
        }
    }

    // Unload all music
    for (&self.music) |*slot| {
        if (slot.active) {
            if (slot.sound) |sound| {
                sound.destroy();
            }
            slot.active = false;
        }
    }

    // Destroy engine
    if (self.engine) |engine| {
        engine.destroy();
        self.engine = null;
    }

    zaudio.deinit();
    self.initialized = false;
}

/// Update audio system (no-op for miniaudio, it handles streaming internally)
pub fn update(self: *Self) void {
    _ = self;
    // miniaudio handles streaming internally, no update needed
}

// ==================== Sound Effects ====================

/// Load a sound effect from file
pub fn loadSound(self: *Self, path: [:0]const u8) AudioError!SoundId {
    if (!self.initialized) return AudioError.AudioNotSupported;

    const engine = self.engine orelse return AudioError.AudioNotSupported;

    // Find an empty slot
    for (&self.sounds, 0..) |*slot, i| {
        if (!slot.active) {
            const sound = engine.createSoundFromFile(path, .{}) catch {
                return AudioError.LoadFailed;
            };

            slot.sound = sound;
            slot.generation = self.sound_generation;
            slot.active = true;

            const id = SoundId{
                .index = @intCast(i),
                .generation = self.sound_generation,
            };

            self.sound_generation +%= 1;
            if (self.sound_generation == 0) self.sound_generation = 1;

            return id;
        }
    }

    return AudioError.SlotsFull;
}

/// Unload a sound effect
pub fn unloadSound(self: *Self, sound_id: SoundId) void {
    if (self.getSoundSlot(sound_id)) |slot| {
        if (slot.sound) |sound| {
            sound.destroy();
        }
        slot.sound = null;
        slot.active = false;
    }
}

/// Play a sound effect
pub fn playSound(self: *Self, sound_id: SoundId) void {
    if (self.getSoundSlot(sound_id)) |slot| {
        if (slot.sound) |sound| {
            sound.start() catch {};
        }
    }
}

/// Stop a playing sound effect
pub fn stopSound(self: *Self, sound_id: SoundId) void {
    if (self.getSoundSlot(sound_id)) |slot| {
        if (slot.sound) |sound| {
            sound.stop() catch {};
        }
    }
}

/// Set volume for a sound effect (0.0 to 1.0)
pub fn setSoundVolume(self: *Self, sound_id: SoundId, volume: f32) void {
    if (self.getSoundSlot(sound_id)) |slot| {
        if (slot.sound) |sound| {
            sound.setVolume(volume);
        }
    }
}

/// Check if a sound effect is currently playing
pub fn isSoundPlaying(self: *const Self, sound_id: SoundId) bool {
    if (self.getSoundSlotConst(sound_id)) |slot| {
        if (slot.sound) |sound| {
            return sound.isPlaying();
        }
    }
    return false;
}

// ==================== Music ====================

/// Load a music stream from file
pub fn loadMusic(self: *Self, path: [:0]const u8) AudioError!MusicId {
    if (!self.initialized) return AudioError.AudioNotSupported;

    const engine = self.engine orelse return AudioError.AudioNotSupported;

    // Find an empty slot
    for (&self.music, 0..) |*slot, i| {
        if (!slot.active) {
            const sound = engine.createSoundFromFile(path, .{
                .flags = .{ .stream = true }, // Stream for music
            }) catch {
                return AudioError.LoadFailed;
            };

            slot.sound = sound;
            slot.generation = self.music_generation;
            slot.active = true;

            const id = MusicId{
                .index = @intCast(i),
                .generation = self.music_generation,
            };

            self.music_generation +%= 1;
            if (self.music_generation == 0) self.music_generation = 1;

            return id;
        }
    }

    return AudioError.SlotsFull;
}

/// Unload a music stream
pub fn unloadMusic(self: *Self, music_id: MusicId) void {
    if (self.getMusicSlot(music_id)) |slot| {
        if (slot.sound) |sound| {
            sound.destroy();
        }
        slot.sound = null;
        slot.active = false;
    }
}

/// Start playing music
pub fn playMusic(self: *Self, music_id: MusicId) void {
    if (self.getMusicSlot(music_id)) |slot| {
        if (slot.sound) |sound| {
            sound.start() catch {};
        }
    }
}

/// Stop playing music
pub fn stopMusic(self: *Self, music_id: MusicId) void {
    if (self.getMusicSlot(music_id)) |slot| {
        if (slot.sound) |sound| {
            sound.stop() catch {};
        }
    }
}

/// Pause music playback (saves position for resume)
pub fn pauseMusic(self: *Self, music_id: MusicId) void {
    if (self.getMusicSlot(music_id)) |slot| {
        if (slot.sound) |sound| {
            // Save cursor position before stopping
            slot.pause_frame = sound.getCursorInPcmFrames() catch 0;
            sound.stop() catch {};
        }
    }
}

/// Resume music playback (from paused position)
pub fn resumeMusic(self: *Self, music_id: MusicId) void {
    if (self.getMusicSlot(music_id)) |slot| {
        if (slot.sound) |sound| {
            // Seek to saved position and start
            sound.seekToPcmFrame(slot.pause_frame) catch {};
            sound.start() catch {};
        }
    }
}

/// Set volume for music (0.0 to 1.0)
pub fn setMusicVolume(self: *Self, music_id: MusicId, volume: f32) void {
    if (self.getMusicSlot(music_id)) |slot| {
        if (slot.sound) |sound| {
            sound.setVolume(volume);
        }
    }
}

/// Check if music is currently playing
pub fn isMusicPlaying(self: *const Self, music_id: MusicId) bool {
    if (self.getMusicSlotConst(music_id)) |slot| {
        if (slot.sound) |sound| {
            return sound.isPlaying();
        }
    }
    return false;
}

// ==================== Global ====================

/// Set master volume (0.0 to 1.0)
pub fn setMasterVolume(self: *Self, volume: f32) void {
    if (self.engine) |engine| {
        engine.setVolume(volume) catch {};
    }
}

/// Check if audio is available
pub fn isAvailable(self: *const Self) bool {
    return self.initialized and self.engine != null;
}

// ==================== Internal Helpers ====================

/// Get a mutable sound slot by ID, validating generation
fn getSoundSlot(self: *Self, sound_id: SoundId) ?*SoundSlot {
    if (sound_id.index >= MAX_SOUNDS) return null;
    const slot = &self.sounds[sound_id.index];
    if (!slot.active or slot.generation != sound_id.generation) return null;
    return slot;
}

/// Get a const sound slot by ID, validating generation
fn getSoundSlotConst(self: *const Self, sound_id: SoundId) ?*const SoundSlot {
    if (sound_id.index >= MAX_SOUNDS) return null;
    const slot = &self.sounds[sound_id.index];
    if (!slot.active or slot.generation != sound_id.generation) return null;
    return slot;
}

/// Get a mutable music slot by ID, validating generation
fn getMusicSlot(self: *Self, music_id: MusicId) ?*MusicSlot {
    if (music_id.index >= MAX_MUSIC) return null;
    const slot = &self.music[music_id.index];
    if (!slot.active or slot.generation != music_id.generation) return null;
    return slot;
}

/// Get a const music slot by ID, validating generation
fn getMusicSlotConst(self: *const Self, music_id: MusicId) ?*const MusicSlot {
    if (music_id.index >= MAX_MUSIC) return null;
    const slot = &self.music[music_id.index];
    if (!slot.active or slot.generation != music_id.generation) return null;
    return slot;
}
