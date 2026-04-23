//! SpriteByField — declarative field-driven sprite selection.
//!
//! Complements `SpriteAnimation` (time-driven frame cycling) for the
//! other half of the prefab-animation RFC: cases where the sprite
//! follows the runtime value of a field on another component rather
//! than a frame timer. Canonical example: the hydroponics plant
//! overlay that swaps sprite based on `TendableWorkstation.level`
//! (0/1 → hidden, 2 → sapling_lvl1, 3 → sapling_lvl2, 4/5 → green).
//! Today that logic lives in a ~140-line tick script per use case
//! (`hydroponics_animation.zig`); this component collapses it to the
//! prefab data.
//!
//! See `labelle-engine/RFC-PREFAB-ANIMATION.md` for the full design.
//!
//! ## What this file ships
//!
//! Phase B slice of the animation RFC: the **pure state machine** —
//! component shape + `lookup(key)` method. The ECS tick system that
//! reads a field from a named component on each entity, coerces its
//! value to `i32`, looks up via `lookup`, and mutates the entity's
//! Sprite on match lands in a follow-up. Same staging as Phase A
//! (the sibling `SpriteAnimation` component) — that module introduces
//! `sprite_animation.zig` when its PR lands; the two components ship
//! together and cross-reference each other by intent.

const std = @import("std");
const save_policy = @import("labelle-core").save_policy;

/// Which entity carries the driving field.
///
/// - `.self` — read the field off this entity's own component of the
///   named type. Use when the sprite-bearing entity also holds the
///   state (rare for decoration).
/// - `.parent` — walk to the entity's parent first, then read. The
///   hydroponics case: the plant overlay is a child of the
///   workstation, and the driving `TendableWorkstation` lives on the
///   parent.
pub const SpriteByFieldSource = enum {
    self,
    parent,
};

/// Drive `Sprite.sprite_name` from a runtime field value.
///
/// `component` is the serde name of the source component (e.g.
/// `"TendableWorkstation"`), `field` is the field on that component
/// to read (e.g. `"level"`). The engine tick system resolves both at
/// runtime through `ComponentRegistry.getType` + `std.meta.fieldIndex`
/// and coerces the resulting value to `i32` so integer fields
/// (signed or unsigned) and `enum` fields (via `@intFromEnum`) all
/// feed the same `lookup` table.
///
/// `entries` is a slice of `Entry` structs — each `Entry.key` is
/// matched against the coerced field value; the first match wins and
/// its `sprite_name` is written onto the Sprite. A `null`
/// `sprite_name` means "hide the sprite" (the tick system toggles
/// `Sprite.visible = false` rather than setting a name) — used for
/// the hydroponics level 0/1 case.
///
/// ## Field lifetimes
///
/// `component`, `field`, and each entry's `sprite_name` are
/// **borrowed** — typically comptime string literals in the prefab,
/// or prefab-arena-owned slices. The component does not copy. Same
/// ownership contract as `PrefabInstance` / `PrefabChild` — see
/// `labelle-core/src/prefab.zig` for the full memory note.
///
/// ## Save policy
///
/// `.saveable` with the runtime `last_key_set` / `last_key` cache
/// skipped. On load, both reset and the next tick re-resolves
/// through the whole pipeline — a one-tick recheck is negligible
/// compared to saving the cache. Ensures save files stay small and
/// deterministic.
pub const SpriteByField = struct {
    pub const save = save_policy.Saveable(.saveable, @This(), .{
        .skip = &.{ "last_key_set", "last_key" },
    });

    pub const Entry = struct {
        /// Signed (per gemini review on RFC #472) so components using
        /// `-1` as a sentinel `Unset` value can participate.
        key: i32,
        /// `null` means "hide the sprite" (tick sets `visible = false`).
        sprite_name: ?[]const u8,
    };

    component: []const u8,
    field: []const u8,
    source: SpriteByFieldSource = .self,
    entries: []const Entry,

    // Runtime cache — skipped from save. Used by the tick system to
    // short-circuit `markVisualDirty` when the resolved sprite name
    // hasn't changed tick-over-tick (steady-state entities writing
    // nothing).
    last_key_set: bool = false,
    last_key: i32 = 0,

    /// Find the entry matching `key` and return its `sprite_name`.
    /// Returns:
    /// - `.match` with the entry's sprite (possibly `null` → "hide")
    ///   when an entry matched.
    /// - `.no_match` when `key` isn't in the table.
    ///
    /// First-match-wins on duplicate keys; duplicates are a prefab-
    /// authoring bug, not an engine invariant, so we don't assert.
    pub fn lookup(self: *const SpriteByField, key: i32) LookupResult {
        for (self.entries) |entry| {
            if (entry.key == key) return .{ .match = entry.sprite_name };
        }
        return .no_match;
    }

    pub const LookupResult = union(enum) {
        /// An entry matched. `sprite_name` is `null` when the entry
        /// says "hide" (empty slot in the table).
        match: ?[]const u8,
        /// No entry matched — tick system should leave the sprite
        /// alone (no mutation, no hide) rather than guessing.
        no_match,
    };
};
