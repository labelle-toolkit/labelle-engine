//! Public surface of the `audio_backend` sub-package.
//!
//! Lives inside `labelle-engine` (mirroring the `spatial_grid` / `tilemap` /
//! `camera` sub-packages inside `labelle-gfx`) so concrete audio backends
//! (raylib-audio, sokol-audio, miniaudio, …) can depend on a narrow
//! decoder-side contract without pulling the whole engine.
//!
//! Runtime playback (`AudioInterface`-style) lives in `labelle-core`; this
//! sub-package is decoder/loader-side only.
//!
//! See `labelle-engine#530` for the tracking issue.

pub const backend_mod = @import("backend.zig");
pub const mock_backend_mod = @import("mock_backend.zig");

pub const Backend = backend_mod.Backend;
pub const DecodedAudio = backend_mod.DecodedAudio;
pub const MockBackend = mock_backend_mod.MockBackend;
