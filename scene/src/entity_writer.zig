// Entity Writer — component addition and onReady firing for scene entities
//
// Extracted from loader.zig to separate entity writing (component coercion,
// entity references, plugin components) from scene loading orchestration.

const std = @import("std");
const labelle_core = @import("labelle-core");

const types = @import("types.zig");
const builtins = @import("builtins.zig");
const script_mod = @import("script.zig");
const component_mod = @import("component.zig");

const VisualType = labelle_core.VisualType;
const isReference = types.isReference;
const extractRefInfo = types.extractRefInfo;
const ReferenceContext = types.ReferenceContext;

/// Entity writer — handles component addition and onReady firing for scene entities.
///
/// Parameterized by:
/// - GameType: from GameConfig(...), provides Entity type, Sprite/Shape components, ECS backend
/// - Components: ComponentRegistry mapping names to game-specific component types
///
/// Supports:
/// - Component coercion from .zon data to concrete types
/// - Entity reference resolution (deferred to Phase 2)
/// - Merged components (prefab defaults + scene overrides)
/// - onReady lifecycle firing after all components are added
pub fn EntityWriter(
    comptime GameType: type,
    comptime Components: type,
) type {
    const Entity = GameType.EntityType;
    const EcsImpl = GameType.EcsBackend;
    const Sprite = GameType.SpriteComp;
    const RefCtx = ReferenceContext(Entity);

    return struct {
        // =====================================================================
        // Component addition with entity reference support
        // =====================================================================

        fn addAuthoredSprite(game: *GameType, entity: Entity, sprite: Sprite) void {
            var authored = sprite;
            if (comptime @hasField(Sprite, "material")) {
                if (comptime @FieldType(Sprite, "material") == labelle_core.Material) authored.material.shader = .none;
            }
            game.addSprite(entity, authored);
        }

        // =====================================================================
        // Built-in dispatch (#881)
        // =====================================================================
        //
        // BUILT-INS are engine-owned components that a project never
        // registers, so `Components.has(name)` is false for them and the
        // registry loop below walks straight past. Before #881 this writer
        // hand-rolled a chain of `Sprite`/`Shape` comparisons and everything
        // else fell off the end with NO error: a `.zon`-authored `Camera`,
        // `Image` or `Emitter` produced an entity with no such component and
        // not one diagnostic anywhere.
        //
        // The set now comes from `scene.builtins.Builtin` — one source of
        // truth shared with the other dispatch sites — and `handlerFor`'s
        // EXHAUSTIVE switch is what forces this writer to keep up: add a tag
        // to that enum without a prong here and the completeness gate below
        // fails to COMPILE, naming the built-in. Silent-drop is no longer
        // expressible.

        /// How a built-in reaches the ECS. `plain` is a bare
        /// `addComponent`; the others route through the Game API that
        /// also performs the built-in's side-effects (renderer tracking,
        /// tilemap decode, particle driving).
        const Via = enum { sprite, shape, tilemap, camera, image, emitter };

        const Handler = struct {
            via: Via,
            /// The entity's `VisualType` once this component lands
            /// (`.none` leaves whatever a sibling component set).
            visual: VisualType,
        };

        /// The writer branch for each built-in. EXHAUSTIVE on purpose —
        /// a new `builtins.Builtin` tag with no prong here is a compile
        /// error ("unhandled enumeration value"), which is exactly the
        /// #881 guarantee: a built-in can never be silently dropped from
        /// a `.zon` scene again.
        fn handlerFor(comptime b: builtins.Builtin) Handler {
            return switch (b) {
                .Sprite => .{ .via = .sprite, .visual = .sprite },
                .Shape => .{ .via = .shape, .visual = .shape },
                .Tilemap => .{ .via = .tilemap, .visual = .none },
                .Camera => .{ .via = .camera, .visual = .none },
                .Image => .{ .via = .image, .visual = .none },
                .Emitter => .{ .via = .emitter, .visual = .none },
            };
        }

        /// Completeness gate (#881). Forces `handlerFor` for EVERY
        /// built-in the moment this writer is instantiated — a missing
        /// prong breaks the build even if no scene authors that
        /// component yet.
        pub const builtin_dispatch_complete = blk: {
            for (std.enums.values(builtins.Builtin)) |b| _ = handlerFor(b);
            break :blk true;
        };

        comptime {
            std.debug.assert(builtin_dispatch_complete);
        }

        /// The built-in `name` dispatches to, or `null` when the name is
        /// not a built-in — or is a SHADOWABLE built-in the project
        /// registered itself (`Tilemap`/`Camera`/`Image`/`Emitter`),
        /// which mirrors the `!Components.has(…)` gates in
        /// `jsonc/component_apply.zig`. `Sprite`/`Shape` are
        /// unconditional and shadow the registry, as they always have.
        fn builtinFor(comptime name: []const u8) ?builtins.Builtin {
            const b = comptime builtins.lookup(name) orelse return null;
            if (comptime b.shadowable() and Components.has(name)) return null;
            return b;
        }

        /// Add one built-in, coercing the authored `.zon` value to the
        /// engine type the Game exposes as `<name>Comp`. `overlay` is a
        /// scene-level override tuple laid over `value` (pass `.{}` when
        /// there is none — an empty overlay is the identity merge), so a
        /// prefab + scene pair reaches the built-in's add path ONCE, on
        /// the merged value.
        fn addBuiltin(
            comptime b: builtins.Builtin,
            game: *GameType,
            entity: Entity,
            comptime value: anytype,
            comptime overlay: anytype,
        ) VisualType {
            const T = comptime b.Type(GameType);
            const handler = comptime handlerFor(b);
            switch (comptime handler.via) {
                .sprite => addAuthoredSprite(game, entity, merge(T, value, overlay)),
                .shape => game.addShape(entity, merge(T, value, overlay)),
                .tilemap => game.addTilemap(entity, merge(T, value, overlay)),
                .camera => {
                    // `tag` is an inline `[16:0]u8`; a `.zon` string can
                    // only reach it through `setTagSlice` (the same reason
                    // `applyCamera` special-cases it on the JSONC side).
                    var cam = coerceMergedSkipping(T, value, overlay, "tag");
                    if (comptime @hasField(@TypeOf(overlay), "tag")) {
                        cam.setTagSlice(@field(overlay, "tag"));
                    } else if (comptime @hasField(@TypeOf(value), "tag")) {
                        cam.setTagSlice(@field(value, "tag"));
                    }
                    game.addComponent(entity, cam);
                },
                .image => game.addComponent(entity, merge(T, value, overlay)),
                .emitter => {
                    game.addComponent(entity, merge(T, value, overlay));
                    // Parity with `applyEmitter`: authoring an emitter
                    // turns the particle tick/draw on by itself.
                    game.drive_particles = true;
                },
            }
            return comptime handler.visual;
        }

        /// Field-by-field coerce of `overlay` over `value` into `T`,
        /// leaving the field named `skip` at its default — for inline
        /// bounded buffers (`Camera.tag`) that no generic coercion can
        /// fill from a `.zon` string.
        fn coerceMergedSkipping(
            comptime T: type,
            comptime value: anytype,
            comptime overlay: anytype,
            comptime skip: []const u8,
        ) T {
            var result: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (comptime std.mem.eql(u8, f.name, skip)) {
                    setFieldDefault(f, &result);
                } else if (comptime @hasField(@TypeOf(overlay), f.name)) {
                    @field(result, f.name) = coerce(f.type, @field(overlay, f.name));
                } else if (comptime @hasField(@TypeOf(value), f.name)) {
                    @field(result, f.name) = coerce(f.type, @field(value, f.name));
                } else {
                    setFieldDefault(f, &result);
                }
            }
            return result;
        }

        /// Add components from a comptime component tuple to an entity.
        /// Handles Sprite/Shape visuals, custom components from the ComponentRegistry,
        /// and entity references (deferred to Phase 2 via ref_ctx).
        pub fn addComponents(entity: Entity, game: *GameType, comptime comps: anytype, ref_ctx: ?*RefCtx) VisualType {
            var vtype: VisualType = .none;

            inline for (@typeInfo(@TypeOf(comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;

                const value = @field(comps, field.name);

                if (comptime builtinFor(field.name)) |b| {
                    const v = addBuiltin(b, game, entity, value, .{});
                    if (v != .none) vtype = v;
                } else if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    addCustomComponent(T, field.name, entity, game, value, ref_ctx);
                }
            }

            return vtype;
        }

        /// Add merged components from prefab defaults + scene overrides.
        /// Prefab components are merged with scene overrides; scene-only components
        /// are added directly. Position is always skipped (handled by orchestrator).
        pub fn addMergedComponents(
            entity: Entity,
            game: *GameType,
            comptime prefab_comps: anytype,
            comptime scene_comps: anytype,
            ref_ctx: ?*RefCtx,
        ) VisualType {
            var vtype: VisualType = .none;

            // Prefab components (merged with scene overrides)
            inline for (@typeInfo(@TypeOf(prefab_comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;

                const prefab_val = @field(prefab_comps, field.name);
                const has_override = comptime @hasField(@TypeOf(scene_comps), field.name);

                if (comptime builtinFor(field.name)) |b| {
                    // Merged authoring stays a `.zon`-level overlay so the
                    // built-in's add path (and its side-effects) runs once,
                    // on the merged value.
                    const v = if (comptime has_override)
                        addBuiltin(b, game, entity, prefab_val, @field(scene_comps, field.name))
                    else
                        addBuiltin(b, game, entity, prefab_val, .{});
                    if (v != .none) vtype = v;
                } else if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    if (has_override) {
                        const val = comptime merge(T, prefab_val, @field(scene_comps, field.name));
                        game.ecs_backend.addComponent(entity, val);
                    } else {
                        addCustomComponent(T, field.name, entity, game, prefab_val, ref_ctx);
                    }
                }
            }

            // Scene-only components (not in prefab)
            inline for (@typeInfo(@TypeOf(scene_comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;
                if (comptime @hasField(@TypeOf(prefab_comps), field.name)) continue;

                const value = @field(scene_comps, field.name);

                if (comptime builtinFor(field.name)) |b| {
                    const v = addBuiltin(b, game, entity, value, .{});
                    if (v != .none) vtype = v;
                } else if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    addCustomComponent(T, field.name, entity, game, value, ref_ctx);
                }
            }

            return vtype;
        }

        /// Add a custom component, handling Entity-typed fields that may contain references
        /// and nested entity array fields that contain child entity definitions.
        /// All reference and nested-array detection is comptime — no runtime branching.
        fn addCustomComponent(
            comptime T: type,
            comptime comp_name: []const u8,
            entity: Entity,
            game: *GameType,
            comptime comp_data: anytype,
            ref_ctx: ?*RefCtx,
        ) void {
            _ = comp_name;
            const t_info = @typeInfo(T);

            // Check at comptime if this component has any entity reference fields
            const has_refs = comptime blk: {
                if (t_info != .@"struct") break :blk false;
                for (t_info.@"struct".fields) |comp_field| {
                    if (comp_field.type == Entity) {
                        if (@hasField(@TypeOf(comp_data), comp_field.name)) {
                            if (isReference(@field(comp_data, comp_field.name))) {
                                break :blk true;
                            }
                        }
                    }
                }
                break :blk false;
            };

            // Check at comptime if this component has nested entity array fields
            const has_nested = comptime hasNestedEntityFields(T, comp_data);

            // Comptime branch: if no refs and no nested arrays, just coerce directly.
            // This also handles non-struct types (unions, enums) which have no
            // field-level references and can be coerced directly.
            if (!has_refs and !has_nested) {
                game.ecs_backend.addComponent(entity, coerce(T, comp_data));
                return;
            }

            // Build the component field-by-field, deferring references and
            // skipping nested entity arrays (those stay at default, populated later).
            // Only reachable for struct types (has_refs/has_nested are always false for non-structs).
            if (t_info != .@"struct") unreachable;
            var comp: T = undefined;
            inline for (t_info.@"struct".fields) |comp_field| {
                if (@hasField(@TypeOf(comp_data), comp_field.name)) {
                    const field_val = @field(comp_data, comp_field.name);

                    if ((comp_field.type == []const u64 or comp_field.type == []const Entity) and
                        comptime isNestedEntityArray(field_val))
                    {
                        // Nested entity array — skip during coercion; the loader will
                        // spawn child entities and populate this field with their IDs.
                        setFieldDefault(comp_field, &comp);
                    } else if (comp_field.type == Entity and comptime isReference(field_val)) {
                        // Placeholder — will be resolved in Phase 2
                        @field(comp, comp_field.name) = entity; // self as placeholder

                        // Queue for Phase 2 resolution
                        const ref_info = comptime extractRefInfo(field_val).?;
                        const field_name = comp_field.name;

                        const ResolveHelper = struct {
                            fn resolve(ecs_ptr: *anyopaque, target: Entity, resolved: Entity) void {
                                const ecs: *EcsImpl = @ptrCast(@alignCast(ecs_ptr));
                                if (ecs.getComponent(target, T)) |c| {
                                    @field(c, field_name) = resolved;
                                }
                            }
                        };

                        if (ref_ctx) |ctx| {
                            ctx.addPendingRef(.{
                                .target_entity = entity,
                                .resolve_callback = ResolveHelper.resolve,
                                .ref_key = ref_info.ref_key orelse "",
                                .is_self_ref = ref_info.is_self,
                                .is_id_ref = ref_info.is_id_ref,
                            }) catch @panic("OOM");
                        }
                    } else {
                        @field(comp, comp_field.name) = coerce(comp_field.type, field_val);
                    }
                } else if (comp_field.default_value_ptr) |ptr| {
                    const default = @as(*const comp_field.type, @ptrCast(@alignCast(ptr)));
                    @field(comp, comp_field.name) = default.*;
                }
            }

            game.ecs_backend.addComponent(entity, comp);
        }

        // =====================================================================
        // onReady firing — after all components have been added to an entity
        // =====================================================================

        /// Fire `onReady` for each component in a comptime component tuple.
        /// Skips Position (handled separately) and visual components (Sprite/Shape).
        /// Only fires for custom components registered in the ComponentRegistry.
        pub fn fireOnReadyForComponents(entity: Entity, game: *GameType, comptime comps: anytype) void {
            inline for (@typeInfo(@TypeOf(comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;
                if (comptime std.mem.eql(u8, field.name, "Sprite")) continue;
                if (comptime std.mem.eql(u8, field.name, "Shape")) continue;

                if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    game.fireOnReady(entity, T);
                }
            }
        }

        /// Fire `onReady` for the merged set of prefab + scene components, ensuring
        /// each component type is fired exactly once even when it appears in both.
        /// Iterates prefab components first, then scene-only components (skipping
        /// any already covered by the prefab).
        pub fn fireOnReadyMerged(entity: Entity, game: *GameType, comptime prefab_comps: anytype, comptime scene_comps: anytype) void {
            // Fire for all prefab components
            inline for (@typeInfo(@TypeOf(prefab_comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;
                if (comptime std.mem.eql(u8, field.name, "Sprite")) continue;
                if (comptime std.mem.eql(u8, field.name, "Shape")) continue;

                if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    game.fireOnReady(entity, T);
                }
            }

            // Fire for scene-only components (not already in prefab)
            inline for (@typeInfo(@TypeOf(scene_comps)).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "Position")) continue;
                if (comptime std.mem.eql(u8, field.name, "Sprite")) continue;
                if (comptime std.mem.eql(u8, field.name, "Shape")) continue;
                if (comptime @hasField(@TypeOf(prefab_comps), field.name)) continue;

                if (comptime Components.has(field.name)) {
                    const T = Components.getType(field.name);
                    game.fireOnReady(entity, T);
                }
            }
        }

        // =====================================================================
        // Helpers
        // =====================================================================

        /// Set a struct field to its default value, or &.{} if no default exists.
        /// Used when skipping nested entity array fields during coercion.
        fn setFieldDefault(comptime comp_field: anytype, result: anytype) void {
            if (comp_field.default_value_ptr) |ptr| {
                const default = @as(*const comp_field.type, @ptrCast(@alignCast(ptr)));
                @field(result, comp_field.name) = default.*;
            } else {
                @field(result, comp_field.name) = &.{};
            }
        }

        // =====================================================================
        // Nested entity array detection
        // =====================================================================

        /// Check if a comptime .zon value is a tuple of nested entity definitions.
        /// These are struct tuples where each element has .prefab or .components,
        /// meaning they represent child entities to be spawned — not plain data
        /// that can be coerced to the target field type (e.g. []const u64).
        ///
        /// Example .zon that triggers this:
        ///   .workstations = .{
        ///       .{ .prefab = "bakery_workstation", .components = .{ .Position = .{} } },
        ///   },
        pub fn isNestedEntityArray(comptime zon_val: anytype) bool {
            const Src = @TypeOf(zon_val);
            const src_info = @typeInfo(Src);
            if (src_info != .@"struct") return false;
            // Must be a tuple (fields named "0", "1", ...)
            if (!src_info.@"struct".is_tuple) return false;
            if (src_info.@"struct".fields.len == 0) return false;
            // Check first element for entity definition markers
            const first = zon_val.@"0";
            const FirstType = @TypeOf(first);
            return @hasField(FirstType, "prefab") or @hasField(FirstType, "components");
        }

        /// Check if a component type T has any fields that could hold nested entity
        /// arrays ([]const u64 / []const Entity), given the .zon data provided.
        /// Returns true if at least one field's .zon value is a nested entity tuple.
        pub fn hasNestedEntityFields(comptime T: type, comptime comp_data: anytype) bool {
            const t_info = @typeInfo(T);
            if (t_info != .@"struct") return false;
            for (t_info.@"struct".fields) |comp_field| {
                if (comp_field.type == []const u64 or comp_field.type == []const Entity) {
                    if (@hasField(@TypeOf(comp_data), comp_field.name)) {
                        if (isNestedEntityArray(@field(comp_data, comp_field.name))) {
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        // =====================================================================
        // Deep .zon coercion
        // =====================================================================

        /// Deep-coerce a .zon anonymous value into target type T.
        /// Handles structs (field-by-field), tagged unions (by active field), and enums.
        pub fn coerce(comptime T: type, comptime zon_val: anytype) T {
            if (T == labelle_core.shader_material.Id) return .none;
            const Src = @TypeOf(zon_val);
            const src_info = @typeInfo(Src);
            const dst_info = @typeInfo(T);

            if (Src == T) return zon_val;

            // Enum coercion: .tag_name → T.tag_name
            if (dst_info == .@"enum") {
                if (src_info == .enum_literal) {
                    return @field(T, @tagName(zon_val));
                }
                return zon_val;
            }

            // Tagged union coercion: .{ .variant = payload } → T{ .variant = coerced_payload }
            if (dst_info == .@"union") {
                if (src_info == .@"struct") {
                    const fields = src_info.@"struct".fields;
                    if (fields.len == 1) {
                        const src_field = fields[0];
                        const payload = @field(zon_val, src_field.name);
                        const UnionPayload = @FieldType(T, src_field.name);
                        return @unionInit(T, src_field.name, coerce(UnionPayload, payload));
                    }
                }
                return zon_val;
            }

            // Struct coercion: field-by-field, filling from source then defaults.
            // Fields whose .zon value is a nested entity array (tuple of entity defs)
            // are skipped here and left at their default value — they are expanded into
            // child entities by the scene loader in a separate pass.
            if (dst_info == .@"struct") {
                if (src_info == .@"struct") {
                    var result: T = undefined;
                    comptime var matched_fields: usize = 0;
                    inline for (dst_info.@"struct".fields) |dst_field| {
                        if (@hasField(Src, dst_field.name)) {
                            const field_val = @field(zon_val, dst_field.name);
                            // Skip nested entity arrays — these are []const u64 fields
                            // whose .zon value contains entity definitions (structs with
                            // .prefab or .components). They cannot be coerced directly;
                            // the loader will spawn child entities and fill in the IDs.
                            if ((dst_field.type == []const u64 or dst_field.type == []const Entity) and
                                isNestedEntityArray(field_val))
                            {
                                // Use the field's default value (typically &.{})
                                setFieldDefault(dst_field, &result);
                                matched_fields += 1;
                            } else {
                                @field(result, dst_field.name) = coerce(dst_field.type, field_val);
                                matched_fields += 1;
                            }
                        } else if (dst_field.default_value_ptr) |ptr| {
                            const default = @as(*const dst_field.type, @ptrCast(@alignCast(ptr)));
                            @field(result, dst_field.name) = default.*;
                        }
                    }
                    // EnumSet coercion: when source fields are enum variant names
                    // with bool values (e.g. .{ .Water = true }), build the set.
                    if (matched_fields == 0) {
                        // Empty .zon struct coercing to a struct where all fields have defaults:
                        // return the result which already has all defaults populated above.
                        if (@typeInfo(Src).@"struct".fields.len == 0) {
                            const all_defaults = comptime blk: {
                                for (dst_info.@"struct".fields) |f| {
                                    if (f.default_value_ptr == null) break :blk false;
                                }
                                break :blk true;
                            };
                            if (all_defaults) return result;
                        }
                        // EnumSet-like types: has initEmpty() + insert(), source has bool fields
                        if (@hasDecl(T, "initEmpty") and @hasDecl(T, "insert")) {
                            var set = T.initEmpty();
                            const src_fields = @typeInfo(Src).@"struct".fields;
                            inline for (src_fields) |sf| {
                                if (@field(zon_val, sf.name) == true) {
                                    set.insert(@field(T.Key, sf.name));
                                }
                            }
                            return set;
                        }
                        if (@hasDecl(T, "initEmpty")) {
                            return T.initEmpty();
                        } else if (@hasDecl(T, "init")) {
                            return T.init();
                        } else {
                            @compileError("Cannot coerce to " ++ @typeName(T) ++ ": no matching fields and no init()/initEmpty() method.");
                        }
                    }
                    return result;
                }
            }

            return zon_val;
        }

        /// Merge: coerce base, then overlay fields on top.
        /// Nested entity array fields are skipped — they are expanded by the loader.
        pub fn merge(comptime T: type, comptime base: anytype, comptime overlay: anytype) T {
            var result: T = coerce(T, base);
            inline for (@typeInfo(@TypeOf(overlay)).@"struct".fields) |field| {
                if (@hasField(T, field.name)) {
                    const FieldType = @TypeOf(@field(result, field.name));
                    const overlay_val = @field(overlay, field.name);
                    // Skip nested entity arrays — can't coerce entity defs to []const u64
                    if ((FieldType == []const u64 or FieldType == []const Entity) and
                        isNestedEntityArray(overlay_val))
                    {
                        continue;
                    }
                    @field(result, field.name) = coerce(FieldType, overlay_val);
                }
            }
            return result;
        }
    };
}
