//! Sokol Audio Backend
//!
//! Audio implementation using sokol_audio.
//! Designed for platforms where zaudio/miniaudio is not available (iOS).
//! Uses sokol_audio's callback model with a simple mixer for playing multiple sounds.

const std = @import("std");
const sokol = @import("sokol");
const saudio = sokol.audio;
const types = @import("types.zig");

pub const SoundId = types.SoundId;
pub const MusicId = types.MusicId;
pub const AudioError = types.AudioError;

const Self = @This();

// Maximum number of sounds and music tracks
const MAX_SOUNDS = 64;
const MAX_MUSIC = 8;
const MAX_PLAYING = 32; // Maximum simultaneously playing sounds/music

// Audio configuration
const SAMPLE_RATE = 44100;
const NUM_CHANNELS = 2;

/// Decoded audio data stored in memory
const AudioData = struct {
    samples: []f32, // Interleaved stereo samples
    sample_rate: u32,
    num_channels: u16,
};

/// Sound slot with generation counter for handle validation
const SoundSlot = struct {
    data: ?AudioData,
    generation: u16,
    active: bool,
    volume: f32,
};

/// Music slot with generation counter for handle validation
const MusicSlot = struct {
    data: ?AudioData,
    generation: u16,
    active: bool,
    volume: f32,
};

/// Playing instance tracking
const PlayingInstance = struct {
    is_sound: bool, // true = sound, false = music
    slot_index: u16,
    generation: u16,
    position: usize, // Current sample frame position
    playing: bool,
    looping: bool,
    paused: bool,
    volume: f32,
};

/// Allocator for audio data
allocator: std.mem.Allocator,
/// Sound slots array
sounds: [MAX_SOUNDS]SoundSlot,
/// Music slots array
music: [MAX_MUSIC]MusicSlot,
/// Currently playing instances
playing: [MAX_PLAYING]PlayingInstance,
/// Next generation counter for sounds
sound_generation: u16,
/// Next generation counter for music
music_generation: u16,
/// Master volume
master_volume: f32,
/// Whether audio was successfully initialized
initialized: bool,

// Global instance pointer for the audio callback
var g_instance: ?*Self = null;

/// Initialize the audio system
pub fn init() Self {
    // Use c_allocator for WASM (emscripten), page_allocator for native
    const allocator = if (@import("builtin").os.tag == .emscripten)
        std.heap.c_allocator
    else
        std.heap.page_allocator;

    var self = Self{
        .allocator = allocator,
        .sounds = undefined,
        .music = undefined,
        .playing = undefined,
        .sound_generation = 1,
        .music_generation = 1,
        .master_volume = 1.0,
        .initialized = false,
    };

    // Initialize all slots as inactive
    for (&self.sounds) |*slot| {
        slot.* = SoundSlot{
            .data = null,
            .generation = 0,
            .active = false,
            .volume = 1.0,
        };
    }

    for (&self.music) |*slot| {
        slot.* = MusicSlot{
            .data = null,
            .generation = 0,
            .active = false,
            .volume = 1.0,
        };
    }

    for (&self.playing) |*inst| {
        inst.* = PlayingInstance{
            .is_sound = true,
            .slot_index = 0,
            .generation = 0,
            .position = 0,
            .playing = false,
            .looping = false,
            .paused = false,
            .volume = 1.0,
        };
    }

    // Store global instance pointer for callback
    g_instance = &self;

    // Initialize sokol audio
    saudio.setup(.{
        .sample_rate = SAMPLE_RATE,
        .num_channels = NUM_CHANNELS,
        .stream_cb = audioCallback,
        .logger = .{ .func = sokolLog },
    });

    if (saudio.isvalid()) {
        self.initialized = true;
    }

    return self;
}

/// Clean up the audio system
pub fn deinit(self: *Self) void {
    // Shutdown sokol audio first
    saudio.shutdown();

    // Free all sound data
    for (&self.sounds) |*slot| {
        if (slot.active) {
            if (slot.data) |data| {
                self.allocator.free(data.samples);
            }
            slot.data = null;
            slot.active = false;
        }
    }

    // Free all music data
    for (&self.music) |*slot| {
        if (slot.active) {
            if (slot.data) |data| {
                self.allocator.free(data.samples);
            }
            slot.data = null;
            slot.active = false;
        }
    }

    g_instance = null;
    self.initialized = false;
}

/// Update audio system (no-op for sokol audio, callback handles streaming)
pub fn update(self: *Self) void {
    _ = self;
    // sokol_audio handles streaming via callback
}

// ==================== Sound Effects ====================

/// Load a sound effect from file
pub fn loadSound(self: *Self, path: [:0]const u8) AudioError!SoundId {
    if (!self.initialized) return AudioError.AudioNotSupported;

    // Find an empty slot
    for (&self.sounds, 0..) |*slot, i| {
        if (!slot.active) {
            const data = loadWavFile(self.allocator, path) catch {
                return AudioError.LoadFailed;
            };

            slot.data = data;
            slot.generation = self.sound_generation;
            slot.active = true;
            slot.volume = 1.0;

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
        // Stop any playing instances
        for (&self.playing) |*inst| {
            if (inst.playing and inst.is_sound and inst.slot_index == sound_id.index and inst.generation == sound_id.generation) {
                inst.playing = false;
            }
        }

        if (slot.data) |data| {
            self.allocator.free(data.samples);
        }
        slot.data = null;
        slot.active = false;
    }
}

/// Play a sound effect
pub fn playSound(self: *Self, sound_id: SoundId) void {
    if (self.getSoundSlot(sound_id)) |slot| {
        _ = slot;
        // Find an empty playing slot
        for (&self.playing) |*inst| {
            if (!inst.playing) {
                inst.is_sound = true;
                inst.slot_index = sound_id.index;
                inst.generation = sound_id.generation;
                inst.position = 0;
                inst.playing = true;
                inst.looping = false;
                inst.paused = false;
                inst.volume = 1.0;
                return;
            }
        }
        // No empty slot, sound won't play
    }
}

/// Stop a playing sound effect
pub fn stopSound(self: *Self, sound_id: SoundId) void {
    for (&self.playing) |*inst| {
        if (inst.playing and inst.is_sound and inst.slot_index == sound_id.index and inst.generation == sound_id.generation) {
            inst.playing = false;
        }
    }
}

/// Set volume for a sound effect (0.0 to 1.0)
pub fn setSoundVolume(self: *Self, sound_id: SoundId, volume: f32) void {
    if (self.getSoundSlot(sound_id)) |slot| {
        slot.volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

/// Check if a sound effect is currently playing
pub fn isSoundPlaying(self: *const Self, sound_id: SoundId) bool {
    for (self.playing) |inst| {
        if (inst.playing and inst.is_sound and inst.slot_index == sound_id.index and inst.generation == sound_id.generation) {
            return true;
        }
    }
    return false;
}

// ==================== Music ====================

/// Load a music stream from file
pub fn loadMusic(self: *Self, path: [:0]const u8) AudioError!MusicId {
    if (!self.initialized) return AudioError.AudioNotSupported;

    // Find an empty slot
    for (&self.music, 0..) |*slot, i| {
        if (!slot.active) {
            const data = loadWavFile(self.allocator, path) catch {
                return AudioError.LoadFailed;
            };

            slot.data = data;
            slot.generation = self.music_generation;
            slot.active = true;
            slot.volume = 1.0;

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
        // Stop any playing instances
        for (&self.playing) |*inst| {
            if (inst.playing and !inst.is_sound and inst.slot_index == music_id.index and inst.generation == music_id.generation) {
                inst.playing = false;
            }
        }

        if (slot.data) |data| {
            self.allocator.free(data.samples);
        }
        slot.data = null;
        slot.active = false;
    }
}

/// Start playing music (loops by default)
pub fn playMusic(self: *Self, music_id: MusicId) void {
    if (self.getMusicSlot(music_id)) |slot| {
        _ = slot;
        // Find an empty playing slot
        for (&self.playing) |*inst| {
            if (!inst.playing) {
                inst.is_sound = false;
                inst.slot_index = music_id.index;
                inst.generation = music_id.generation;
                inst.position = 0;
                inst.playing = true;
                inst.looping = true; // Music loops by default
                inst.paused = false;
                inst.volume = 1.0;
                return;
            }
        }
    }
}

/// Stop playing music
pub fn stopMusic(self: *Self, music_id: MusicId) void {
    for (&self.playing) |*inst| {
        if (inst.playing and !inst.is_sound and inst.slot_index == music_id.index and inst.generation == music_id.generation) {
            inst.playing = false;
        }
    }
}

/// Pause music playback
pub fn pauseMusic(self: *Self, music_id: MusicId) void {
    for (&self.playing) |*inst| {
        if (inst.playing and !inst.is_sound and inst.slot_index == music_id.index and inst.generation == music_id.generation) {
            inst.paused = true;
        }
    }
}

/// Resume music playback
pub fn resumeMusic(self: *Self, music_id: MusicId) void {
    for (&self.playing) |*inst| {
        if (inst.playing and !inst.is_sound and inst.slot_index == music_id.index and inst.generation == music_id.generation) {
            inst.paused = false;
        }
    }
}

/// Set volume for music (0.0 to 1.0)
pub fn setMusicVolume(self: *Self, music_id: MusicId, volume: f32) void {
    if (self.getMusicSlot(music_id)) |slot| {
        slot.volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

/// Check if music is currently playing
pub fn isMusicPlaying(self: *const Self, music_id: MusicId) bool {
    for (self.playing) |inst| {
        if (inst.playing and !inst.paused and !inst.is_sound and inst.slot_index == music_id.index and inst.generation == music_id.generation) {
            return true;
        }
    }
    return false;
}

// ==================== Global ====================

/// Set master volume (0.0 to 1.0)
pub fn setMasterVolume(self: *Self, volume: f32) void {
    self.master_volume = std.math.clamp(volume, 0.0, 1.0);
}

/// Check if audio is available
pub fn isAvailable(self: *const Self) bool {
    return self.initialized;
}

// ==================== Internal Helpers ====================

/// Get a mutable sound slot by ID, validating generation
fn getSoundSlot(self: *Self, sound_id: SoundId) ?*SoundSlot {
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

/// Sokol audio callback - mixes and outputs audio
fn audioCallback(buffer: [*c]f32, num_frames: c_int, num_channels: c_int) callconv(.c) void {
    const self = g_instance orelse return;
    const frames: usize = @intCast(num_frames);
    const channels: usize = @intCast(num_channels);
    const total_samples = frames * channels;

    // Clear buffer
    for (0..total_samples) |i| {
        buffer[i] = 0;
    }

    // Mix all playing instances
    for (&self.playing) |*inst| {
        if (!inst.playing or inst.paused) continue;

        // Get audio data based on type
        const audio_data_opt: ?AudioData = if (inst.is_sound) blk: {
            if (inst.slot_index < MAX_SOUNDS) {
                const slot = &self.sounds[inst.slot_index];
                if (slot.active and slot.generation == inst.generation) {
                    break :blk slot.data;
                }
            }
            break :blk null;
        } else blk: {
            if (inst.slot_index < MAX_MUSIC) {
                const slot = &self.music[inst.slot_index];
                if (slot.active and slot.generation == inst.generation) {
                    break :blk slot.data;
                }
            }
            break :blk null;
        };

        const audio_data = audio_data_opt orelse {
            inst.playing = false;
            continue;
        };

        // Get volume from slot
        const slot_volume: f32 = if (inst.is_sound) blk: {
            if (inst.slot_index < MAX_SOUNDS) {
                break :blk self.sounds[inst.slot_index].volume;
            }
            break :blk 1.0;
        } else blk: {
            if (inst.slot_index < MAX_MUSIC) {
                break :blk self.music[inst.slot_index].volume;
            }
            break :blk 1.0;
        };

        const volume = inst.volume * slot_volume * self.master_volume;
        const src_channels = audio_data.num_channels;
        const samples_per_frame = src_channels;
        const total_src_frames = audio_data.samples.len / samples_per_frame;

        var frame: usize = 0;
        while (frame < frames) : (frame += 1) {
            var src_frame = inst.position;

            // Check if we've reached the end
            if (src_frame >= total_src_frames) {
                if (inst.looping) {
                    inst.position = 0;
                    src_frame = 0;
                } else {
                    inst.playing = false;
                    break;
                }
            }

            // Get source samples
            const src_idx = src_frame * samples_per_frame;
            var left: f32 = 0;
            var right: f32 = 0;

            if (src_channels == 1) {
                // Mono to stereo
                left = audio_data.samples[src_idx] * volume;
                right = left;
            } else {
                // Stereo
                left = audio_data.samples[src_idx] * volume;
                right = audio_data.samples[src_idx + 1] * volume;
            }

            // Mix into output buffer
            const dst_idx = frame * channels;
            if (channels >= 1) buffer[dst_idx] += left;
            if (channels >= 2) buffer[dst_idx + 1] += right;

            inst.position += 1;
        }
    }

    // Clamp output to prevent clipping
    for (0..total_samples) |i| {
        buffer[i] = std.math.clamp(buffer[i], -1.0, 1.0);
    }
}

/// Sokol logging callback
fn sokolLog(
    tag: [*c]const u8,
    log_level: u32,
    log_item: u32,
    message: [*c]const u8,
    line: u32,
    filename: [*c]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = user_data;
    _ = tag;
    _ = log_item;
    _ = line;
    _ = filename;
    const msg = if (message != null) std.mem.span(message) else "";

    switch (log_level) {
        0 => {}, // panic - ignore
        1 => std.log.err("sokol audio: {s}", .{msg}),
        2 => std.log.warn("sokol audio: {s}", .{msg}),
        else => std.log.info("sokol audio: {s}", .{msg}),
    }
}

// ==================== WAV File Decoder ====================

/// WAV file header structure
const WavHeader = packed struct {
    riff: [4]u8, // "RIFF"
    file_size: u32, // File size minus 8 bytes
    wave: [4]u8, // "WAVE"
};

/// WAV format chunk
const WavFmtChunk = packed struct {
    fmt: [4]u8, // "fmt "
    chunk_size: u32,
    audio_format: u16, // 1 = PCM, 3 = IEEE float
    num_channels: u16,
    sample_rate: u32,
    byte_rate: u32,
    block_align: u16,
    bits_per_sample: u16,
};

/// Load a WAV file and convert to f32 samples
fn loadWavFile(allocator: std.mem.Allocator, path: [:0]const u8) !AudioData {
    const file = std.fs.cwd().openFileZ(path, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close();

    const reader = file.reader();

    // Read and validate RIFF header
    var header: WavHeader = undefined;
    _ = try reader.readAll(std.mem.asBytes(&header));

    if (!std.mem.eql(u8, &header.riff, "RIFF") or !std.mem.eql(u8, &header.wave, "WAVE")) {
        return error.InvalidFormat;
    }

    // Find and read fmt chunk
    var fmt: WavFmtChunk = undefined;
    var found_fmt = false;
    var data_size: u32 = 0;
    var data_pos: u64 = 0;

    while (true) {
        var chunk_id: [4]u8 = undefined;
        _ = reader.readAll(&chunk_id) catch break;

        var chunk_size_bytes: [4]u8 = undefined;
        _ = reader.readAll(&chunk_size_bytes) catch break;
        const chunk_size = std.mem.readInt(u32, &chunk_size_bytes, .little);

        if (std.mem.eql(u8, &chunk_id, "fmt ")) {
            // Read format chunk (minus the id and size we already read)
            var fmt_bytes: [@sizeOf(WavFmtChunk) - 8]u8 = undefined;
            const to_read = @min(fmt_bytes.len, chunk_size);
            _ = try reader.readAll(fmt_bytes[0..to_read]);

            // Skip extra bytes if chunk is larger
            if (chunk_size > to_read) {
                try file.seekBy(@intCast(chunk_size - to_read));
            }

            // Reconstruct fmt chunk
            fmt.fmt = chunk_id;
            fmt.chunk_size = chunk_size;
            fmt.audio_format = std.mem.readInt(u16, fmt_bytes[0..2], .little);
            fmt.num_channels = std.mem.readInt(u16, fmt_bytes[2..4], .little);
            fmt.sample_rate = std.mem.readInt(u32, fmt_bytes[4..8], .little);
            fmt.byte_rate = std.mem.readInt(u32, fmt_bytes[8..12], .little);
            fmt.block_align = std.mem.readInt(u16, fmt_bytes[12..14], .little);
            fmt.bits_per_sample = std.mem.readInt(u16, fmt_bytes[14..16], .little);

            found_fmt = true;
        } else if (std.mem.eql(u8, &chunk_id, "data")) {
            data_size = chunk_size;
            data_pos = try file.getPos();
            break;
        } else {
            // Skip unknown chunk
            try file.seekBy(@intCast(chunk_size));
        }
    }

    if (!found_fmt or data_size == 0) {
        return error.InvalidFormat;
    }

    // Only support PCM formats (1 = integer PCM, 3 = IEEE float)
    if (fmt.audio_format != 1 and fmt.audio_format != 3) {
        return error.UnsupportedFormat;
    }

    // Seek to data position
    try file.seekTo(data_pos);

    // Calculate number of samples
    const bytes_per_sample = fmt.bits_per_sample / 8;
    const num_samples = data_size / bytes_per_sample;

    // Allocate output buffer (always f32 stereo for output)
    const output_samples = try allocator.alloc(f32, num_samples);
    errdefer allocator.free(output_samples);

    // Read and convert samples based on format
    if (fmt.audio_format == 3) {
        // IEEE float (32-bit)
        if (fmt.bits_per_sample == 32) {
            const raw_bytes = try allocator.alloc(u8, data_size);
            defer allocator.free(raw_bytes);
            _ = try reader.readAll(raw_bytes);

            for (0..num_samples) |i| {
                const bytes: *const [4]u8 = @ptrCast(raw_bytes[i * 4 ..][0..4]);
                output_samples[i] = @bitCast(std.mem.readInt(u32, bytes, .little));
            }
        } else {
            return error.UnsupportedFormat;
        }
    } else {
        // Integer PCM
        if (fmt.bits_per_sample == 16) {
            const raw_bytes = try allocator.alloc(u8, data_size);
            defer allocator.free(raw_bytes);
            _ = try reader.readAll(raw_bytes);

            for (0..num_samples) |i| {
                const bytes: *const [2]u8 = @ptrCast(raw_bytes[i * 2 ..][0..2]);
                const sample_i16: i16 = @bitCast(std.mem.readInt(u16, bytes, .little));
                output_samples[i] = @as(f32, @floatFromInt(sample_i16)) / 32768.0;
            }
        } else if (fmt.bits_per_sample == 8) {
            const raw_bytes = try allocator.alloc(u8, data_size);
            defer allocator.free(raw_bytes);
            _ = try reader.readAll(raw_bytes);

            for (0..num_samples) |i| {
                // 8-bit WAV is unsigned (0-255), convert to signed float
                const sample_u8 = raw_bytes[i];
                output_samples[i] = (@as(f32, @floatFromInt(sample_u8)) - 128.0) / 128.0;
            }
        } else if (fmt.bits_per_sample == 24) {
            const raw_bytes = try allocator.alloc(u8, data_size);
            defer allocator.free(raw_bytes);
            _ = try reader.readAll(raw_bytes);

            for (0..num_samples) |i| {
                const b0 = raw_bytes[i * 3];
                const b1 = raw_bytes[i * 3 + 1];
                const b2 = raw_bytes[i * 3 + 2];
                // Convert 24-bit to 32-bit signed integer (sign extend)
                const sample_i32: i32 = (@as(i32, @as(i8, @bitCast(b2))) << 16) | (@as(i32, b1) << 8) | @as(i32, b0);
                output_samples[i] = @as(f32, @floatFromInt(sample_i32)) / 8388608.0;
            }
        } else if (fmt.bits_per_sample == 32) {
            const raw_bytes = try allocator.alloc(u8, data_size);
            defer allocator.free(raw_bytes);
            _ = try reader.readAll(raw_bytes);

            for (0..num_samples) |i| {
                const bytes: *const [4]u8 = @ptrCast(raw_bytes[i * 4 ..][0..4]);
                const sample_i32: i32 = @bitCast(std.mem.readInt(u32, bytes, .little));
                output_samples[i] = @as(f32, @floatFromInt(sample_i32)) / 2147483648.0;
            }
        } else {
            return error.UnsupportedFormat;
        }
    }

    return AudioData{
        .samples = output_samples,
        .sample_rate = fmt.sample_rate,
        .num_channels = fmt.num_channels,
    };
}
