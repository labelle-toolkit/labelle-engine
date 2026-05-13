const std = @import("std");
const backend_mod = @import("backend.zig");

/// Mock backend for testing — produces stub decoded audio + stub sound
/// handles without any native dependencies. Mirrors `labelle-gfx`'s
/// `MockBackend` shape for images and fonts.
pub const MockBackend = struct {
    pub const DecodedAudio = backend_mod.DecodedAudio;

    /// Mock sound handle — generation-tagged to detect use-after-free
    /// under test, parallel to `labelle-gfx`'s `Texture.id` / `FontAtlas.id`.
    pub const Sound = struct {
        id: u32,
        sample_rate: u32,
        channels: u8,
    };

    threadlocal var allocator_ref: ?std.mem.Allocator = null;
    threadlocal var sound_counter: u32 = 1;
    threadlocal var sound_unload_calls: u32 = 0;

    pub fn initMock(allocator: std.mem.Allocator) void {
        allocator_ref = allocator;
        sound_counter = 1;
        sound_unload_calls = 0;
    }

    pub fn deinitMock() void {
        allocator_ref = null;
    }

    pub fn resetMock() void {
        sound_counter = 1;
        sound_unload_calls = 0;
    }

    pub fn getSoundUnloadCalls() u32 {
        return sound_unload_calls;
    }

    // Backend interface implementation.

    /// Stub CPU decode: returns a 4-sample mono PCM buffer allocated from
    /// the caller's allocator. Worker-thread safe (no shared mutable state
    /// is touched). The caller owns `samples` and must free it through the
    /// same allocator on both the success and the discard paths.
    pub fn decodeAudio(
        _: [:0]const u8,
        _: []const u8,
        allocator: std.mem.Allocator,
    ) !backend_mod.DecodedAudio {
        const samples = try allocator.alloc(i16, 4);
        samples[0] = 0;
        samples[1] = 1;
        samples[2] = 2;
        samples[3] = 3;
        return .{
            .samples = samples,
            .sample_rate = 44_100,
            .channels = 1,
        };
    }

    /// Stub upload: returns a fresh mock `Sound` and records nothing about
    /// the sample buffer (the caller still owns it).
    pub fn uploadSound(decoded: backend_mod.DecodedAudio) !Sound {
        const id = sound_counter;
        sound_counter += 1;
        return Sound{
            .id = id,
            .sample_rate = decoded.sample_rate,
            .channels = decoded.channels,
        };
    }

    pub fn unloadSound(_: Sound) void {
        sound_unload_calls += 1;
    }
};
