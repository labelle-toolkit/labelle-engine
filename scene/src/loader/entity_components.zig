// Entity creation and component resolution — the recursive core of scene loading.
//
// This module contains the mutually-recursive functions for creating entities,
// resolving components, handling nested entity definitions, and creating gizmos.
// Extracted from loader.zig (Issue #278) to separate orchestration from core logic.

const std = @import("std");
const builtin = @import("builtin");
const ecs = @import("ecs");
const zon = @import("../../../core/src/zon_coercion.zig");
const core_mod = @import("../core.zig");
const game_mod = @import("../../../engine/game.zig");
const loader_types = @import("types.zig");
const render = @import("../../../render/src/pipeline.zig");

const Entity = ecs.Entity;
const Scene = core_mod.Scene;
const EntityInstance = core_mod.EntityInstance;
const VisualType = core_mod.VisualType;
const Game = game_mod.Game;

const ReadyCallbackEntry = loader_types.ReadyCallbackEntry;
const ParentContext = loader_types.ParentContext;
const no_parent = loader_types.no_parent;
const Pos = loader_types.Pos;
const getFieldOrDefault = loader_types.getFieldOrDefault;
const getPositionFromComponents = loader_types.getPositionFromComponents;

/// Recursive core operations for entity creation and component resolution.
/// Parameterized by Prefabs and Components registries (Scripts not needed here).
pub fn EntityComponentOps(comptime Prefabs: type, comptime Components: type) type {
    const Position = Components.getType("Position");

    return struct {
        // =====================================================================
        // Entity creation
        // =====================================================================

        /// Create a child entity and track it in the scene for cleanup.
        ///
        /// When scene is provided:
        /// - Child entities are added to scene.entities for lifecycle management
        /// - Allocated entity slices are tracked in scene.allocated_entity_slices for cleanup
        ///
        /// When scene is null:
        /// - Caller is responsible for entity cleanup (destroy via registry)
        /// - Allocated slice ownership transfers to caller (must free via game.allocator)
        fn createAndTrackChildEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            const instance = try createChildEntity(game, scene, entity_def, parent_x, parent_y, parent_ctx, ready_queue);
            if (scene) |s| {
                try s.addEntity(instance);
            }
            return instance;
        }

        fn createChildEntities(
            game: *Game,
            scene: ?*Scene,
            comptime entity_defs: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) ![]Entity {
            const entity_count = @typeInfo(@TypeOf(entity_defs)).@"struct".fields.len;

            // Allocate slice for entity references
            const entities = try game.allocator.alloc(Entity, entity_count);

            // Create each child entity
            inline for (0..entity_count) |i| {
                const entity_def = entity_defs[i];
                const instance = try createAndTrackChildEntity(game, scene, entity_def, parent_x, parent_y, parent_ctx, ready_queue);
                entities[i] = instance.entity;
            }

            // Track the allocated slice for cleanup on scene deinit
            if (scene) |s| {
                try s.trackAllocatedSlice(entities);
            }

            return entities;
        }

        /// Create a single child entity with support for prefabs or inline components.
        /// Positions are relative to parent.
        /// Visual components (Sprite, Shape, Text) are handled uniformly through
        /// addComponentsExcluding, with their onAdd callbacks handling pipeline registration.
        fn createChildEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            // Check if this is a prefab reference
            if (@hasField(@TypeOf(entity_def), "prefab")) {
                return try createChildPrefabEntity(game, scene, entity_def, parent_x, parent_y, parent_ctx, ready_queue);
            }

            // Inline entity with components - visual type is determined by which components are present
            if (@hasField(@TypeOf(entity_def), "components")) {
                return try createChildComponentEntity(game, scene, entity_def, parent_x, parent_y, parent_ctx, ready_queue);
            }

            @compileError("Child entity must have .prefab or .components field");
        }

        /// Create a child entity that references a prefab.
        /// Uses uniform component handling - visual components are registered via onAdd callbacks.
        fn createChildPrefabEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            const prefab_name = entity_def.prefab;

            // Verify prefab exists at compile time
            comptime {
                if (!Prefabs.has(prefab_name)) {
                    @compileError("Prefab not found in nested entity: " ++ prefab_name);
                }
            }

            const entity = game.createEntity();

            // Get position from .components.Position (scene overrides prefab), relative to parent
            const local_pos = getPrefabPosition(prefab_name, entity_def);
            const pos_x = parent_x + local_pos.x;
            const pos_y = parent_y + local_pos.y;

            game.getRegistry().addComponent(entity, Position{ .x = pos_x, .y = pos_y });

            // Add components from prefab, merging with entity_def overrides where present
            // Note: Child entities don't support entity references (no ref_ctx)
            if (comptime Prefabs.hasComponents(prefab_name)) {
                const prefab_components = Prefabs.getComponents(prefab_name);
                const scene_components = if (@hasField(@TypeOf(entity_def), "components"))
                    entity_def.components
                else
                    .{};

                try addMergedPrefabComponents(game, scene, entity, prefab_components, scene_components, pos_x, pos_y, parent_ctx, ready_queue, null);
            }

            // Add entity_def-only components (components in entity_def that don't exist in prefab)
            if (@hasField(@TypeOf(entity_def), "components")) {
                if (comptime Prefabs.hasComponents(prefab_name)) {
                    const prefab_components = Prefabs.getComponents(prefab_name);
                    try addSceneOnlyComponents(game, scene, entity, prefab_components, entity_def.components, pos_x, pos_y, parent_ctx, ready_queue, null);
                } else {
                    try addComponentsExcluding(game, scene, entity, entity_def.components, pos_x, pos_y, .{"Position"}, parent_ctx, ready_queue, null);
                }
            }

            // Create gizmo entities (debug builds only)
            // Scene-level gizmos override prefab gizmos
            if (@hasField(@TypeOf(entity_def), "gizmos")) {
                try createGizmoEntities(game, scene, entity, entity_def.gizmos, pos_x, pos_y, ready_queue);
            } else if (comptime Prefabs.hasGizmos(prefab_name)) {
                try createGizmoEntities(game, scene, entity, Prefabs.getGizmos(prefab_name), pos_x, pos_y, ready_queue);
            }

            return .{
                .entity = entity,
                .visual_type = comptime getVisualTypeFromPrefab(prefab_name),
                .prefab_name = prefab_name,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        /// Create a child entity from inline component definitions.
        /// Handles all component types uniformly - visual components (Sprite, Shape, Text)
        /// are registered with the render pipeline via their onAdd callbacks.
        /// Note: Child entities don't support entity references (no ref_ctx).
        fn createChildComponentEntity(
            game: *Game,
            scene: ?*Scene,
            comptime entity_def: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !EntityInstance {
            const entity = game.createEntity();

            // Get position from .components.Position, relative to parent
            const local_pos = getPositionFromComponents(entity_def) orelse Pos{ .x = 0, .y = 0 };
            const child_x = parent_x + local_pos.x;
            const child_y = parent_y + local_pos.y;
            game.getRegistry().addComponent(entity, Position{ .x = child_x, .y = child_y });

            // Add all components (Sprite/Shape/Text handled via fromZonData, others generically)
            // Position is excluded since we already added it above
            // Note: Child entities don't support entity references (no ref_ctx)
            try addComponentsExcluding(game, scene, entity, entity_def.components, child_x, child_y, .{"Position"}, parent_ctx, ready_queue, null);

            // Create gizmo entities if present (debug builds only)
            if (@hasField(@TypeOf(entity_def), "gizmos")) {
                try createGizmoEntities(game, scene, entity, entity_def.gizmos, child_x, child_y, ready_queue);
            }

            return .{
                .entity = entity,
                .visual_type = comptime getVisualTypeFromComponents(entity_def.components),
                .prefab_name = null,
                .onUpdate = null,
                .onDestroy = null,
            };
        }

        // =====================================================================
        // Component resolution
        // =====================================================================

        /// Add a component, creating child entities for any []const Entity fields.
        /// If scene is provided, child entities are tracked for cleanup.
        /// Supports parent reference convention: if parent_ctx is provided and this component
        /// has a field matching the parent component name (lowercased), it will be set to the parent entity.
        /// Supports entity references (Issue #242): if ref_ctx is provided and a field value is
        /// a reference (.ref = .{ .entity = "name" } or .ref = .self), it's deferred to Phase 2.
        fn addComponentWithNestedEntities(
            game: *Game,
            scene: ?*Scene,
            parent_entity: Entity,
            comptime comp_name: []const u8,
            comptime comp_data: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
            ref_ctx: ?*loader_types.ReferenceContext,
        ) !void {
            // Generic component handling
            const ComponentType = Components.getType(comp_name);
            const comp_fields = @typeInfo(ComponentType).@"struct".fields;
            var component: ComponentType = undefined;

            // Create a new parent context for child entities of this component
            const child_parent_ctx = ParentContext{
                .entity = parent_entity,
                .component_name = comp_name,
            };

            // Process each field in the component type
            inline for (comp_fields) |comp_field| {
                const field_name = comp_field.name;

                // Handle Entity fields specially for parent reference auto-population (RFC #169)
                // and entity references (Issue #242)
                if (comptime comp_field.type == Entity) {
                    // Check at runtime if this is a parent reference field
                    // Convention: field name matches parent component name (lowercased)
                    const is_parent_ref = is_parent_ref: {
                        const ctx = parent_ctx orelse break :is_parent_ref false;
                        if (field_name.len != ctx.component_name.len) break :is_parent_ref false;
                        inline for (field_name, 0..) |f, i| {
                            const p = ctx.component_name[i];
                            const lower_p = if (p >= 'A' and p <= 'Z') p + 32 else p;
                            if (f != lower_p) break :is_parent_ref false;
                        }
                        break :is_parent_ref true;
                    };

                    if (is_parent_ref) {
                        // Auto-populate parent reference field
                        @field(component, field_name) = parent_ctx.?.entity;
                    } else if (@hasField(@TypeOf(comp_data), field_name)) {
                        const entity_def = @field(comp_data, field_name);

                        // Check if this is a reference (Issue #242)
                        if (comptime zon.isReference(entity_def)) {
                            // Defer reference resolution to Phase 2
                            const ref_info = comptime zon.extractRefInfo(entity_def).?;

                            // Set placeholder value (will be resolved in Phase 2)
                            @field(component, field_name) = @bitCast(@as(ecs.EntityBits, 0));

                            // Generate callback that captures comptime component/field
                            const ResolveHelper = struct {
                                fn resolve(registry: *ecs.Registry, target: Entity, resolved: Entity) void {
                                    if (registry.getComponent(target, ComponentType)) |comp| {
                                        @field(comp, field_name) = resolved;
                                    }
                                }
                            };

                            // Queue for Phase 2 resolution
                            if (ref_ctx) |ctx| {
                                try ctx.addPendingRef(.{
                                    .target_entity = parent_entity,
                                    .resolve_callback = ResolveHelper.resolve,
                                    .ref_key = ref_info.ref_key orelse "",
                                    .is_self_ref = ref_info.is_self,
                                    .is_id_ref = ref_info.is_id_ref,
                                });
                            }
                        } else {
                            // Single Entity field - create child entity from definition
                            const instance = try createAndTrackChildEntity(game, scene, entity_def, parent_x, parent_y, child_parent_ctx, ready_queue);
                            @field(component, field_name) = instance.entity;
                        }
                    } else if (comp_field.default_value_ptr) |ptr| {
                        const default_ptr: *const comp_field.type = @ptrCast(@alignCast(ptr));
                        @field(component, field_name) = default_ptr.*;
                    } else {
                        @compileError("Missing required field '" ++ field_name ++ "' for component '" ++ comp_name ++ "'");
                    }
                } else if (@hasField(@TypeOf(comp_data), field_name)) {
                    // Data provides this field
                    if (comptime zon.isEntitySlice(comp_field.type)) {
                        // This field is []const Entity - create child entities from the tuple
                        const entity_defs = @field(comp_data, field_name);
                        @field(component, field_name) = try createChildEntities(game, scene, entity_defs, parent_x, parent_y, child_parent_ctx, ready_queue);
                    } else {
                        // Regular field - coerce to handle nested structs and tuples
                        const data_value = @field(comp_data, field_name);
                        @field(component, field_name) = zon.coerceValue(comp_field.type, data_value);
                    }
                } else if (comp_field.default_value_ptr) |ptr| {
                    // Field not provided but has a default value
                    const default_ptr: *const comp_field.type = @ptrCast(@alignCast(ptr));
                    @field(component, field_name) = default_ptr.*;
                } else {
                    // Required field not provided - compile-time error
                    @compileError("Missing required field '" ++ field_name ++ "' for component '" ++ comp_name ++ "'");
                }
            }

            game.getRegistry().addComponent(parent_entity, component);

            // Queue onReady callback if component defines one
            if (@hasDecl(ComponentType, "onReady")) {
                try ready_queue.append(game.allocator, .{
                    .entity = parent_entity,
                    .callback = ComponentType.onReady,
                });
            }
        }

        /// Add all components, handling nested entity definitions where present.
        /// If scene is provided, child entities are tracked for cleanup.
        fn addComponentsWithNestedEntities(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime components_data: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
            ref_ctx: ?*loader_types.ReferenceContext,
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));
            inline for (data_fields) |field_name| {
                const field_data = @field(components_data, field_name);
                try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y, parent_ctx, ready_queue, ref_ctx);
            }
        }

        /// Add all components except those in the excluded_names tuple.
        /// Used when certain components (like Position, Sprite, Shape) are handled separately.
        pub fn addComponentsExcluding(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime components_data: anytype,
            parent_x: f32,
            parent_y: f32,
            comptime excluded_names: anytype,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
            ref_ctx: ?*loader_types.ReferenceContext,
        ) !void {
            const data_fields = comptime std.meta.fieldNames(@TypeOf(components_data));

            data_field_loop: inline for (data_fields) |field_name| {
                // Check if this field should be excluded
                inline for (excluded_names) |excluded| {
                    if (comptime std.mem.eql(u8, field_name, excluded)) {
                        continue :data_field_loop;
                    }
                }
                const field_data = @field(components_data, field_name);
                try addComponentWithNestedEntities(game, scene, entity, field_name, field_data, parent_x, parent_y, parent_ctx, ready_queue, ref_ctx);
            }
        }

        /// Add prefab components with scene overrides merged in.
        /// For each component in prefab_components:
        ///   - If scene_components has the same component, merge the two
        ///   - Otherwise, use prefab component as-is
        pub fn addMergedPrefabComponents(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime prefab_components: anytype,
            comptime scene_components: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
            ref_ctx: ?*loader_types.ReferenceContext,
        ) !void {
            const prefab_fields = comptime std.meta.fieldNames(@TypeOf(prefab_components));

            inline for (prefab_fields) |field_name| {
                // Skip Position - already handled
                if (comptime std.mem.eql(u8, field_name, "Position")) continue;

                const prefab_data = @field(prefab_components, field_name);

                if (@hasField(@TypeOf(scene_components), field_name)) {
                    // Merge prefab + scene override
                    const scene_data = @field(scene_components, field_name);
                    const merged_data = zon.mergeStructs(prefab_data, scene_data);
                    try addComponentWithNestedEntities(game, scene, entity, field_name, merged_data, parent_x, parent_y, parent_ctx, ready_queue, ref_ctx);
                } else {
                    // Use prefab data as-is
                    try addComponentWithNestedEntities(game, scene, entity, field_name, prefab_data, parent_x, parent_y, parent_ctx, ready_queue, ref_ctx);
                }
            }
        }

        /// Add components that exist only in scene (not in prefab).
        pub fn addSceneOnlyComponents(
            game: *Game,
            scene: ?*Scene,
            entity: Entity,
            comptime prefab_components: anytype,
            comptime scene_components: anytype,
            parent_x: f32,
            parent_y: f32,
            parent_ctx: ?ParentContext,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
            ref_ctx: ?*loader_types.ReferenceContext,
        ) !void {
            const scene_fields = comptime std.meta.fieldNames(@TypeOf(scene_components));

            inline for (scene_fields) |field_name| {
                // Skip Position - already handled
                if (comptime std.mem.eql(u8, field_name, "Position")) continue;

                // Skip components that exist in prefab (already handled by addMergedPrefabComponents)
                if (@hasField(@TypeOf(prefab_components), field_name)) continue;

                const scene_data = @field(scene_components, field_name);
                try addComponentWithNestedEntities(game, scene, entity, field_name, scene_data, parent_x, parent_y, parent_ctx, ready_queue, ref_ctx);
            }
        }

        // =====================================================================
        // Gizmos
        // =====================================================================

        /// Create gizmo entities for debug visualization.
        /// Gizmos are only created in debug builds and are attached to a parent entity.
        /// Each gizmo entity gets a Gizmo marker component for visibility toggling.
        pub fn createGizmoEntities(
            game: *Game,
            scene: ?*Scene,
            parent_entity: Entity,
            comptime gizmos_data: anytype,
            parent_x: f32,
            parent_y: f32,
            ready_queue: *std.ArrayList(ReadyCallbackEntry),
        ) !void {
            // Only create gizmos in debug builds
            if (builtin.mode != .Debug) return;

            const gizmo_fields = @typeInfo(@TypeOf(gizmos_data)).@"struct".fields;

            // Process each gizmo definition (these are component definitions like Shape, Text, Sprite)
            inline for (gizmo_fields) |field| {
                const field_name = field.name;
                const gizmo_data = @field(gizmos_data, field_name);

                // Create a new entity for this gizmo
                const gizmo_entity = game.createEntity();

                // Get offset from the gizmo data's Position if present, otherwise use 0,0
                const offset_x: f32 = if (@hasField(@TypeOf(gizmo_data), "x")) gizmo_data.x else 0;
                const offset_y: f32 = if (@hasField(@TypeOf(gizmo_data), "y")) gizmo_data.y else 0;

                // Note: Gizmos don't need their own Position component.
                // The render pipeline resolves gizmo positions from parent_entity + offset at render time.

                // Add Gizmo marker component with parent reference and offset
                game.getRegistry().addComponent(gizmo_entity, render.Gizmo{
                    .parent_entity = parent_entity,
                    .offset_x = offset_x,
                    .offset_y = offset_y,
                });

                // Handle BoundingBox gizmos specially - they create a Shape from parent's visual bounds
                if (comptime std.mem.eql(u8, field_name, "BoundingBox")) {
                    // Create BoundingBox component from gizmo data using buildStruct (handles defaults)
                    const bbox = zon.buildStruct(render.BoundingBox, gizmo_data);

                    // Store BoundingBox component for reference
                    game.getRegistry().addComponent(gizmo_entity, bbox);

                    // Get parent entity's visual bounds and create Shape
                    if (game.getEntityVisualBounds(parent_entity)) |bounds| {
                        const shape = bbox.toShape(bounds.width, bounds.height);
                        game.getRegistry().addComponent(gizmo_entity, shape);
                    } else {
                        // Fallback to a small default shape if bounds unavailable
                        const shape = bbox.toShape(32, 32);
                        game.getRegistry().addComponent(gizmo_entity, shape);
                        std.log.warn("BoundingBox gizmo: could not get parent visual bounds, using default 32x32", .{});
                    }
                } else {
                    // Add the visual component (Shape, Text, Sprite, Icon)
                    try addComponentWithNestedEntities(game, scene, gizmo_entity, field_name, gizmo_data, parent_x + offset_x, parent_y + offset_y, no_parent, ready_queue, null);
                }

                // Track in scene for cleanup
                if (scene) |s| {
                    try s.addEntity(.{
                        .entity = gizmo_entity,
                        .visual_type = comptime getVisualTypeFromGizmo(field_name),
                        .prefab_name = null,
                        .onUpdate = null,
                        .onDestroy = null,
                    });
                }
            }
        }

        // =====================================================================
        // Helpers
        // =====================================================================

        /// Determine visual type from component definitions at compile time
        pub fn getVisualTypeFromComponents(comptime components: anytype) VisualType {
            // Priority: sprite > shape > text > none
            if (@hasField(@TypeOf(components), "Sprite")) return .sprite;
            if (@hasField(@TypeOf(components), "Shape")) return .shape;
            if (@hasField(@TypeOf(components), "Text")) return .text;
            return .none;
        }

        /// Determine visual type from prefab components at compile time
        pub fn getVisualTypeFromPrefab(comptime prefab_name: []const u8) VisualType {
            if (!Prefabs.hasComponents(prefab_name)) return .none;
            const components = Prefabs.getComponents(prefab_name);
            return getVisualTypeFromComponents(components);
        }

        /// Determine visual type from gizmo component name at compile time
        fn getVisualTypeFromGizmo(comptime comp_name: []const u8) VisualType {
            if (comptime std.mem.eql(u8, comp_name, "Sprite")) return .sprite;
            if (comptime std.mem.eql(u8, comp_name, "Shape")) return .shape;
            if (comptime std.mem.eql(u8, comp_name, "Text")) return .text;
            if (comptime std.mem.eql(u8, comp_name, "Icon")) return .sprite;
            if (comptime std.mem.eql(u8, comp_name, "BoundingBox")) return .shape;
            return .none;
        }

        /// Get position for a prefab entity: scene .components.Position overrides prefab .components.Position
        pub fn getPrefabPosition(comptime prefab_name: []const u8, comptime entity_def: anytype) Pos {
            // Scene-level Position takes precedence
            if (getPositionFromComponents(entity_def)) |pos| {
                return pos;
            }
            // Fall back to prefab's Position
            if (comptime Prefabs.hasComponents(prefab_name)) {
                const prefab_components = Prefabs.getComponents(prefab_name);
                if (@hasField(@TypeOf(prefab_components), "Position")) {
                    const p = prefab_components.Position;
                    return Pos{
                        .x = getFieldOrDefault(p, "x", @as(f32, 0)),
                        .y = getFieldOrDefault(p, "y", @as(f32, 0)),
                    };
                }
            }
            return Pos{ .x = 0, .y = 0 };
        }
    };
}
