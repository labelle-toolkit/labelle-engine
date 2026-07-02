// Component Registry — maps .zon field names to Zig types
//
// Ported from v1 scene/src/component.zig

const std = @import("std");

// ─── Two-tier component visibility (Packs · #652) ───────────────────────────
//
// A component declares whether it is shared across all packs or private to the
// pack that owns it, mirroring how save behavior is declared via a `pub const`
// on the component itself (see labelle-core `save_policy.zig`):
//
//   pub const Locked = struct {
//       pub const visibility = .global; // any pack may name this component
//       by: u64 = 0,
//   };
//
//   pub const Worker = struct {
//       // no `visibility` decl → defaults to `.pack` (private to the owner)
//       hunger: f32 = 0,
//   };
//
// Visibility is a *name-resolution* concern only. Storage is unchanged: every
// component still lives in the one shared ECS backend, and the full/global
// registry (used by the serializer + ECS) still resolves every name. Visibility
// constrains the per-pack *view* produced by `PackView` / `ComponentView`.

/// Whether a component name is resolvable from every pack or only its owner.
pub const Visibility = enum {
    /// Shared registry — any pack may name this component (contract facets like
    /// `Locked`, engine primitives like `Position`).
    global,
    /// Private to the pack that owns it. Foreign packs cannot name it; the name
    /// misses at comptime in their partitioned view. This is the default.
    pack,
};

/// Read a component's declared visibility, defaulting to `.pack` (private).
///
/// Supports the canonical `pub const visibility = .global;` (enum literal) and
/// the explicitly-typed `pub const visibility: Visibility = .global;`.
pub fn getVisibility(comptime T: type) Visibility {
    if (@typeInfo(T) != .@"struct" and @typeInfo(T) != .@"union" and @typeInfo(T) != .@"enum") {
        return .pack;
    }
    if (@hasDecl(T, "visibility")) {
        const v: Visibility = @field(T, "visibility");
        return v;
    }
    return .pack;
}

/// True when the component is shared across all packs.
pub fn isGlobal(comptime T: type) bool {
    return getVisibility(T) == .global;
}

/// Comptime component registry — maps .zon field names to Zig types.
///
/// Usage:
///   const Components = ComponentRegistry(.{
///       .Health = Health,
///       .Velocity = Velocity,
///   });
///
/// Built-in components (Position, Sprite, Shape) are handled automatically
/// by the scene loader and don't need to be registered here.
pub fn ComponentRegistry(comptime component_map: anytype) type {
    return struct {
        pub fn has(comptime name: []const u8) bool {
            return @hasField(@TypeOf(component_map), name);
        }

        pub fn getType(comptime name: []const u8) type {
            return @field(component_map, name);
        }

        pub fn names() []const []const u8 {
            comptime {
                const fields = @typeInfo(@TypeOf(component_map)).@"struct".fields;
                var result: [fields.len][]const u8 = undefined;
                for (fields, 0..) |f, i| {
                    result[i] = f.name;
                }
                return &result;
            }
        }

        pub fn entityHasNamed(ecs: anytype, entity: anytype, comptime name: []const u8) bool {
            const T = getType(name);
            return ecs.hasComponent(entity, T);
        }
    };
}

/// Multi-source component registry — searches multiple maps in order.
///
/// Usage:
///   const Components = ComponentRegistryMulti(.{
///       .{ .Health = Health, .Speed = Speed },
///       plugin_foo.Components,
///   });
///
/// Field names are the component names, so pack-composed games namespace
/// them as `<pack>__<Pascal>` (e.g. `citizens__Worker`). `names()` returns
/// the deduplicated union of every map's field names in map order (first
/// occurrence wins, matching `getType`'s resolution), giving the same flat
/// name list a single-source registry provides — so `PackView` / `globalNames`
/// work on the multi-registry too.
pub fn ComponentRegistryMulti(comptime component_maps: anytype) type {
    const maps_info = @typeInfo(@TypeOf(component_maps));

    return struct {
        pub fn has(comptime name: []const u8) bool {
            inline for (maps_info.@"struct".fields) |field| {
                const Map = @field(component_maps, field.name);
                if (@hasField(@TypeOf(Map), name)) return true;
            }
            return false;
        }

        pub fn getType(comptime name: []const u8) type {
            inline for (maps_info.@"struct".fields) |field| {
                const Map = @field(component_maps, field.name);
                if (@hasField(@TypeOf(Map), name)) {
                    return @field(Map, name);
                }
            }
            @compileError("Unknown component: " ++ name);
        }

        /// True when `name` is a field of a map that comes *before* map index
        /// `up_to` — i.e. an earlier map already owns this name. Field names are
        /// unique within a single map, so an earlier hit is the only way a name
        /// can be a duplicate.
        fn nameInEarlierMap(comptime up_to: usize, comptime name: []const u8) bool {
            inline for (maps_info.@"struct".fields, 0..) |field, mi| {
                if (mi >= up_to) break;
                const Map = @field(component_maps, field.name);
                if (@hasField(@TypeOf(Map), name)) return true;
            }
            return false;
        }

        /// The deduplicated union of every map's field names, in map order
        /// (first occurrence wins — the same order `getType` resolves). Backed
        /// by a container-scoped const so the slice has static storage and is
        /// valid when `names()` is called at runtime.
        const _names = blk: {
            // First pass: count the unique names.
            var count: usize = 0;
            for (maps_info.@"struct".fields, 0..) |field, mi| {
                const Map = @field(component_maps, field.name);
                for (@typeInfo(@TypeOf(Map)).@"struct".fields) |f| {
                    if (!nameInEarlierMap(mi, f.name)) count += 1;
                }
            }

            // Second pass: collect them.
            var buf: [count][]const u8 = undefined;
            var idx: usize = 0;
            for (maps_info.@"struct".fields, 0..) |field, mi| {
                const Map = @field(component_maps, field.name);
                for (@typeInfo(@TypeOf(Map)).@"struct".fields) |f| {
                    if (!nameInEarlierMap(mi, f.name)) {
                        buf[idx] = f.name;
                        idx += 1;
                    }
                }
            }

            const final = buf;
            break :blk final;
        };

        /// Returns a comptime-built slice of every registered component name
        /// across all composed maps, deduplicated, in map order.
        pub fn names() []const []const u8 {
            return &_names;
        }

        /// Check if an entity has a named component (runtime name, comptime dispatch).
        pub fn entityHasNamed(ecs: anytype, entity: anytype, comptime name: []const u8) bool {
            const T = getType(name);
            return ecs.hasComponent(entity, T);
        }
    };
}

/// Component registry with automatic plugin component discovery.
///
/// Game-local components (field-based struct) take precedence over plugin
/// components. Plugin modules are checked for a `Components` declaration
/// whose public declarations are registered automatically.
///
/// Usage:
///   const Components = ComponentRegistryWithPlugins(
///       .{ .Health = Health, .Velocity = Velocity },
///       .{ @import("pathfinding"), @import("labelle-gfx") },
///   );
pub fn ComponentRegistryWithPlugins(comptime local_map: anytype, comptime plugin_modules: anytype) type {
    const plugins_info = @typeInfo(@TypeOf(plugin_modules));

    return struct {
        pub fn has(comptime name: []const u8) bool {
            if (@hasField(@TypeOf(local_map), name)) return true;
            inline for (plugins_info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Components")) {
                    if (@hasDecl(@field(mod, "Components"), name)) return true;
                }
            }
            return false;
        }

        pub fn getType(comptime name: []const u8) type {
            if (@hasField(@TypeOf(local_map), name)) {
                return @field(local_map, name);
            }
            inline for (plugins_info.@"struct".fields) |field| {
                const mod = @field(plugin_modules, field.name);
                if (@hasDecl(mod, "Components")) {
                    const Comps = @field(mod, "Components");
                    if (@hasDecl(Comps, name)) {
                        return @field(Comps, name);
                    }
                }
            }
            @compileError("Unknown component: " ++ name);
        }

        /// Returns a comptime slice of all registered component names.
        pub fn names() []const []const u8 {
            comptime {
                var count: usize = 0;

                // Count local components
                for (@typeInfo(@TypeOf(local_map)).@"struct".fields) |_| {
                    count += 1;
                }

                // Count plugin components (skip duplicates with local)
                for (plugins_info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "Components")) {
                        const Comps = @field(mod, "Components");
                        for (@typeInfo(Comps).@"struct".decls) |decl| {
                            if (!@hasField(@TypeOf(local_map), decl.name)) {
                                count += 1;
                            }
                        }
                    }
                }

                var result: [count][]const u8 = undefined;
                var idx: usize = 0;

                for (@typeInfo(@TypeOf(local_map)).@"struct".fields) |f| {
                    result[idx] = f.name;
                    idx += 1;
                }

                for (plugins_info.@"struct".fields) |field| {
                    const mod = @field(plugin_modules, field.name);
                    if (@hasDecl(mod, "Components")) {
                        const Comps = @field(mod, "Components");
                        for (@typeInfo(Comps).@"struct".decls) |decl| {
                            if (!@hasField(@TypeOf(local_map), decl.name)) {
                                result[idx] = decl.name;
                                idx += 1;
                            }
                        }
                    }
                }

                return &result;
            }
        }

        /// Check if an entity has a named component (runtime name, comptime dispatch).
        /// Returns true if the entity has the component matching the given name.
        pub fn entityHasNamed(ecs: anytype, entity: anytype, comptime name: []const u8) bool {
            const T = getType(name);
            return ecs.hasComponent(entity, T);
        }
    };
}

// ─── Per-pack registry partition (Packs · #652) ─────────────────────────────
//
// `ComponentView` is a restricted *view* over an existing registry. It resolves
// ONLY an allow-list of names; every other name — including a foreign pack's
// private component — misses at comptime. This closes the string-escape hole:
// a script that calls `getType("citizens__Worker")` or
// `entityHasNamed(ecs, e, "citizens__Worker")` on a foreign-private name now
// fails to compile instead of silently reaching into another pack's data.
//
// The view delegates resolution to `FullRegistry` (any
// `ComponentRegistry` / `ComponentRegistryWithPlugins`), so storage and the
// global serializer registry are untouched — this is purely a name→type lens.

/// Comptime membership test for an allow-list of component names.
fn nameAllowed(comptime allowed_names: []const []const u8, comptime name: []const u8) bool {
    inline for (allowed_names) |allowed| {
        if (comptime std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

/// A restricted registry view that resolves only `allowed_names`.
///
/// `FullRegistry` must expose `has`, `getType`, `names` (the shape of
/// `ComponentRegistry` / `ComponentRegistryWithPlugins`).
///
///   - `has(name)`  → true only if the name is allowed AND known to FullRegistry
///   - `getType(name)` → the type for an allowed name; **compile error** for a
///                       disallowed name (the comptime miss / escape closure)
///   - `entityHasNamed(...)` → dispatches through `getType`, so a disallowed
///                       name is a compile error here too
///   - `names()`    → the allowed names that actually exist in FullRegistry
pub fn ComponentView(comptime FullRegistry: type, comptime allowed_names: []const []const u8) type {
    return struct {
        /// The names this view is permitted to resolve.
        pub const allowed = allowed_names;

        /// Whether `name` is in this view's allow-list (independent of whether
        /// FullRegistry actually defines it).
        pub fn isAllowed(comptime name: []const u8) bool {
            return nameAllowed(allowed_names, name);
        }

        pub fn has(comptime name: []const u8) bool {
            return isAllowed(name) and FullRegistry.has(name);
        }

        pub fn getType(comptime name: []const u8) type {
            if (!isAllowed(name)) {
                @compileError("Component '" ++ name ++ "' is not visible to this pack " ++
                    "(foreign-private or unknown). Only `.global` components and the " ++
                    "pack's own components are resolvable.");
            }
            return FullRegistry.getType(name);
        }

        /// The allowed names that are actually defined in FullRegistry.
        /// Backed by a container-scoped const so the slice has static storage
        /// and is valid when `names()` is called at runtime.
        const _names = blk: {
            var buf: [allowed_names.len][]const u8 = undefined;
            var n: usize = 0;
            for (allowed_names) |name| {
                if (FullRegistry.has(name)) {
                    buf[n] = name;
                    n += 1;
                }
            }
            const final = buf[0..n].*;
            break :blk final;
        };

        pub fn names() []const []const u8 {
            return &_names;
        }

        /// Check if an entity has a named component (runtime name, comptime
        /// dispatch). Compile error if `name` is not visible to this view.
        pub fn entityHasNamed(ecs: anytype, entity: anytype, comptime name: []const u8) bool {
            const T = getType(name);
            return ecs.hasComponent(entity, T);
        }
    };
}

/// Comptime list of every `.global` component name in `FullRegistry`.
///
/// Iterates `FullRegistry.names()` and keeps the ones whose type declares
/// `visibility == .global`. These are the names visible to *every* pack.
pub fn globalNames(comptime FullRegistry: type) []const []const u8 {
    comptime {
        if (!@hasDecl(FullRegistry, "names")) {
            @compileError("PackView/globalNames require a registry type that exposes " ++
                "names() — every built-in registry (ComponentRegistry, " ++
                "ComponentRegistryMulti, ComponentRegistryWithPlugins) does.");
        }
    }
    // A struct nested in a generic fn is memoized per `FullRegistry`, giving
    // the computed list static storage so the slice survives a runtime call.
    const Holder = struct {
        const list = blk: {
            const all = FullRegistry.names();
            var buf: [all.len][]const u8 = undefined;
            var n: usize = 0;
            for (all) |name| {
                if (isGlobal(FullRegistry.getType(name))) {
                    buf[n] = name;
                    n += 1;
                }
            }
            const final = buf[0..n].*;
            break :blk final;
        };
    };
    return &Holder.list;
}

/// Build a per-pack view: the pack resolves all `.global` components of
/// `FullRegistry` plus the explicit list of its own (private) component names.
/// Foreign-private names are absent from the allow-list and therefore miss at
/// comptime, per the Packs isolation model.
///
///   const Citizens = PackView(FullRegistry, &.{ "Worker", "Home" });
///   _ = Citizens.getType("Worker");  // ok (own)
///   _ = Citizens.getType("Locked");  // ok (global facet)
///   _ = Citizens.getType("Ship");    // compile error (foreign-private)
pub fn PackView(comptime FullRegistry: type, comptime own_names: []const []const u8) type {
    // A struct nested in a generic fn is memoized per (FullRegistry, own_names),
    // giving the allow-list static storage — never return `&local` from a
    // comptime block, whose temporary array goes out of scope with the block.
    const Holder = struct {
        const allowed = blk: {
            const globals = globalNames(FullRegistry);
            var buf: [globals.len + own_names.len][]const u8 = undefined;
            var n: usize = 0;
            for (globals) |name| {
                buf[n] = name;
                n += 1;
            }
            for (own_names) |name| {
                // Skip a duplicate if the pack lists a name that is already global.
                if (!nameAllowed(globals, name)) {
                    buf[n] = name;
                    n += 1;
                }
            }
            const result = buf[0..n].*;
            break :blk result;
        };
    };
    return ComponentView(FullRegistry, &Holder.allowed);
}
