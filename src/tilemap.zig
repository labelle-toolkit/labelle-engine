//! Tilemap component (T2 Phase 2, labelle-engine tilemap epic).
//!
//! A `Tilemap` entity references an embedded `.tmx` asset by name. The
//! component itself is a tiny POD holding only that reference — the
//! decoded map + its per-entity draw-pass renderer live engine-side in a
//! side table on `Game` (see `game/tilemap_mixin.zig`), keyed by entity.
//!
//! **Immutable at runtime (T2).** A tilemap is fully deterministic from
//! its `.tmx` asset: there are no runtime tile mutations and no dirty
//! tracking. Consequently the save/load contract persists ONLY
//! `asset_name` (via the engine's built-in save channel, alongside
//! `Position`/`PrefabInstance` — see `game/save_load/`), and load
//! rehydrates the decoded map by re-decoding the asset. The decoded map
//! is never serialized.
//!
//! **Engine built-in, NOT a `ComponentRegistry` component.** Like
//! `Position` and `PrefabInstance`, `Tilemap` is handled by dedicated
//! built-in channels in the scene loader, save/load, and digest — its
//! `asset_name` is a `[]const u8`, which the registry-driven `serde`
//! path cannot round-trip. Do not register it in a game's
//! `ComponentRegistry`.

/// An explicit `.tmx`-layer → engine-layer binding (T3 Z-interleave).
/// Overrides the implicit-by-name rule for a single `.tmx` layer: the
/// layer named `tmx_layer` renders at the z of the engine layer named
/// `engine_layer` (matched against the renderer's `LayerEnum` `@tagName`),
/// interleaved with the sprite layers, instead of in the pre-sprite
/// background pass. Authored in scene JSONC; the assembler emits `null`
/// bindings for back-compat.
pub const LayerBinding = struct {
    /// Name of the `.tmx` `<layer>` (Tiled layer name).
    tmx_layer: []const u8 = "",
    /// Name of the engine layer (`@tagName` of the renderer's `LayerEnum`)
    /// this `.tmx` layer binds to. Must be a WORLD-space layer — a binding
    /// to a screen-space (or unknown) engine layer is ignored and the
    /// `.tmx` layer falls back to the background pass.
    engine_layer: []const u8 = "",
};

/// The `Tilemap` component. Reachable on a configured game as
/// `Game.TilemapComp`.
pub const Tilemap = struct {
    /// Name of the embedded `.tmx` asset this entity renders. Resolved
    /// through `Game.addEmbeddedTilemapAsset` (the `.tmx` bytes) + the
    /// same registry for each tileset's image bytes. The ONLY field that
    /// persists across save/load — the decoded map is rebuilt from it.
    asset_name: []const u8 = "",

    /// Optional explicit `.tmx`-layer → engine-layer bindings (T3
    /// Z-interleave). `null` (the default the assembler emits) means
    /// "implicit-by-name only": a `.tmx` layer named X binds to the engine
    /// layer named X if one exists, otherwise it renders in the pre-sprite
    /// background pass (exactly T2). A non-null list overrides that mapping
    /// per named `.tmx` layer. Scene-authored: like the decoded map itself,
    /// bindings are NOT carried through save/load snapshots (only
    /// `asset_name` persists); they are re-applied when the scene reloads.
    layer_bindings: ?[]const LayerBinding = null,
};
