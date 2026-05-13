//! Font Types
//!
//! Shared types for the font system, used across all backends and the
//! asset catalog. Backend-agnostic — actual atlas baking and glyph
//! rasterising is delegated to a `FontBackend` hook injected by the
//! assembler at `Game.init`, mirroring `AudioBackend` and `ImageBackend`.

/// Opaque handle for a loaded font (baked glyph atlas + metrics).
/// Same shape as `audio_types.SoundId` — generation-tagged so the
/// runtime can detect use-after-free against a stale handle.
pub const FontId = struct {
    index: u16,
    generation: u16,

    pub const invalid: FontId = .{ .index = 0, .generation = 0 };

    pub fn isValid(self: FontId) bool {
        return self.generation != 0;
    }
};

/// One baked glyph. UV rect is in *pixels* of the atlas (not
/// normalised) so the renderer can divide by atlas size once at
/// upload time. `xoff` / `yoff` are pen-relative blit offsets that
/// already incorporate the glyph's bearing — the renderer just adds
/// them to the pen position. `advance` moves the pen for the next
/// glyph. See `RFC-FONT-LOADER.md` §3.
///
/// `extern struct` so the assembler-generated `FontBackendAdapter` can
/// `@ptrCast` slices between `[]BackendGfx.Glyph` and `[]engine.Glyph`
/// (and the equivalent sokol-side types) — the three repos define
/// structurally-identical-but-nominally-distinct `Glyph` types and
/// rely on a zero-cost reinterpret at the codegen marshal boundary.
/// Without `extern` the layout is unspecified and the reinterpret is
/// UB. Layout-compatible across all three definitions: u16×4 then f32×3.
pub const Glyph = extern struct {
    u0: u16,
    v0: u16,
    u1: u16,
    v1: u16,

    xoff: f32,
    yoff: f32,
    advance: f32,
};

/// Sorted (by `codepoint`) lookup from Unicode codepoint to dense
/// index in the `glyphs` array. Renderers binary-search this per
/// glyph. Built from `FontBakeParams.ranges` at bake time. `extern`
/// for the same reason as `Glyph`.
pub const CodepointEntry = extern struct {
    codepoint: u32,
    glyph_index: u32,
};

/// One GPOS kern pair. `advance` is added to the pen advance when
/// `first` is followed by `second`. Empty slice when kerning is
/// disabled or the font has no GPOS kern table. `extern` for the
/// same reason as `Glyph`.
pub const KernPair = extern struct {
    first: u32,
    second: u32,
    advance: f32,
};
