const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const audio_mod = @import("audio");

test {
    zspec.runAll(@This());
}

pub const AUDIO_TYPES = struct {
    pub const SOUND_ID = struct {
        test "SoundId is exported from engine" {
            const T = engine.SoundId;
            try expect.toBeTrue(@typeName(T).len > 0);
        }

        test "SoundId has invalid constant" {
            try expect.toBeTrue(@hasDecl(engine.SoundId, "invalid"));
            try expect.equal(engine.SoundId.invalid.generation, 0);
        }

        test "SoundId has isValid method" {
            try expect.toBeTrue(@hasDecl(engine.SoundId, "isValid"));
            try expect.toBeFalse(engine.SoundId.invalid.isValid());
        }
    };

    pub const MUSIC_ID = struct {
        test "MusicId is exported from engine" {
            const T = engine.MusicId;
            try expect.toBeTrue(@typeName(T).len > 0);
        }

        test "MusicId has invalid constant" {
            try expect.toBeTrue(@hasDecl(engine.MusicId, "invalid"));
            try expect.equal(engine.MusicId.invalid.generation, 0);
        }

        test "MusicId has isValid method" {
            try expect.toBeTrue(@hasDecl(engine.MusicId, "isValid"));
            try expect.toBeFalse(engine.MusicId.invalid.isValid());
        }
    };

    pub const AUDIO_ERROR = struct {
        test "AudioError is exported from engine" {
            const T = engine.AudioError;
            try expect.toBeTrue(@typeName(T).len > 0);
        }

        test "AudioError has expected variants" {
            // Check that the error set contains expected errors
            const err_set = @typeInfo(engine.AudioError).error_set orelse unreachable;
            var has_not_supported = false;
            var has_load_failed = false;
            var has_slots_full = false;
            for (err_set) |err| {
                if (std.mem.eql(u8, err.name, "AudioNotSupported")) has_not_supported = true;
                if (std.mem.eql(u8, err.name, "LoadFailed")) has_load_failed = true;
                if (std.mem.eql(u8, err.name, "SlotsFull")) has_slots_full = true;
            }
            try expect.toBeTrue(has_not_supported);
            try expect.toBeTrue(has_load_failed);
            try expect.toBeTrue(has_slots_full);
        }
    };
};

pub const AUDIO_INTERFACE = struct {
    pub const TYPE_EXPORTS = struct {
        test "Audio type is exported from engine" {
            const T = engine.Audio;
            try expect.toBeTrue(@typeName(T).len > 0);
        }

        test "Audio has Implementation type" {
            try expect.toBeTrue(@hasDecl(engine.Audio, "Implementation"));
        }

        test "Audio has init method" {
            try expect.toBeTrue(@hasDecl(engine.Audio, "init"));
        }

        test "Audio has deinit method" {
            try expect.toBeTrue(@hasDecl(engine.Audio, "deinit"));
        }

        test "Audio has update method" {
            try expect.toBeTrue(@hasDecl(engine.Audio, "update"));
        }

        test "Audio has sound methods" {
            try expect.toBeTrue(@hasDecl(engine.Audio, "loadSound"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "unloadSound"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "playSound"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "stopSound"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "setSoundVolume"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "isSoundPlaying"));
        }

        test "Audio has music methods" {
            try expect.toBeTrue(@hasDecl(engine.Audio, "loadMusic"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "unloadMusic"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "playMusic"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "stopMusic"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "pauseMusic"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "resumeMusic"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "setMusicVolume"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "isMusicPlaying"));
        }

        test "Audio has global methods" {
            try expect.toBeTrue(@hasDecl(engine.Audio, "setMasterVolume"));
            try expect.toBeTrue(@hasDecl(engine.Audio, "isAvailable"));
        }
    };
};

pub const AUDIO_INTERFACE_VALIDATION = struct {
    test "AudioInterface function exists" {
        try expect.toBeTrue(@hasDecl(audio_mod, "AudioInterface"));
    }

    test "backend selection enum exists" {
        try expect.toBeTrue(@hasDecl(audio_mod, "Backend"));
        try expect.toBeTrue(@hasDecl(audio_mod, "backend"));
    }
};
