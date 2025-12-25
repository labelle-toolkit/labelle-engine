# RFC 001: Hook System for labelle-engine

**Status**: Draft
**Created**: 2025-12-24

## Summary

Add a type-safe hook/event system to labelle-engine that allows:
1. Games to register callbacks for engine lifecycle events
2. Plugins (like labelle-tasks) to define and emit custom hooks
3. Games to subscribe to plugin hooks

## Motivation

Currently, labelle-engine has scattered callback patterns:
- `SceneHooks` (onLoad/onUnload) in game.zig
- `EntityInstance` hooks (onUpdate/onDestroy) in scene.zig
- `ScriptFns` lifecycle (init/update/deinit) in script.zig
- labelle-tasks uses its own callback system (FindBestWorkerFn, OnStepStartedFn, etc.)

A unified hook system would:
- Provide consistent API across engine and plugins
- Enable type-safe enum-based event dispatch
- Allow plugins to define extensible hook points
- Reduce boilerplate for common patterns

## Design

### Core Concepts

```
┌─────────────────────────────────────────────────────────────┐
│                         Game                                 │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │ HookRegistry    │  │ PluginHooks     │                   │
│  │ (engine events) │  │ (plugin events) │                   │
│  └────────┬────────┘  └────────┬────────┘                   │
│           │                    │                             │
│           ▼                    ▼                             │
│  ┌─────────────────────────────────────────┐                │
│  │            HookDispatcher               │                │
│  │  - register(hook, callback)             │                │
│  │  - emit(hook, payload)                  │                │
│  └─────────────────────────────────────────┘                │
└─────────────────────────────────────────────────────────────┘
```

### 1. Engine Hook Enum

Built-in hooks for engine lifecycle events:

```zig
pub const EngineHook = enum {
    // Game lifecycle
    game_init,
    game_deinit,
    frame_start,
    frame_end,

    // Scene lifecycle
    scene_load,
    scene_unload,
    scene_update,

    // Entity lifecycle
    entity_created,
    entity_destroyed,

    // Input events
    input_key_pressed,
    input_key_released,

    // Rendering
    render_begin,
    render_end,
};
```

### 2. Hook Payload

Type-safe payload for each hook type:

```zig
pub const HookPayload = union(EngineHook) {
    game_init: void,
    game_deinit: void,
    frame_start: FrameInfo,
    frame_end: FrameInfo,

    scene_load: SceneInfo,
    scene_unload: SceneInfo,
    scene_update: struct { scene: *Scene, dt: f32 },

    entity_created: EntityInfo,
    entity_destroyed: EntityInfo,

    input_key_pressed: KeyInfo,
    input_key_released: KeyInfo,

    render_begin: void,
    render_end: void,
};

pub const FrameInfo = struct {
    frame_number: u64,
    dt: f32,
};

pub const SceneInfo = struct {
    name: []const u8,
    scene: *Scene,
};

pub const EntityInfo = struct {
    entity: Entity,
    prefab_name: ?[]const u8,
};

pub const KeyInfo = struct {
    key: Key,
    modifiers: Modifiers,
};
```

### 3. Hook Registry (Comptime)

Similar to existing registries, define hooks at compile time:

```zig
// In game's main.zig
const Hooks = engine.HookRegistry(struct {
    // Engine hooks
    pub const on_scene_load = onSceneLoad;
    pub const on_entity_created = onEntityCreated;

    // Plugin hooks (from labelle-tasks)
    pub const on_step_completed = tasks.onStepCompleted;
    pub const on_worker_released = tasks.onWorkerReleased;
});

fn onSceneLoad(game: *Game, info: SceneInfo) void {
    // Handle scene load
}

fn onEntityCreated(game: *Game, info: EntityInfo) void {
    // Handle entity creation
}
```

### 4. Plugin Hook Definition

Plugins define their own hook enums:

```zig
// In labelle-tasks/hooks.zig
pub const TasksHook = enum {
    step_started,
    step_completed,
    worker_assigned,
    worker_released,
    workstation_blocked,
    workstation_activated,
    cycle_completed,
};

pub const TasksPayload = union(TasksHook) {
    step_started: StepInfo,
    step_completed: StepInfo,
    worker_assigned: WorkerAssignment,
    worker_released: WorkerInfo,
    workstation_blocked: WorkstationInfo,
    workstation_activated: WorkstationInfo,
    cycle_completed: CycleInfo,
};
```

### 5. Comptime Hook Dispatcher

Zero-overhead hook dispatch via comptime:

```zig
/// Creates a hook dispatcher from a comptime hook map.
/// Each field in HookMap should be a function matching the expected signature for that hook.
pub fn HookDispatcher(comptime HookEnum: type, comptime PayloadUnion: type, comptime HookMap: type) type {
    return struct {
        /// Emit a hook event. Resolved entirely at comptime - no runtime overhead.
        pub inline fn emit(game: *Game, payload: PayloadUnion) void {
            const hook = std.meta.activeTag(payload);
            inline for (std.meta.fields(HookMap)) |field| {
                if (comptime std.mem.eql(u8, field.name, @tagName(hook))) {
                    const handler = @field(HookMap, field.name);
                    handler(game, payload);
                    return;
                }
            }
            // No handler registered for this hook - that's fine
        }

        /// Check at comptime if a hook has a handler registered.
        pub fn hasHandler(comptime hook: HookEnum) bool {
            return @hasDecl(HookMap, @tagName(hook));
        }
    };
}
```

### 6. Integration with Existing Systems

#### Scene Hooks Migration
```zig
// Before (game.zig)
pub const SceneHooks = struct {
    onLoad: ?*const fn (*Game) void = null,
    onUnload: ?*const fn (*Game) void = null,
};

// After - use hook system
game.hooks.emit(.scene_load, .{ .name = scene_name, .scene = scene });
```

#### Entity Lifecycle Migration
```zig
// Before (scene.zig EntityInstance)
onUpdate: ?*const fn (u64, *anyopaque, f32) void = null,
onDestroy: ?*const fn (u64, *anyopaque) void = null,

// After - emit hooks
game.hooks.emit(.entity_created, .{ .entity = entity, .prefab_name = prefab });
game.hooks.emit(.entity_destroyed, .{ .entity = entity, .prefab_name = prefab });
```

## Usage Examples

### Basic Game Hook Registration

```zig
// main.zig
const engine = @import("labelle-engine");

pub fn main() !void {
    var game = try engine.Game.init(allocator, config);
    defer game.deinit();

    // Register hooks
    game.hooks.register(.scene_load, onSceneLoad);
    game.hooks.register(.entity_created, onEntityCreated);
    game.hooks.register(.frame_end, onFrameEnd);

    try game.run();
}

fn onSceneLoad(game: *engine.Game, info: engine.SceneInfo) void {
    std.log.info("Scene loaded: {s}", .{info.name});
}

fn onEntityCreated(game: *engine.Game, info: engine.EntityInfo) void {
    if (info.prefab_name) |name| {
        std.log.info("Entity created from prefab: {s}", .{name});
    }
}

fn onFrameEnd(game: *engine.Game, info: engine.FrameInfo) void {
    // Analytics, debug overlay, etc.
}
```

### Plugin Integration (labelle-tasks)

```zig
// main.zig with labelle-tasks
const engine = @import("labelle-engine");
const tasks = @import("labelle-tasks");

pub fn main() !void {
    var game = try engine.Game.init(allocator, config);
    defer game.deinit();

    // Initialize tasks plugin
    var task_engine = tasks.Engine.init(allocator, .{
        // Connect task hooks to game hooks
        .hooks = game.createPluginHooks(tasks.TasksHook, tasks.TasksPayload),
    });

    // Game subscribes to task events
    task_engine.hooks.register(.step_completed, onStepCompleted);
    task_engine.hooks.register(.worker_released, onWorkerReleased);

    try game.run();
}

fn onStepCompleted(game: *engine.Game, info: tasks.StepInfo) void {
    // Play completion sound, update UI, etc.
    game.audio.play("step_complete.wav");
}

fn onWorkerReleased(game: *engine.Game, info: tasks.WorkerInfo) void {
    // Update worker sprite animation
    if (game.getRegistry().tryGet(Sprite, info.entity)) |sprite| {
        sprite.animation = .idle;
    }
}
```

### Comptime Hook Registry (Zero-Overhead)

```zig
// For maximum performance, use comptime registration
const Hooks = engine.HookRegistry(struct {
    pub fn on_scene_load(game: *Game, info: SceneInfo) void {
        // Inlined at compile time
    }

    pub fn on_frame_end(game: *Game, info: FrameInfo) void {
        // Inlined at compile time
    }
});

// In Game initialization
const Game = engine.GameWith(Hooks);
```

## Implementation Plan

### Phase 1: Core Hook Infrastructure
1. Create `src/hooks.zig` with:
   - `EngineHook` enum (game_init, game_deinit, scene_load, scene_unload, entity_created, entity_destroyed, frame_start, frame_end)
   - `HookPayload` tagged union with payload types for each hook
   - `HookDispatcher` comptime generic type
   - Payload structs (FrameInfo, SceneInfo, EntityInfo)

2. Create `src/hooks/` directory structure:
   - `src/hooks/types.zig` - Core types and enums
   - `src/hooks/dispatcher.zig` - HookDispatcher implementation
   - `src/hooks/payloads.zig` - Payload struct definitions

### Phase 2: Engine Integration
1. Add `HookRegistry` type parameter to Game:
   ```zig
   pub fn GameWith(comptime Hooks: type) type { ... }
   pub const Game = GameWith(struct {}); // Default: no hooks
   ```

2. Add emit points in game.zig:
   - `game_init` after initialization
   - `game_deinit` before cleanup
   - `frame_start` at beginning of frame
   - `frame_end` at end of frame
   - `scene_load` after scene loads
   - `scene_unload` before scene unloads

3. Add emit points in scene.zig:
   - `entity_created` when entity is added to scene
   - `entity_destroyed` when entity is removed

### Phase 3: Plugin Hook Pattern
1. Document pattern for plugins to define their own hooks:
   ```zig
   // In plugin: define hook enum and payloads
   pub const MyPluginHook = enum { ... };
   pub const MyPluginPayload = union(MyPluginHook) { ... };

   // Game creates dispatcher for plugin hooks
   const PluginHooks = hooks.HookDispatcher(
       MyPluginHook,
       MyPluginPayload,
       MyHandlers
   );
   ```

2. Add example showing labelle-tasks integration pattern

### Phase 4: Testing & Documentation
1. Create `test/hooks_test.zig` with tests for:
   - Hook dispatch with handlers
   - Hook dispatch without handlers (no-op)
   - Multiple hooks in same HookMap
   - Payload data correctness

2. Add documentation in CLAUDE.md for hook system usage

## Files to Create/Modify

### New Files
- `src/hooks.zig` - Main module, re-exports all hook types
- `src/hooks/types.zig` - EngineHook enum, HookPayload union
- `src/hooks/dispatcher.zig` - HookDispatcher comptime generic
- `src/hooks/payloads.zig` - FrameInfo, SceneInfo, EntityInfo structs
- `test/hooks_test.zig` - Hook system tests

### Modified Files
- `src/game.zig` - Add GameWith(Hooks) parameterization, emit lifecycle hooks
- `src/scene.zig` - Emit entity_created/entity_destroyed hooks
- `src/scene.zig` (module entry) - Re-export hook types
- `CLAUDE.md` - Document hook system usage

## Design Decisions

1. **Comptime Registration**: Prioritize comptime hooks for zero overhead. Hooks are defined at compile time and inlined, matching existing registry patterns (ComponentRegistry, ScriptRegistry, PrefabRegistry).

2. **No Cancellation**: Hooks are purely observational - they react to events but cannot prevent or modify them. This keeps the system simple and predictable.

3. **Separate Dispatchers**: Each plugin has its own HookDispatcher. Games subscribe to each plugin's hooks separately. This provides clear namespacing and avoids coordination issues.

4. **No Priority/Async**: Keep initial implementation simple. Priority ordering and async hooks can be added later if needed.

## Alternatives Considered

### 1. Signal/Slot Pattern
- More traditional but requires more boilerplate
- Harder to make type-safe in Zig

### 2. Observer Pattern with Interfaces
- Zig doesn't have interfaces, would require vtables
- More runtime overhead

### 3. Keep Current Scattered Callbacks
- Works but inconsistent API
- Harder for plugins to integrate

## References

- Current labelle-engine patterns: `src/script.zig`, `src/scene.zig`
- labelle-tasks callbacks: `labelle-tasks/src/engine.zig`
- labelle-gui plugin pattern: `labelle-gui/spikes/05-dynamic-imgui/`
