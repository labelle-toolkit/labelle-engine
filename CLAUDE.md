# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Run all tests (zspec BDD tests)
zig build test

# Run unit tests only
zig build unit-test

# Generate project files from project.labelle
zig build generate

# Run ECS performance benchmarks
zig build bench

# Run example projects (each has its own build.zig)
cd usage/example_1 && zig build run
cd usage/example_2 && zig build run
cd usage/example_3 && zig build run

# CI test mode (runs without window, exits immediately)
CI_TEST=1 zig build run  # in example directories

# Build with specific backend
zig build -Dbackend=sokol           # Use sokol graphics backend
zig build -Decs_backend=zflecs      # Use zflecs ECS backend
```

## Architecture

labelle-engine is a 2D game engine for Zig built on top of labelle-gfx (graphics) and pluggable ECS backends (zig_ecs or zflecs). It provides a declarative scene system using comptime .zon files.

### Core Modules (src/)

- **scene.zig** - Main module, re-exports all public types. Entry point for `@import("labelle-engine")`
- **game.zig** - `Game` facade providing high-level API: window init, entity management, scene transitions, game loop
- **render_pipeline.zig** - Bridges ECS components to RetainedEngine, handles dirty tracking and visual sync
- **loader.zig** - `SceneLoader` parses comptime .zon scene data, creates entities from prefabs or inline definitions
- **prefab.zig** - `Prefab` templates with sprite config and optional lifecycle hooks (onCreate/onUpdate/onDestroy)
- **component.zig** - `ComponentRegistry` maps component names to types for .zon scene loading
- **script.zig** - `ScriptRegistry` maps script names to update/init/deinit functions
- **generator.zig** - Generates build.zig, build.zig.zon, main.zig from project.labelle config using zts templates
- **project_config.zig** - Parses .labelle project files (ZON format)
- **ecs/** - ECS abstraction layer supporting multiple backends (zig_ecs, zflecs)

### Key Abstractions

**Registries** (comptime type maps):
```zig
const Prefabs = engine.PrefabRegistry(.{ player_prefab, enemy_prefab });
const Components = engine.ComponentRegistry(struct {
    pub const Health = health_comp.Health;
});
const Scripts = engine.ScriptRegistry(struct {
    pub const gravity = gravity_script;
});
const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
```

**Scene .zon format** (scenes/*.zon):
```zig
.{
    .name = "level1",
    .scripts = .{"gravity"},
    .entities = .{
        .{ .prefab = "player", .x = 400, .y = 300 },
        .{ .sprite = .{ .name = "coin.png", .x = 100 }, .components = .{ .Health = .{ .current = 50 } } },
        .{ .shape = .{ .type = .circle, .radius = 50, .color = .{ .r = 255 } } },
    },
}
```

**Prefab definition** (prefabs/*.zig):
```zig
pub const name = "player";
pub const sprite = engine.SpriteConfig{ .name = "idle", .x = 400, .y = 300 };
pub fn onCreate(entity: u64, game_ptr: *anyopaque) void { ... }  // optional
pub fn onUpdate(entity: u64, game_ptr: *anyopaque, dt: f32) void { ... }  // optional
pub fn onDestroy(entity: u64, game_ptr: *anyopaque) void { ... }  // optional
```

**Script definition** (scripts/*.zig):
```zig
pub fn init(game: *Game, scene: *Scene) void { ... }  // optional
pub fn update(game: *Game, scene: *Scene, dt: f32) void { ... }
pub fn deinit(game: *Game, scene: *Scene) void { ... }  // optional
```

**Project configuration** (project.labelle):
```zig
.{
    .version = 1,
    .name = "my_game",
    .initial_scene = "main_scene",
    .backend = .raylib,        // or .sokol
    .ecs_backend = .zig_ecs,   // or .zflecs
    .window = .{ .width = 800, .height = 600, .title = "My Game" },
}
```

### Graphics Backends

Supports raylib (default) and sokol backends, selected at build time:
```bash
zig build -Dbackend=sokol
```

The `RetainedEngine` type is selected based on backend via build_options.

### ECS Backends

Supports zig_ecs (default) and zflecs backends:
```bash
zig build -Decs_backend=zflecs
```

Both backends implement a common interface defined in `src/ecs/`.

### Project Generator

The `zig build generate` command reads `project.labelle` and scans prefabs/, components/, scripts/ folders to generate:
- build.zig.zon (dependencies)
- build.zig (build configuration)
- main.zig (wires up registries and game loop)

Uses zts templates from `src/templates/`.

### Entity Lifecycle

1. Scene loader creates entities via `Game.createEntity()`
2. Components added: Position, Sprite/Shape/Text, custom components
3. Visual tracked via `RenderPipeline.trackEntity()`
4. Prefab `onCreate()` hook called if defined
5. Each frame: scripts update components, `RenderPipeline.sync()` pushes dirty state to graphics
6. On destroy: prefab `onDestroy()` hook called, `RenderPipeline.untrackEntity()` removes visual

### Important Patterns

- Lifecycle hooks use `u64` for entity and `*anyopaque` for game to avoid circular imports
- Use `engine.entityFromU64()` and `engine.entityToU64()` for entity conversion in hooks
- `Game.fixPointers()` must be called after init when struct moves to final stack location
- Position changes require `pipeline.markPositionDirty(entity)` for sync to graphics
- Scripts support `init()` and `deinit()` lifecycle hooks for resource management
