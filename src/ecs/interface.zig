// ECS Interface - comptime abstraction for pluggable ECS backends
//
// This module defines a compile-time interface that abstracts the common operations
// needed from an ECS library. Users can configure which ECS backend to use via build options.
//
// Supported backends:
// - zig_ecs (default): prime31/zig-ecs - A Zig port of EnTT
// - zcs: Games-by-Mason/ZCS - A Zig ECS library focused on simplicity
//
// Usage:
//   const ecs = @import("ecs/interface.zig");
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

// Import the appropriate backend adapter
const BackendAdapter = switch (backend) {
    .zig_ecs => @import("zig_ecs_adapter.zig"),
    .zcs => @import("zcs_adapter.zig"),
};

/// Entity handle type - represents a unique entity in the ECS
/// Must be the same size as u32 for bitcast compatibility with lifecycle hooks
pub const Entity = BackendAdapter.Entity;

/// Registry type - the main ECS container that manages entities and components
pub const Registry = BackendAdapter.Registry;

// Compile-time verification that Entity can be safely cast to u32
comptime {
    if (@sizeOf(Entity) != @sizeOf(u32)) {
        @compileError("Entity must be the same size as u32 for @bitCast in lifecycle hooks");
    }
}

test "Entity size compatibility" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Entity));
}
