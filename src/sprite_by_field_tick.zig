//! SpriteByField ECS tick system (Phase B+ of RFC-PREFAB-ANIMATION.md).
//!
//! Walks entities carrying `SpriteByField` + the renderer's Sprite,
//! reads the driving field value off the named component on either
//! the entity itself (`.self`) or its parent (`.parent`), coerces
//! to `i32`, and applies the lookup result to the Sprite.
//!
//! ## Runtime-string resolution pattern
//!
//! `SpriteByField.component` and `.field` are runtime strings (author-
//! facing — games declare them in prefabs). Zig's comptime wants
//! comptime-known strings for type and field lookup. The tick uses
//! the standard pattern: comptime-iterate every registered component
//! type, match on its serde name at runtime, and specialize the
//! getComponent + field-read inside the matching branch where the
//! type is comptime-known. Same shape as `save_load_mixin`'s
//! `inline for (names)` loop, just with a runtime-name match.
//!
//! Unknown component names (not in the registry) or unknown fields
//! (not on that component) result in a silent skip for that entity
//! this tick — same soft-fail semantics as the existing plugin-
//! controller duck typing (`production.Controller`,
//! `command_buffer.Controller`). Validation at spawn time can be
//! added later once `spawnFromPrefab` exists (Slice 2 / issue #479).

const std = @import("std");
const sbf_mod = @import("sprite_by_field.zig");
const SpriteByField = sbf_mod.SpriteByField;

pub fn tick(game: anytype, dt: f32) void {
    _ = dt; // SpriteByField is not time-driven; field value changes trigger the update.

    const Game = @TypeOf(game.*);
    const Sprite = Game.SpriteComp;
    const Reg = Game.ComponentRegistry;
    const names = comptime Reg.names();

    var view = game.active_world.ecs_backend.view(.{ SpriteByField, Sprite }, .{});
    defer view.deinit();

    while (view.next()) |entity| {
        const sbf = game.active_world.ecs_backend.getComponent(entity, SpriteByField) orelse continue;

        // Resolve the driving entity per the `source` enum.
        const target: @TypeOf(entity) = switch (sbf.source) {
            .self => entity,
            .parent => blk: {
                const p = game.getParent(entity) orelse continue;
                break :blk p;
            },
        };

        // Comptime-iterate the registry, match the component name at
        // runtime, specialize inside the matching branch.
        inline for (names) |comp_name| {
            if (std.mem.eql(u8, comp_name, sbf.component)) {
                const T = Reg.getType(comp_name);
                if (game.active_world.ecs_backend.getComponent(target, T)) |comp| {
                    const key_opt = readFieldAsI32(T, comp, sbf.field);
                    if (key_opt) |key| {
                        applyLookup(game, entity, sbf, key);
                    }
                }
                break;
            }
        }
    }
}

/// Read `field_name` off `comp` (typed as `T`) and coerce to `i32`.
/// Returns `null` when the field isn't on the struct or its type
/// isn't supported (non-integer, non-enum).
fn readFieldAsI32(comptime T: type, comp: *const T, field_name: []const u8) ?i32 {
    const info = @typeInfo(T);
    if (info != .@"struct") return null;

    inline for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            const FT = field.type;
            const finfo = @typeInfo(FT);
            const raw = @field(comp.*, field.name);
            return switch (finfo) {
                // `std.math.cast` returns `null` for values outside i32's
                // range — no overflow panic on `u64` > `i64::MAX` or
                // `i128` or other edge widths. Out-of-range keys end up
                // matching `.no_match` in the lookup table, which is the
                // intended graceful-fail path — the prefab just doesn't
                // have an entry for that value.
                .int => std.math.cast(i32, raw),
                .@"enum" => std.math.cast(i32, @intFromEnum(raw)),
                else => null,
            };
        }
    }
    return null;
}

fn applyLookup(game: anytype, entity: anytype, sbf: *SpriteByField, key: i32) void {
    // Cache: skip the whole pipeline when the key hasn't changed
    // since last tick. Matches the "idle entities write nothing"
    // contract Phase A+ established for SpriteAnimation.
    if (sbf.last_key_set and sbf.last_key == key) return;

    const Game = @TypeOf(game.*);
    const Sprite = Game.SpriteComp;

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite) orelse return;

    switch (sbf.lookup(key)) {
        .match => |maybe_sprite_name| {
            if (maybe_sprite_name) |name| {
                if (comptime @hasField(Sprite, "visible")) sprite.visible = true;
                sprite.sprite_name = name;
                // Atlas fields (source_rect / texture / display_*) are
                // resolved by `Game.resolveAtlasSprites` every frame
                // before renderer sync — writing `sprite_name` here is
                // enough to invalidate its per-entity cache and pull
                // in the correct mapping (including rotation + per-
                // axis texture scaling). See sprite_animation_tick.zig
                // for the full rationale.
            } else {
                // Null sprite_name → hide the overlay.
                if (comptime @hasField(Sprite, "visible")) sprite.visible = false;
            }
            // Always dirty: on atlas builds `resolveAtlasSprites` will
            // also dirty on its cache miss (idempotent); on stub or
            // sprite-by-name renderers this is the only signal the
            // renderer gets that the visual changed.
            game.renderer.markVisualDirty(entity);
        },
        .no_match => {
            // No entry for this key — leave the Sprite alone (don't
            // hide, don't overwrite). Authoring mistake to be caught
            // by a future spawn-time validator.
        },
    }

    sbf.last_key_set = true;
    sbf.last_key = key;
}
