//! Two-pass `@ref` resolution for the JSONC scene bridge.
//!
//! Slice 2 of #495. Components can declare `entity_ref` fields that
//! point to other entities by name (e.g. `WithItem { item_id: "@item" }`).
//! The first pass loads each entity, replaces every `@ref` string
//! with `0` so the deserializer can populate the component normally,
//! and registers the field for later patching. The second pass walks
//! the deferred list and writes the resolved entity ID back in
//! place, walking the `RefContext` parent chain so a prefab-body
//! entity's `@ref` can still match a name registered in the
//! enclosing scope.
//!
//! The resolver is fully generic over `GameType` + `Components`.
//! Callers instantiate once per bridge type:
//!
//!     const Resolver = RefResolver(GameType, Components);
//!     var ctx = Resolver.RefContext.init(allocator, null);
//!     ...
//!     try Resolver.collectDeferredRefFields(&ctx, entity, "Foo", value);
//!     ...
//!     for (ctx.deferred.items) |d| Resolver.patchRefField(game, d, &ctx);

const std = @import("std");
const jsonc = @import("jsonc");
const Value = jsonc.Value;
const core = @import("labelle-core");

pub fn RefResolver(comptime GameType: type, comptime Components: type) type {
    const Entity = GameType.EntityType;

    return struct {
        /// A single entity_ref field that needs patching with a
        /// resolved `@ref` ID after the entity load completes.
        pub const DeferredRefField = struct {
            entity: Entity,
            comp_name: []const u8,
            field_name: []const u8,
            ref_name: []const u8,
        };

        /// Ref context shared across entity loading — collects named
        /// refs and deferred field patches for two-pass resolution.
        ///
        /// Scopes form a chain via `parent`: registrations stay in
        /// the current scope (so repeated prefab instances don't
        /// collide on their internal ref names), but lookups walk
        /// up the chain (so a `@ref` inside a prefab body can still
        /// resolve to something registered in an enclosing scope —
        /// e.g. `food_packet` inside `food_storage_with_packet`
        /// referencing its parent's `@storage`).
        pub const RefContext = struct {
            ref_map: std.StringHashMap(u64),
            deferred: std.ArrayListUnmanaged(DeferredRefField),
            allocator: std.mem.Allocator,
            parent: ?*RefContext,

            pub fn init(allocator: std.mem.Allocator, parent: ?*RefContext) RefContext {
                return .{
                    .ref_map = std.StringHashMap(u64).init(allocator),
                    .deferred = .{},
                    .allocator = allocator,
                    .parent = parent,
                };
            }

            pub fn deinit(self: *RefContext) void {
                self.ref_map.deinit();
                self.deferred.deinit(self.allocator);
            }

            /// Resolve a ref name, walking up the parent chain when
            /// not found locally.
            pub fn lookup(self: *const RefContext, name: []const u8) ?u64 {
                if (self.ref_map.get(name)) |id| return id;
                if (self.parent) |p| return p.lookup(name);
                return null;
            }
        };

        /// Check if a component value contains `@ref` strings in
        /// any entity_ref field. Cheap pre-pass for callers that
        /// only need to do the buffer dance when refs are present.
        pub fn valueHasRefs(comp_name: []const u8, value: Value) bool {
            const obj = value.asObject() orelse return false;
            const comp_names = comptime Components.names();
            inline for (comp_names) |name| {
                if (std.mem.eql(u8, comp_name, name)) {
                    return hasRefsInFields(Components.getType(name), obj);
                }
            }
            return false;
        }

        fn hasRefsInFields(comptime T: type, obj: Value.Object) bool {
            const ref_fields = comptime core.getEntityRefFields(T);
            inline for (ref_fields) |field_name| {
                if (obj.getString(field_name)) |str| {
                    if (str.len > 0 and str[0] == '@') return true;
                }
            }
            return false;
        }

        /// Replace `@ref` strings with integer 0 in entity_ref
        /// fields so the deserializer can parse the component
        /// through the normal pipeline. The caller-supplied `buf`
        /// holds the rewritten entries; the returned `Value`
        /// borrows from it.
        pub fn replaceRefsWithZero(comp_name: []const u8, value: Value, buf: []Value.Object.Entry) ?Value {
            const obj = value.asObject() orelse return null;
            const comp_names = comptime Components.names();
            inline for (comp_names) |name| {
                if (std.mem.eql(u8, comp_name, name)) {
                    const T = Components.getType(name);
                    const ref_fields = comptime core.getEntityRefFields(T);
                    if (ref_fields.len == 0) return null;
                    var len: usize = 0;
                    for (obj.entries) |entry| {
                        if (len >= buf.len) break;
                        var e = entry;
                        inline for (ref_fields) |field_name| {
                            if (std.mem.eql(u8, entry.key, field_name)) {
                                if (entry.value.asString()) |str| {
                                    if (str.len > 0 and str[0] == '@') {
                                        e.value = .{ .integer = 0 };
                                    }
                                }
                            }
                        }
                        buf[len] = e;
                        len += 1;
                    }
                    return Value{ .object = .{ .entries = buf[0..len] } };
                }
            }
            return null;
        }

        /// Collect a `DeferredRefField` entry for each `@ref` string
        /// found in entity_ref fields. Run this during the first
        /// pass; the entries get patched in the second pass via
        /// `patchRefField`.
        pub fn collectDeferredRefFields(ref_ctx: *RefContext, entity: Entity, comp_name: []const u8, value: Value) !void {
            const obj = value.asObject() orelse return;
            const comp_names = comptime Components.names();
            inline for (comp_names) |name| {
                if (std.mem.eql(u8, comp_name, name)) {
                    const T = Components.getType(name);
                    const ref_fields = comptime core.getEntityRefFields(T);
                    inline for (ref_fields) |field_name| {
                        if (obj.getString(field_name)) |str| {
                            if (str.len > 0 and str[0] == '@') {
                                try ref_ctx.deferred.append(ref_ctx.allocator, .{
                                    .entity = entity,
                                    .comp_name = comp_name,
                                    .field_name = field_name,
                                    .ref_name = str[1..],
                                });
                            }
                        }
                    }
                    return;
                }
            }
        }

        /// Patch a single deferred ref field in-place on an
        /// already-applied component. Lookups walk up the
        /// `RefContext` parent chain so a prefab-body entity can
        /// resolve refs registered in its enclosing scope.
        pub fn patchRefField(game: *GameType, deferred: DeferredRefField, ref_ctx: *const RefContext) void {
            const comp_names = comptime Components.names();
            inline for (comp_names) |name| {
                if (std.mem.eql(u8, deferred.comp_name, name)) {
                    const T = Components.getType(name);
                    patchFieldOnComponent(T, game, deferred, ref_ctx);
                    return;
                }
            }
        }

        fn patchFieldOnComponent(comptime T: type, game: *GameType, deferred: DeferredRefField, ref_ctx: *const RefContext) void {
            if (game.ecs_backend.getComponent(deferred.entity, T)) |comp| {
                const ref_fields = comptime core.getEntityRefFields(T);
                inline for (ref_fields) |field_name| {
                    if (std.mem.eql(u8, deferred.field_name, field_name)) {
                        if (ref_ctx.lookup(deferred.ref_name)) |resolved_id| {
                            @field(comp, field_name) = resolved_id;
                        } else {
                            game.log.err("[SceneRef] Unresolved ref '@{s}' in {s}.{s}", .{ deferred.ref_name, deferred.comp_name, field_name });
                        }
                    }
                }
            }
        }
    };
}
