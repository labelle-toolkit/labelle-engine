// ECS Interface - comptime struct abstraction for pluggable ECS backends
//
// This module defines a compile-time interface that abstracts the common operations
// needed from an ECS library. Users can configure which ECS backend to use via build options.
//
// The interface uses a comptime struct pattern to enforce that all backends implement
// the required methods with correct signatures at compile time.
//
// Supported backends:
// - zig_ecs (default): prime31/zig-ecs - A Zig port of EnTT
// - zflecs: zig-gamedev/zflecs - Zig bindings for flecs (high-performance C ECS)
//
// Usage:
//   const ecs = @import("ecs");
//   var registry = ecs.Registry.init(allocator);
//   const entity = registry.create();
//   registry.add(entity, MyComponent{ .value = 42 });
//   if (registry.tryGet(MyComponent, entity)) |comp| { ... }

const std = @import("std");
const build_options = @import("build_options");

/// ECS backend selection
pub const EcsBackend = build_options.@"build.EcsBackend";

/// The current ECS backend
pub const backend: EcsBackend = build_options.ecs_backend;

/// Comptime interface that all ECS backends must implement.
/// This provides compile-time verification of the backend contract.
pub fn EcsInterface(comptime Impl: type) type {
    // Compile-time verification of required types and methods
    comptime {
        if (!@hasDecl(Impl, "Entity")) {
            @compileError("ECS backend must declare Entity type");
        }
        if (!@hasDecl(Impl, "Registry")) {
            @compileError("ECS backend must declare Registry type");
        }

        // Verify Registry has required methods
        const R = Impl.Registry;
        if (!@hasDecl(R, "init")) @compileError("Registry must have init method");
        if (!@hasDecl(R, "deinit")) @compileError("Registry must have deinit method");
        if (!@hasDecl(R, "create")) @compileError("Registry must have create method");
        if (!@hasDecl(R, "destroy")) @compileError("Registry must have destroy method");
        if (!@hasDecl(R, "add")) @compileError("Registry must have add method");
        if (!@hasDecl(R, "tryGet")) @compileError("Registry must have tryGet method");
        if (!@hasDecl(R, "setComponent")) @compileError("Registry must have setComponent method");
        if (!@hasDecl(R, "remove")) @compileError("Registry must have remove method");
        if (!@hasDecl(R, "query")) @compileError("Registry must have query method");
    }

    return struct {
        pub const Entity = Impl.Entity;
        pub const Registry = Impl.Registry;

        /// Check if Entity type has an 'invalid' sentinel value
        pub const has_invalid = @hasDecl(Impl.Entity, "invalid");

        /// Check if Entity type has an 'eql' method
        pub const has_eql = @hasDecl(Impl.Entity, "eql");
    };
}

// Import the appropriate backend adapter
const BackendImpl = switch (backend) {
    .zig_ecs => @import("zig_ecs_adapter.zig"),
    .zflecs => @import("zflecs_adapter.zig"),
};

// Import query facade utilities
const query_facade = @import("query.zig");

// Apply the interface to verify the backend at compile time
const Interface = EcsInterface(BackendImpl);

/// Entity handle type - represents a unique entity in the ECS
/// Size varies by backend: zig_ecs uses 32-bit, zflecs uses 64-bit
pub const Entity = Interface.Entity;

/// Registry type - the main ECS container that manages entities and components
pub const Registry = Interface.Registry;

/// Query type for backend-agnostic iteration
/// Usage: var q = registry.query(.{ Position, Velocity });
pub const Query = BackendImpl.Query;

/// Separates component types into data (non-zero-sized) and tags (zero-sized)
pub const separateComponents = query_facade.separateComponents;

/// Size of entity ID in bytes (for interop with external systems)
pub const entity_size = @sizeOf(Entity);

/// Whether the Entity type has an 'invalid' sentinel value
pub const has_invalid_entity = Interface.has_invalid;

/// Whether the Entity type has an 'eql' method for comparison
pub const has_entity_eql = Interface.has_eql;

/// Get invalid entity if supported, otherwise returns error.NotImplemented
pub fn getInvalidEntity() error{NotImplemented}!Entity {
    if (comptime has_invalid_entity) {
        return Entity.invalid;
    }
    return error.NotImplemented;
}

/// Compare two entities for equality if supported
pub fn entityEql(a: Entity, b: Entity) error{NotImplemented}!bool {
    if (comptime has_entity_eql) {
        return a.eql(b);
    }
    return error.NotImplemented;
}

/// Register component lifecycle callbacks if the component type defines them.
/// Components can define these callbacks:
/// - `pub fn onAdd(payload: ComponentPayload) void` - called when component is added
/// - `pub fn onSet(payload: ComponentPayload) void` - called when component is updated via setComponent()
/// - `pub fn onRemove(payload: ComponentPayload) void` - called when component is removed
///
/// Note: Use registry.setComponent() to update components and trigger onSet.
/// Direct mutation via tryGet() pointers will NOT trigger onSet.
pub fn registerComponentCallbacks(registry: *Registry, comptime T: type) void {
    BackendImpl.registerComponentCallbacks(registry, T);
}

/// Set the global game pointer for component callbacks to access.
/// Pass null to clear the game pointer during cleanup.
///
/// If this is not called before a callback runs, the callback will log a warning
/// and its body will be skipped (no game pointer–dependent logic will execute).
///
/// In normal usage this is set automatically by `Game.fixPointers()`, so you
/// usually do not need to call this directly unless you are wiring a custom
/// game/registry setup.
pub fn setGamePtr(ptr: ?*anyopaque) void {
    BackendImpl.setGamePtr(ptr);
}

/// Get the global game pointer. Returns null if not set.
pub fn getGamePtr() ?*anyopaque {
    return BackendImpl.getGamePtr();
}

test "Entity interface availability" {
    // Just verify the comptime flags compile correctly
    _ = has_invalid_entity;
    _ = has_entity_eql;
}
