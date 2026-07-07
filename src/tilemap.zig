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

/// The `Tilemap` component. Reachable on a configured game as
/// `Game.TilemapComp`.
pub const Tilemap = struct {
    /// Name of the embedded `.tmx` asset this entity renders. Resolved
    /// through `Game.addEmbeddedTilemapAsset` (the `.tmx` bytes) + the
    /// same registry for each tileset's image bytes. The ONLY field that
    /// persists across save/load — the decoded map is rebuilt from it.
    asset_name: []const u8 = "",
};
