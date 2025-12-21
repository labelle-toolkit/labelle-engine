//! Raylib Audio Backend
//!
//! Full audio implementation using raylib's audio system.
//! Supports both sound effects (loaded into memory) and music (streamed).

const rl = @import("raylib");
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
    sound: rl.Sound,
    generation: u16,
    active: bool,
};

/// Music slot with generation counter for handle validation
const MusicSlot = struct {
    music: rl.Music,
    generation: u16,
    active: bool,
    playing: bool,
};

/// Sound slots array
sounds: [MAX_SOUNDS]SoundSlot,
/// Music slots array
music: [MAX_MUSIC]MusicSlot,
/// Next generation counter for sounds
sound_generation: u16,
/// Next generation counter for music
music_generation: u16,

/// Initialize the audio system
pub fn init() Self {
    rl.initAudioDevice();

    var self = Self{
        .sounds = undefined,
        .music = undefined,
        .sound_generation = 1, // Start at 1 so 0 is always invalid
        .music_generation = 1,
    };

    // Initialize all slots as inactive
    for (&self.sounds) |*slot| {
        slot.* = .{
            .sound = undefined,
            .generation = 0,
            .active = false,
        };
    }
    for (&self.music) |*slot| {
        slot.* = .{
            .music = undefined,
            .generation = 0,
            .active = false,
            .playing = false,
        };
    }

    return self;
}

/// Clean up the audio system
pub fn deinit(self: *Self) void {
    // Unload all sounds
    for (&self.sounds) |*slot| {
        if (slot.active) {
            rl.unloadSound(slot.sound);
            slot.active = false;
        }
    }

    // Unload all music
    for (&self.music) |*slot| {
        if (slot.active) {
            rl.unloadMusicStream(slot.music);
            slot.active = false;
        }
    }

    rl.closeAudioDevice();
}

/// Update audio system (must be called each frame for music streaming)
pub fn update(self: *Self) void {
    // Update all playing music streams
    for (&self.music) |*slot| {
        if (slot.active and slot.playing) {
            rl.updateMusicStream(slot.music);
        }
    }
}

// ==================== Sound Effects ====================

/// Load a sound effect from file
pub fn loadSound(self: *Self, path: [:0]const u8) AudioError!SoundId {
    // Find an empty slot
    for (&self.sounds, 0..) |*slot, i| {
        if (!slot.active) {
            const sound = rl.loadSound(path);
            if (!rl.isSoundValid(sound)) {
                return AudioError.LoadFailed;
            }

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
pub fn unloadSound(self: *Self, sound: SoundId) void {
    if (self.getSoundSlot(sound)) |slot| {
        rl.unloadSound(slot.sound);
        slot.active = false;
    }
}

/// Play a sound effect
pub fn playSound(self: *Self, sound: SoundId) void {
    if (self.getSoundSlot(sound)) |slot| {
        rl.playSound(slot.sound);
    }
}

/// Stop a playing sound effect
pub fn stopSound(self: *Self, sound: SoundId) void {
    if (self.getSoundSlot(sound)) |slot| {
        rl.stopSound(slot.sound);
    }
}

/// Set volume for a sound effect (0.0 to 1.0)
pub fn setSoundVolume(self: *Self, sound: SoundId, volume: f32) void {
    if (self.getSoundSlot(sound)) |slot| {
        rl.setSoundVolume(slot.sound, volume);
    }
}

/// Check if a sound effect is currently playing
pub fn isSoundPlaying(self: *const Self, sound: SoundId) bool {
    if (self.getSoundSlotConst(sound)) |slot| {
        return rl.isSoundPlaying(slot.sound);
    }
    return false;
}

// ==================== Music ====================

/// Load a music stream from file
pub fn loadMusic(self: *Self, path: [:0]const u8) AudioError!MusicId {
    // Find an empty slot
    for (&self.music, 0..) |*slot, i| {
        if (!slot.active) {
            const music = rl.loadMusicStream(path);
            if (!rl.isMusicValid(music)) {
                return AudioError.LoadFailed;
            }

            slot.music = music;
            slot.generation = self.music_generation;
            slot.active = true;
            slot.playing = false;

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
pub fn unloadMusic(self: *Self, music: MusicId) void {
    if (self.getMusicSlot(music)) |slot| {
        rl.unloadMusicStream(slot.music);
        slot.active = false;
        slot.playing = false;
    }
}

/// Start playing music
pub fn playMusic(self: *Self, music: MusicId) void {
    if (self.getMusicSlot(music)) |slot| {
        rl.playMusicStream(slot.music);
        slot.playing = true;
    }
}

/// Stop playing music
pub fn stopMusic(self: *Self, music: MusicId) void {
    if (self.getMusicSlot(music)) |slot| {
        rl.stopMusicStream(slot.music);
        slot.playing = false;
    }
}

/// Pause music playback
pub fn pauseMusic(self: *Self, music: MusicId) void {
    if (self.getMusicSlot(music)) |slot| {
        rl.pauseMusicStream(slot.music);
        slot.playing = false;
    }
}

/// Resume music playback
pub fn resumeMusic(self: *Self, music: MusicId) void {
    if (self.getMusicSlot(music)) |slot| {
        rl.resumeMusicStream(slot.music);
        slot.playing = true;
    }
}

/// Set volume for music (0.0 to 1.0)
pub fn setMusicVolume(self: *Self, music: MusicId, volume: f32) void {
    if (self.getMusicSlot(music)) |slot| {
        rl.setMusicVolume(slot.music, volume);
    }
}

/// Check if music is currently playing
pub fn isMusicPlaying(self: *const Self, music: MusicId) bool {
    if (self.getMusicSlotConst(music)) |slot| {
        return rl.isMusicStreamPlaying(slot.music);
    }
    return false;
}

// ==================== Global ====================

/// Set master volume (0.0 to 1.0)
pub fn setMasterVolume(self: *Self, volume: f32) void {
    _ = self;
    rl.setMasterVolume(volume);
}

/// Check if audio is available (always true for raylib)
pub fn isAvailable(self: *const Self) bool {
    _ = self;
    return rl.isAudioDeviceReady();
}

// ==================== Internal Helpers ====================

/// Get a mutable sound slot by ID, validating generation
fn getSoundSlot(self: *Self, sound: SoundId) ?*SoundSlot {
    if (sound.index >= MAX_SOUNDS) return null;
    const slot = &self.sounds[sound.index];
    if (!slot.active or slot.generation != sound.generation) return null;
    return slot;
}

/// Get a const sound slot by ID, validating generation
fn getSoundSlotConst(self: *const Self, sound: SoundId) ?*const SoundSlot {
    if (sound.index >= MAX_SOUNDS) return null;
    const slot = &self.sounds[sound.index];
    if (!slot.active or slot.generation != sound.generation) return null;
    return slot;
}

/// Get a mutable music slot by ID, validating generation
fn getMusicSlot(self: *Self, music: MusicId) ?*MusicSlot {
    if (music.index >= MAX_MUSIC) return null;
    const slot = &self.music[music.index];
    if (!slot.active or slot.generation != music.generation) return null;
    return slot;
}

/// Get a const music slot by ID, validating generation
fn getMusicSlotConst(self: *const Self, music: MusicId) ?*const MusicSlot {
    if (music.index >= MAX_MUSIC) return null;
    const slot = &self.music[music.index];
    if (!slot.active or slot.generation != music.generation) return null;
    return slot;
}
