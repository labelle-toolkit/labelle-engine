# audio_backend

Decoder-side audio backend traits for the labelle-toolkit. Sub-package
of `labelle-engine`, mirroring the `spatial_grid` / `tilemap` / `camera`
sub-packages inside `labelle-gfx`.

Defines a comptime-validated `Backend(Impl)` wrapper and a `DecodedAudio`
POD that concrete decoder backends (raylib-audio, sokol-audio,
miniaudio, …) implement; `labelle-assembler` adapts the result to
`labelle-engine`'s `AudioBackend` struct (`src/assets/loaders/audio.zig`)
at codegen time.

This is the audio sibling of [labelle-gfx][gfx]'s image and font backend
traits (see [labelle-gfx#258][gfx258]). Runtime playback
(`AudioInterface`-style) lives in `labelle-core` and is intentionally
not part of this sub-package.

Concrete backends consume this via path dep on `labelle-engine`:

```zig
// in a concrete backend's build.zig.zon
.dependencies = .{
    .labelle_engine = .{ .path = "../labelle-engine" },
},
```

```zig
// in build.zig
const engine_dep = b.dependency("labelle_engine", ...);
const audio_backend = engine_dep.module("audio_backend");
```

Tracking issue: [labelle-engine#530][issue530].

[gfx]: https://github.com/labelle-toolkit/labelle-gfx
[gfx258]: https://github.com/labelle-toolkit/labelle-gfx/pull/258
[issue530]: https://github.com/labelle-toolkit/labelle-engine/issues/530
