//! Font Types
//!
//! Shared types for the font system, used across all backends and the
//! asset catalog. Backend-agnostic — actual atlas baking and glyph
//! rasterising is delegated to a `FontBackend` hook injected by the
//! assembler at `Game.init`, mirroring `AudioBackend` and `ImageBackend`.

const core = @import("labelle-core");

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

// `Glyph` / `CodepointEntry` / `KernPair` are now owned by **labelle-core**
// (labelle-assembler#647, RFC §Q#2) and aliased here. They were `extern struct`s
// duplicated across core/gfx/engine purely so the assembler-generated
// `FontBackendAdapter` could `@ptrCast` slices between the nominally-distinct
// copies. With one canonical type shared by all three repos the reinterpret
// collapses to identity; the `extern` layout guarantee lives at the core
// definition (`labelle-core/src/backend_contract.zig`). The field shape is
// unchanged: u16×4 then f32×3 for `Glyph`. See `RFC-FONT-LOADER.md` §3.

/// One baked glyph. UV rect in atlas *pixels*; `xoff`/`yoff` are
/// pen-relative blit offsets; `advance` moves the pen for the next glyph.
pub const Glyph = core.Glyph;

/// Sorted (by `codepoint`) lookup from Unicode codepoint to dense glyph
/// index; renderers binary-search this per glyph.
pub const CodepointEntry = core.CodepointEntry;

/// One GPOS kern pair — `advance` added when `first` is followed by `second`.
pub const KernPair = core.KernPair;
