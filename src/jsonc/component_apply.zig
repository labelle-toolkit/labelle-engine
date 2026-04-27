//! Apply a single named component to an entity from a parsed
//! JSONC `Value`. Slice 4b of #495.
//!
//! `applyComponent` handles three special cases (`Position` →
//! `setPosition`, `Sprite` → `addSprite`, `Shape` → `addShape`) and
//! falls through to comptime-dispatched `addComponent` for every
//! other registered component. `applyComponentWithRefs` wraps it
//! with the two-pass `@ref` resolution flow when a `RefContext` is
//! active.
//!
//! Allocation lifetime — `deserialize`-side allocations (slices for
//! `frames` / `entries` / etc.) land in
//! `active_world.nested_entity_arena` so they share the lifetime of
//! the spawned entity and free atomically on scene change via
//! `resetEcsBackend`. The transient `stripEntityArrayFields` scratch
//! uses `game.allocator` because its lifetime is the
//! `applyComponent` call only and the `defer` frees it.

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const core = @import("labelle-core");
const Position = core.Position;
const deserializer = @import("deserializer.zig");
const ref_resolver_mod = @import("ref_resolver.zig");

pub fn ComponentApply(comptime GameType: type, comptime Components: type) type {
    const Entity = GameType.EntityType;
    const Sprite = GameType.SpriteComp;
    const Shape = GameType.ShapeComp;
    const RefResolver = ref_resolver_mod.RefResolver(GameType, Components);
    const RefContext = RefResolver.RefContext;

    return struct {
        /// Apply a component, handling `@ref` substitution when
        /// `ref_ctx` is non-null. Components with `@ref` strings
        /// are applied with `0` placeholders through the full
        /// `applyComponent` pipeline, and their ref fields are
        /// collected for patching in pass 2.
        pub fn applyComponentWithRefs(
            game: *GameType,
            entity: Entity,
            comp_name: []const u8,
            value: Value,
            parent_offset: Position,
            ref_ctx: ?*RefContext,
        ) !void {
            if (ref_ctx) |rctx| {
                if (RefResolver.valueHasRefs(comp_name, value)) {
                    // Replace `@ref` strings with `0` so the full
                    // pipeline works. Allocate a scratch buffer
                    // sized to the object's entry count.
                    const obj = value.asObject() orelse {
                        applyComponent(game, entity, comp_name, value, parent_offset);
                        return;
                    };
                    const entries = try game.allocator.alloc(Value.Object.Entry, obj.entries.len);
                    defer game.allocator.free(entries);
                    const zeroed = RefResolver.replaceRefsWithZero(comp_name, value, entries) orelse value;
                    applyComponent(game, entity, comp_name, zeroed, parent_offset);
                    // Record which fields need patching in pass 2.
                    try RefResolver.collectDeferredRefFields(rctx, entity, comp_name, value);
                    return;
                }
            }
            applyComponent(game, entity, comp_name, value, parent_offset);
        }

        /// Apply a single named component to an entity.
        pub fn applyComponent(
            game: *GameType,
            entity: Entity,
            name: []const u8,
            value: Value,
            parent_offset: Position,
        ) void {
            // Position — uses setPosition, offset by parent position.
            if (std.mem.eql(u8, name, "Position")) {
                if (value.asObject()) |obj| {
                    var pos = Position{};
                    if (obj.getInteger("x")) |x| {
                        pos.x = @floatFromInt(x);
                    } else if (obj.getFloat("x")) |x| {
                        pos.x = @floatCast(x);
                    }
                    if (obj.getInteger("y")) |y| {
                        pos.y = @floatFromInt(y);
                    } else if (obj.getFloat("y")) |y| {
                        pos.y = @floatCast(y);
                    }
                    game.setPosition(entity, .{ .x = parent_offset.x + pos.x, .y = parent_offset.y + pos.y });
                }
                return;
            }

            const comp_alloc = game.active_world.nested_entity_arena.allocator();

            // Sprite — uses addSprite for renderer registration.
            if (std.mem.eql(u8, name, "Sprite")) {
                if (deserializer.deserialize(Sprite, value, comp_alloc)) |sprite| {
                    game.addSprite(entity, sprite);
                }
                return;
            }

            // Shape — uses addShape for renderer registration.
            if (std.mem.eql(u8, name, "Shape")) {
                if (deserializer.deserialize(Shape, value, comp_alloc)) |shape| {
                    game.addShape(entity, shape);
                }
                return;
            }

            // All other components — comptime dispatch via
            // Components registry.
            const filtered = stripEntityArrayFields(value, game.allocator);
            defer {
                // Free the filtered entries slice if it was newly
                // allocated.
                if (filtered.asObject()) |fo| {
                    if (value.asObject()) |orig| {
                        if (fo.entries.ptr != orig.entries.ptr) {
                            game.allocator.free(fo.entries);
                        }
                    }
                }
            }
            const comp_names = comptime Components.names();
            inline for (comp_names) |comp_name| {
                if (std.mem.eql(u8, name, comp_name)) {
                    const T = Components.getType(comp_name);
                    if (deserializer.deserialize(T, filtered, comp_alloc)) |component| {
                        game.addComponent(entity, component);
                    }
                    return;
                }
            }
        }

        /// Strip fields that contain entity-like arrays from a
        /// component `Value`. The entity-array fields are spawned
        /// separately (see `spawnAndLinkNestedEntities` in the
        /// scene loader); the deserializer would otherwise try to
        /// parse them as `[]const Struct` and fail.
        pub fn stripEntityArrayFields(value: Value, allocator: std.mem.Allocator) Value {
            const obj = value.asObject() orelse return value;
            var filtered: std.ArrayList(Value.Object.Entry) = .{};
            for (obj.entries) |entry| {
                const is_entity_array = blk: {
                    const arr = entry.value.asArray() orelse break :blk false;
                    if (arr.items.len == 0) break :blk false;
                    break :blk isEntityLike(arr.items[0]);
                };
                if (!is_entity_array) {
                    filtered.append(allocator, entry) catch {};
                }
            }
            return Value{ .object = .{ .entries = filtered.toOwnedSlice(allocator) catch obj.entries } };
        }

        /// Check if a `Value` looks like an entity definition (has
        /// either a `prefab` string or a `components` object).
        pub fn isEntityLike(value: Value) bool {
            const obj = value.asObject() orelse return false;
            return obj.getString("prefab") != null or obj.getObject("components") != null;
        }
    };
}
