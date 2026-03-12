/// Audio module — re-exports from labelle-core interface + engine-owned types.
const core = @import("labelle-core");
pub const AudioInterface = core.AudioInterface;
pub const StubAudio = core.StubAudio;

// Engine-owned audio types (backend-agnostic)
pub const audio_types = @import("audio_types.zig");
pub const SoundId = audio_types.SoundId;
pub const MusicId = audio_types.MusicId;
pub const AudioError = audio_types.AudioError;
