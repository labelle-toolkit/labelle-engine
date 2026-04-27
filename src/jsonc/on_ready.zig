//! Component `onReady` lifecycle for the JSONC scene bridge.
//!
//! Slice 3 of #495. After a scene/prefab pass applies a component
//! to an entity, the engine fires the matching component's
//! `onReady` hook (and `postLoad` if present). This module owns the
//! comptime dispatch: walk the names from a parsed
//! scene/prefab object, look the type up in `Components`, fire the
//! hook on the entity. Plus a tiny `[]const u64` field-patcher that
//! the entity-array spawn path uses to write IDs of just-spawned
//! children back into the parent's component (e.g.
//! `Workstation.storages`).
//!
//! All three helpers are generic over `GameType` + `Components`.
//! Callers instantiate once per bridge type:
//!
//!     const Hooks = OnReady(GameType, Components);
//!     Hooks.fireOnReadyAll(game, entity, scene_components, prefab_components, &applied);
//!     Hooks.patchEntityIdField(game, parent, "Workstation", "storages", ids);

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;

pub fn OnReady(comptime GameType: type, comptime Components: type) type {
    const Entity = GameType.EntityType;

    return struct {
        /// Fire `onReady` for every component the loader applied to
        /// `entity`. `scene_components` are the entity's own
        /// component overrides; `prefab_components` are the
        /// prefab-defined defaults. The `applied` set tracks which
        /// names have already fired (the scene block runs first,
        /// then the prefab block skips anything already handled) so
        /// hooks see exactly one fire per component, regardless of
        /// where the component originated.
        pub fn fireOnReadyAll(
            game: *GameType,
            entity: Entity,
            scene_components: ?Value.Object,
            prefab_components: ?Value.Object,
            applied: *std.StringHashMap(void),
        ) void {
            if (scene_components) |sc| {
                for (sc.entries) |entry| {
                    fireOnReadyByName(game, entity, entry.key);
                }
            }
            if (prefab_components) |pc| {
                for (pc.entries) |entry| {
                    if (!applied.contains(entry.key)) {
                        fireOnReadyByName(game, entity, entry.key);
                    }
                }
            }
        }

        /// Fire `onReady` for a single component by name using
        /// comptime dispatch. Also calls `postLoad(game, entity)`
        /// when the component declares it — gives components a
        /// hook for picking up runtime state that depends on
        /// fully-loaded siblings (workstation slot indexing,
        /// pathfinder repath markers, etc.).
        pub fn fireOnReadyByName(game: *GameType, entity: Entity, name: []const u8) void {
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    game.fireOnReady(entity, T);
                    if (@hasDecl(T, "postLoad")) {
                        if (game.ecs_backend.getComponent(entity, T)) |comp| {
                            comp.postLoad(game, entity);
                        }
                    }
                    return;
                }
            }
        }

        /// Patch a `[]const u64` field on an already-applied
        /// component with a slice of spawned entity IDs. Used by
        /// the nested-entity spawn path so a parent can hold a
        /// ref_array of its children (e.g.
        /// `Workstation.storages`) that survives save/load through
        /// the existing entity-ref save policy.
        pub fn patchEntityIdField(game: *GameType, entity: Entity, comp_name: []const u8, field_name: []const u8, ids: []const u64) void {
            const comp_names = comptime Components.names();
            inline for (comp_names) |cn| {
                if (std.mem.eql(u8, comp_name, cn)) {
                    const T = Components.getType(cn);
                    if (game.ecs_backend.getComponent(entity, T)) |comp| {
                        inline for (@typeInfo(T).@"struct".fields) |field| {
                            if (std.mem.eql(u8, field.name, field_name)) {
                                if (field.type == []const u64) {
                                    @field(comp, field.name) = ids;
                                }
                            }
                        }
                    }
                    return;
                }
            }
        }
    };
}
