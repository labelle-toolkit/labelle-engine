# RFC: Multiple ECS Worlds

## Problem Statement

The engine has a single `ecs_backend` instance. This limits three important workflows:

1. **Save/load**: Can't destroy all entities atomically — must iterate and remove components one by one, which is slow and error-prone.
2. **Scene transitions**: Can't pre-load a scene in a separate world while the current one runs.
3. **Isolation**: UI entities, debug entities, and game entities share one pool — accidental queries across boundaries are easy to introduce.

## Design

### Worlds are named ECS + Renderer pairs

Each world owns its own ECS backend instance **and** its own GfxRenderer instance. This is the cleanest isolation boundary because:

- Entity IDs are scoped per-world — no collision risk in the renderer's `AutoHashMap(u32, Entry)` maps.
- Destroying a world = `renderer.deinit()` + `ecs_backend.deinit()` — bulk cleanup with no per-entity iteration.
- Syncing only iterates the active world's tracked entities.

```zig
const World = struct {
    ecs_backend: EcsBackend,
    renderer: GfxRenderer,
    nested_entity_arena: ArenaAllocator,
};
```

The `Game` struct holds a map of worlds:

```zig
worlds: std.StringHashMap(World),
active_world: []const u8,
```

### Core API

```zig
// Create worlds
const game_world = game.createWorld("game");
const ui_world = game.createWorld("ui");

// Set active world (scripts and systems operate on this one)
game.setActiveWorld("game");

// Get active world's ECS (what scripts already use via game.ecs_backend)
game.ecs_backend; // returns active world's backend

// Destroy a world atomically
game.destroyWorld("game");

// Rename a world
game.renameWorld("loaded", "game");
```

### Impact on labelle-gfx

The renderer layer currently assumes a single flat entity namespace. Here is how multiple worlds interact with each gfx subsystem:

#### Entity ID isolation (critical)

`RetainedEngineWith` stores visuals in three `AutoHashMap(u32, Entry)` maps keyed by `EntityId`. If two worlds share one renderer, entity ID 42 from world A overwrites entity ID 42 from world B.

**Solution**: Each world gets its own `GfxRenderer` instance. The maps are completely independent — no namespacing or ID-prefixing needed.

```
World "game"  →  GfxRenderer instance A  →  RetainedEngine { sprites: {42: ..., 99: ...} }
World "ui"    →  GfxRenderer instance B  →  RetainedEngine { sprites: {42: ..., 7: ...} }
```

#### Dirty tracking & sync (performance win)

`GfxRenderer.sync()` iterates all entries in its `tracked` map every frame. With one renderer per world, sync naturally scopes to that world's entities. Only the active world (or explicitly rendered worlds) need syncing each frame.

```zig
// Only sync worlds that need rendering this frame
for (self.rendered_worlds) |world_name| {
    if (self.worlds.get(world_name)) |world| {
        world.renderer.sync(EcsImpl, &world.ecs_backend);
    }
}
```

#### World destruction → visual cleanup (free)

Currently, destroying N entities requires N calls to `untrackEntity()`. With per-world renderers:

```zig
pub fn destroyWorld(self: *Self, name: []const u8) void {
    const world = self.worlds.get(name).?;
    world.renderer.deinit();      // frees all visual maps at once
    world.ecs_backend.deinit();   // frees all entity storage at once
    world.nested_entity_arena.deinit();
    _ = self.worlds.remove(name);
}
```

No iteration. No per-entity cleanup. O(1) world teardown.

#### Cameras (no impact)

Cameras are managed by a single shared `CameraManager` and are **not tied to entities**. One `CameraManager` serves all worlds. UI layers use screen-space and bypass the camera entirely. Games that need per-world viewpoints can save/restore camera state manually on world swap.

#### Texture registry (no impact)

Textures are shared resources identified by `TextureId`. Multiple renderers referencing the same texture is fine — the backend (raylib/sokol/SDL2) handles texture lifetime independently.

#### Layer system (no impact)

Layers are comptime enums. No per-entity or per-world runtime state.

### Rendering multiple worlds

The render loop draws worlds in declaration order (or explicit priority):

```zig
pub fn render(self: *Self) void {
    // Background world layers first
    self.renderWorld("game");
    // UI world on top
    self.renderWorld("ui");
}
```

Each world's renderer draws its own visual maps. Layer sorting happens within each world. Cross-world ordering is controlled by render call order.

### Save/load use case

```zig
// Save: serialize active world
saveWorld(game.getWorld("game"));

// Load: create fresh world, populate, swap in
const new_world = game.createWorld("loaded");
populateFromSave(new_world, save_data);
game.destroyWorld("game");
game.renameWorld("loaded", "game");
game.setActiveWorld("game");
```

### Scene transitions

```zig
// Pre-load next scene in background world
const next = game.createWorld("next_level");
loadScene(next, "level_02.zon");

// When ready: crossfade or instant swap
game.destroyWorld("game");
game.renameWorld("next_level", "game");
game.setActiveWorld("game");
```

### User-created worlds

Games can create worlds for any purpose — staging, cutscenes, pre-loading, isolated simulations. All worlds are equal; the engine does not special-case any world name.

```zig
// Game developer creates worlds for their own needs
const cutscene = game.createWorld("cutscene");
loadScene(cutscene, "intro_cinematic.zon");

const staging = game.createWorld("staging");
// pre-load assets, build entity graph, then swap in when ready
```

## Impact on Plugins

### Principle: the plugin decides

The engine exposes the world map and the active world. It does **not** prescribe how plugins interact with worlds. Each plugin decides its own strategy based on its domain:

| Strategy | Example Plugin | How It Works |
|----------|---------------|--------------|
| Active world only | Pathfinding | Queries `game.ecs_backend` (active world). Ignores other worlds. No changes needed. |
| Specific world | UI plugin | Always operates on `game.getWorld("ui").ecs_backend`. Ignores active world. |
| All worlds | Debug inspector | Iterates `game.worlds()` to show entity counts, component stats per world. |
| Per-world tick | Physics | Game calls `plugin.tick(game, world_name)` for each world that needs physics. |

### What the engine provides to plugins

Plugins receive `game` on every callback. The new API they can use:

```zig
// Active world (default — backward compatible)
game.ecs_backend;           // active world's ECS
game.renderer;              // active world's renderer

// Explicit world access
game.getWorld("ui");        // returns World struct
game.getWorld("ui").ecs_backend;
game.worlds();              // iterator over all worlds

// World metadata
game.activeWorldName();     // "game", "ui", etc.
game.worldExists("staging");
```

Existing plugins that only use `game.ecs_backend` work unchanged — they operate on the active world.

### Plugin state and world lifecycle

- **ECS components**: Scoped to the world they belong to. Destroying a world destroys all plugin components in it. Correct by default.
- **Script State**: Created per-entity by ScriptRunner. Scoped to the world. Correct by default.
- **Module-level state** (global `var`s): Not world-scoped. A plugin caching entity IDs globally must handle `destroyWorld()` — those IDs become invalid. Plugins should either:
  - Store entity references as components (auto-cleaned on world destroy)
  - Listen to the `world_destroyed` hook to invalidate caches

### New hooks for plugins

```zig
// Plugins can react to world lifecycle
pub const WorldHooks = enum {
    world_created,      // payload: world name
    world_destroyed,    // payload: world name (fired before deinit)
    world_activated,    // payload: world name
};
```

This lets plugins with global state clean up when a world goes away, without requiring every plugin to be world-aware.

### UI as a dedicated world

A UI world is a natural pattern: UI entities don't interact with game entities, don't need physics, and render on screen-space layers. A dedicated UI plugin can always target `game.getWorld("ui")`:

```zig
// UI plugin
pub fn tick(game: anytype, dt: f32) void {
    const ui = game.getWorld("ui").ecs_backend;
    var view = ui.view(.{ Button, Hovered }, .{});
    // ...
}
```

This also means destroying and reloading the game world (save/load, scene transition) leaves UI intact — no re-creating health bars, inventory panels, etc.

## Implementation Plan

### Phase 1: Core reset (save/load unblock)

Add `resetEcsBackend()` to the Game struct — a single-line world reset without full multi-world infrastructure:

```zig
pub fn resetEcsBackend(self: *Self) void {
    self.renderer.deinit();
    self.ecs_backend.deinit();
    self.nested_entity_arena.deinit();
    self.renderer = GfxRenderer.init(self.allocator);
    self.ecs_backend = EcsBackend.init(self.allocator);
    self.nested_entity_arena = ArenaAllocator.init(self.allocator);
}
```

This destroys all entities and visuals atomically. No iteration. Unblocks save/load v2 immediately.

**Scope**: labelle-engine only. No gfx API changes.

### Phase 2: Named worlds

1. Add `World` struct wrapping `{ ecs_backend, renderer, nested_entity_arena }`
2. Replace single fields with `worlds: StringHashMap(World)` + `active_world: []const u8`
3. Add `createWorld()`, `destroyWorld()`, `setActiveWorld()`, `renameWorld()`
4. `game.ecs_backend` becomes a getter returning active world's backend
5. Update `game.tick()` to sync only rendered worlds
6. Update `game.render()` to draw worlds in order

**Scope**: labelle-engine restructure. labelle-gfx unchanged (just instantiated multiple times).

### Phase 3: Scene integration

1. `loadScene()` accepts an optional world name target
2. Scene transitions create a world, load into it, then swap
3. `.zon` scene files can declare which world they belong to

**Scope**: labelle-engine scene loader + CLI codegen.

## Backward Compatibility

- Games that don't use multiple worlds see no API change. The engine creates a default `"main"` world at init.
- `game.ecs_backend` continues to work — returns the active (and only) world's backend.
- `game.renderer` continues to work — returns the active world's renderer.
- Phase 1 (`resetEcsBackend`) is purely additive.
- Existing scenes load into the default world.

## Decisions

1. **Non-active worlds do not tick.** Only the active world runs scripts and systems. Plugins that need to operate on other worlds must do so explicitly.
2. **No cross-world entity references.** Worlds are fully isolated. No world-qualified entity handles.
3. **World render ordering is explicit.** Games control render order by calling `renderWorld()` in the desired sequence (e.g. game world first, UI world on top).
4. **No memory budget limit.** No configurable cap on concurrent worlds for now.
