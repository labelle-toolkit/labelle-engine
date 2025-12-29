# RFC 003: Component Lifecycle Callbacks

**Status**: Draft
**Created**: 2025-12-29

## Summary

Add a component lifecycle callback system where callbacks are defined directly on the component struct itself. The engine automatically detects and wires these callbacks across both ECS backends (zig-ecs and zflecs).

## Motivation

Currently, labelle-engine supports lifecycle hooks at two levels:
- **Engine hooks** (`entity_created`, `entity_destroyed`, etc.) - via the hook system
- **Prefab hooks** (`onCreate`, `onUpdate`, `onDestroy`) - per-prefab callbacks

However, there's no way to observe **component-level** lifecycle events. This is useful for:
- Reacting when a specific component is added to any entity (e.g., play a sound when `Health` is added)
- Cleaning up resources when a component is removed (e.g., release a texture reference)
- Implementing reactive systems that respond to component state changes
- Building debugging/profiling tools that track component usage

### ECS Backend Support

Both supported ECS backends have native callback mechanisms:

**zig-ecs (prime31/zig-ecs)**:
- Signal/Sink pattern ported from EnTT
- `onConstruct`, `onUpdate`, `onDestruct` events
- API: `registry.onConstruct(T).connect(callback)`

**zflecs (Flecs)**:
- Two systems: Component Hooks and Observers
- `on_add`, `on_set`, `on_remove` hooks
- Observers with `OnAdd`, `OnSet`, `OnRemove` events

The challenge is that users should not access the ECS directly - they interact through the Game facade. This RFC proposes callbacks defined directly on components, with the engine abstracting the ECS-specific wiring.

## Design

### Core Concepts

```
┌─────────────────────────────────────────────────────────────────────┐
│  Component Definition                                                │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ const Health = struct {                                         │ │
│  │     amount: i32 = 100,                                          │ │
│  │                                                                 │ │
│  │     pub fn onAdd(payload: ComponentPayload) void { ... }        │ │
│  │     pub fn onSet(payload: ComponentPayload) void { ... }        │ │
│  │     pub fn onRemove(payload: ComponentPayload) void { ... }     │ │
│  │ };                                                              │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                              │                                       │
│                              ▼                                       │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ ComponentRegistry (existing) - auto-detects callbacks           │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                              │                                       │
│                              ▼                                       │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │ ECS Adapter Layer                                               │ │
│  │ - zig_ecs: registry.onConstruct(T).connect(...)                 │ │
│  │ - zflecs: flecs.set_hooks(world, T, .{.on_add = ...})          │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 1. Callback Functions on Component Structs

Components define lifecycle callbacks as public functions directly on the struct:

```zig
const Health = struct {
    amount: i32 = 100,
    max: i32 = 100,

    /// Called when Health is added to an entity
    pub fn onAdd(payload: engine.ComponentPayload) void {
        std.log.info("Health added to entity {d}", .{payload.entity_id});
    }

    /// Called when Health value changes
    pub fn onSet(payload: engine.ComponentPayload) void {
        std.log.info("Health updated on entity {d}", .{payload.entity_id});
    }

    /// Called when Health is removed from an entity
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.info("Health removed from entity {d}", .{payload.entity_id});
    }
};
```

All three callbacks are optional - only define the ones you need.

### 2. Component Payload

Simple payload struct for component callbacks:

```zig
pub const ComponentPayload = struct {
    /// The entity ID (as u64 for backend compatibility).
    /// Use `engine.entityFromU64()` to convert to Entity type.
    entity_id: u64,
};
```

### 3. Optional: Component Helper for Boilerplate

For components that need common patterns, provide a comptime helper:

```zig
/// Creates a component struct with lifecycle callback support
pub fn Component(comptime Data: type, comptime Callbacks: type) type {
    return struct {
        // Embed all data fields
        usingnamespace Data;

        // Forward callback declarations if they exist
        pub usingnamespace if (@hasDecl(Callbacks, "onAdd"))
            struct { pub const onAdd = Callbacks.onAdd; }
        else
            struct {};

        pub usingnamespace if (@hasDecl(Callbacks, "onSet"))
            struct { pub const onSet = Callbacks.onSet; }
        else
            struct {};

        pub usingnamespace if (@hasDecl(Callbacks, "onRemove"))
            struct { pub const onRemove = Callbacks.onRemove; }
        else
            struct {};
    };
}

// Usage:
const Health = engine.Component(
    struct { amount: i32 = 100, max: i32 = 100 },
    struct {
        pub fn onAdd(payload: engine.ComponentPayload) void {
            // ...
        }
    },
);
```

This helper is optional - plain structs with callback functions work directly.

### 4. Automatic Detection in ComponentRegistry

The existing `ComponentRegistry` is extended to detect callbacks at comptime:

```zig
pub fn ComponentRegistry(comptime Components: type) type {
    return struct {
        // ... existing functionality ...

        /// Check if a component type has lifecycle callbacks
        pub fn hasCallbacks(comptime T: type) bool {
            return @hasDecl(T, "onAdd") or
                   @hasDecl(T, "onSet") or
                   @hasDecl(T, "onRemove");
        }

        /// Get list of component types that have callbacks
        pub fn componentsWithCallbacks() []const type {
            // Returns types that have any callback defined
        }
    };
}
```

### 5. ECS Adapter Integration

Each ECS adapter wires callbacks automatically when components are registered:

**zig_ecs_adapter.zig**:
```zig
pub fn registerComponentWithCallbacks(
    registry: *Registry,
    comptime T: type,
) void {
    if (@hasDecl(T, "onAdd")) {
        registry.inner.onConstruct(T).connect(makeCallback(T.onAdd));
    }
    if (@hasDecl(T, "onSet")) {
        registry.inner.onUpdate(T).connect(makeCallback(T.onSet));
    }
    if (@hasDecl(T, "onRemove")) {
        registry.inner.onDestruct(T).connect(makeCallback(T.onRemove));
    }
}

fn makeCallback(comptime callback: anytype) fn(*zig_ecs.Registry, zig_ecs.Entity) void {
    return struct {
        fn wrapper(_: *zig_ecs.Registry, entity: zig_ecs.Entity) void {
            callback(.{ .entity_id = @intFromEnum(entity) });
        }
    }.wrapper;
}
```

**zflecs_adapter.zig**:
```zig
pub fn registerComponentWithCallbacks(
    registry: *Registry,
    comptime T: type,
) void {
    var hooks = flecs.TypeHooksT(T){};

    if (@hasDecl(T, "onAdd")) {
        hooks.on_add = makeCallback(T, T.onAdd);
    }
    if (@hasDecl(T, "onSet")) {
        hooks.on_set = makeCallback(T, T.onSet);
    }
    if (@hasDecl(T, "onRemove")) {
        hooks.on_remove = makeCallback(T, T.onRemove);
    }

    flecs.set_hooks(registry.world, T, hooks);
}
```

### 6. Game Integration

The Game facade automatically registers callbacks for all components in the registry:

```zig
// In Game.init()
inline for (ComponentRegistry.types()) |T| {
    if (@hasDecl(T, "onAdd") or @hasDecl(T, "onSet") or @hasDecl(T, "onRemove")) {
        ecs_adapter.registerComponentWithCallbacks(&self.registry, T);
    }
}
```

## Usage Examples

### Basic Component with Callbacks

```zig
// components/health.zig
const std = @import("std");
const engine = @import("labelle-engine");

pub const Health = struct {
    amount: i32 = 100,
    max: i32 = 100,

    pub fn onAdd(payload: engine.ComponentPayload) void {
        std.log.info("[Health] Added to entity {d}", .{payload.entity_id});
    }

    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.info("[Health] Removed from entity {d}", .{payload.entity_id});
    }
};
```

### Component Without Callbacks

Components without callbacks work exactly as before - no changes needed:

```zig
// components/position.zig
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};
```

### Resource Cleanup Example

```zig
// components/texture_ref.zig
pub const TextureRef = struct {
    handle: u32,
    path: []const u8,

    pub fn onRemove(payload: engine.ComponentPayload) void {
        // Clean up texture reference when component is removed
        TextureManager.release(payload.entity_id);
    }
};
```

### Reactive System Example

```zig
// components/damage.zig
pub const Damage = struct {
    amount: i32,
    source_entity: u64,

    pub fn onAdd(payload: engine.ComponentPayload) void {
        // When Damage is added, apply it immediately
        // This creates a "message-like" component pattern
        applyDamage(payload.entity_id, @This());
    }
};
```

## Implementation Plan

### Phase 1: Core Types
1. Add `ComponentPayload` struct to `src/hooks/types.zig` (or new `src/component_callbacks.zig`)
2. Document callback function signatures (`onAdd`, `onSet`, `onRemove`)

### Phase 2: ECS Adapter Integration
1. Add `registerComponentWithCallbacks` to `zig_ecs_adapter.zig`
   - Wire `onAdd` → `onConstruct`
   - Wire `onSet` → `onUpdate`
   - Wire `onRemove` → `onDestruct`
2. Add `registerComponentWithCallbacks` to `zflecs_adapter.zig`
   - Wire `onAdd` → `on_add` hook
   - Wire `onSet` → `on_set` hook
   - Wire `onRemove` → `on_remove` hook
3. Implement callback wrappers that convert ECS-specific signatures to `ComponentPayload`

### Phase 3: Game Integration
1. Extend Game initialization to detect callbacks on registered components
2. Auto-wire callbacks for components that define them
3. Add tests for both ECS backends

### Phase 4: Optional Helper
1. Implement `engine.Component(Data, Callbacks)` helper (if deemed useful)
2. Add examples showing both plain structs and helper usage

### Phase 5: Documentation
1. Update CLAUDE.md with component callback usage
2. Create example in `usage/example_component_callbacks/`

## Design Decisions

1. **Callbacks on component struct**: Most natural place - the component defines its own behavior. No separate registry or configuration needed.

2. **Single callback per event**: Matches both ECS backends' native behavior. One `onAdd`, one `onSet`, one `onRemove` per component type.

3. **Global scope**: Callbacks fire for all entities with the component. Per-entity filtering can be done inside the callback if needed.

4. **Simple payload (entity_id only)**:
   - Callback receives entity ID
   - Handler can fetch the component value if needed via `game.getComponent(entity, T)`
   - Avoids complexity of passing component data with different lifetime semantics across backends

5. **Zero configuration**: If a component has `onAdd`/`onSet`/`onRemove` functions, they're automatically wired. No explicit registration step.

6. **Backward compatible**: Existing components without callbacks work unchanged.

## Alternatives Considered

### 1. Separate Callback Registry (Original Approach)
```zig
const ComponentCallbacks = engine.ComponentCallbackRegistry(.{
    .Health = HealthCallbacks,
});
```
- Separates data from behavior
- More boilerplate, harder to see component's full behavior

### 2. Runtime Registration API
```zig
game.onComponentAdd(Health, callback);
```
- More flexible but adds runtime overhead
- Harder to integrate with comptime ECS patterns
- Can't leverage comptime callback detection

### 3. Callbacks in Hooks Struct
```zig
const MyHooks = struct {
    pub const ComponentCallbacks = struct {
        pub const Health = HealthCallbacks;
    };
};
```
- Consistent with engine hooks pattern
- But callbacks are logically tied to components, not to game configuration

## Open Questions

1. **Should callbacks receive the component value?**
   - Pro: Convenient, no need to fetch
   - Con: Different ECS backends pass component data differently; adds complexity
   - Current decision: Start with entity_id only, can extend later

2. **`onSet` semantics across backends**:
   - zig-ecs: `onUpdate` fires on `replace()`
   - zflecs: `on_set` fires when value is set/changed
   - Need to document exact semantics and ensure consistency

3. **Should the helper `Component(Data, Callbacks)` be provided?**
   - Pro: Cleaner separation for complex components
   - Con: Plain structs with functions are simpler and work well
   - Current decision: Optional, implement if there's demand

## References

- RFC 001: Hook System
- zig-ecs Signal/Sink: https://github.com/prime31/zig-ecs
- Flecs Component Hooks: https://www.flecs.dev/flecs/md_docs_2EntitiesComponents.html
- Flecs Observers: https://www.flecs.dev/flecs/md_docs_2ObserversManual.html
- EnTT Signals: https://github.com/skypjack/entt/wiki/Crash-Course:-events,-signals-and-everything-in-between
