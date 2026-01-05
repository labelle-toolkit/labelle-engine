# labelle-engine

A declarative 2D game engine for Zig with comptime scene definitions and pluggable backends.

## Features

- **Declarative Scenes** - Define game scenes using `.zon` files at compile time
- **Entity Component System** - Pluggable ECS with support for zig_ecs and zflecs backends
- **Prefab System** - Reusable entity templates with lifecycle hooks
- **Script System** - Scene-level scripts with init/update/deinit lifecycle
- **Hook System** - Type-safe, zero-overhead engine lifecycle hooks (game_init, scene_load, frame_start, etc.)
- **Layer System** - Built-in background, world, and UI layers with automatic screen/world-space handling
- **Sprite Sizing Modes** - CSS-like sizing (stretch, cover, contain, repeat) for backgrounds and UI
- **Fullscreen Support** - Toggle fullscreen and detect screen resize events
- **Multiple Graphics Backends** - raylib (default) and sokol support
- **Project Generator** - Auto-generate build files from `project.labelle` configuration
- **Dirty Tracking** - Efficient render pipeline that only syncs changed state

## Requirements

- Zig 0.15.2 or later

## Installation

Add labelle-engine to your `build.zig.zon`:

```zig
.dependencies = .{
    .@"labelle-engine" = .{
        .url = "git+https://github.com/labelle-toolkit/labelle-engine?ref=v0.18.2#<commit-hash>",
        .hash = "<hash>",
    },
},
```

Then in your `build.zig`:

```zig
const labelle_engine = b.dependency("labelle-engine", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("labelle-engine", labelle_engine.module("labelle-engine"));
```

## Quick Start

### 1. Define a Prefab

```zig
// prefabs/player.zig
const engine = @import("labelle-engine");

pub const name = "player";
pub const sprite = engine.SpriteConfig{
    .name = "player_idle",
    .x = 400,
    .y = 300,
};

pub fn onCreate(entity: u64, game_ptr: *anyopaque) void {
    const game: *engine.Game = @ptrCast(@alignCast(game_ptr));
    // Initialize player
}
```

### 2. Define a Scene

```zig
// scenes/main.zon
.{
    .name = "main",
    .scripts = .{"movement"},
    .entities = .{
        .{ .prefab = "player", .x = 400, .y = 300 },
        .{ .shape = .{ .type = .circle, .radius = 20, .color = .{ .r = 255 } } },
    },
}
```

### 3. Define a Script

```zig
// scripts/movement.zig
const engine = @import("labelle-engine");

pub fn update(game: *engine.Game, scene: *engine.Scene, dt: f32) void {
    // Update game logic
}
```

### 4. Wire Up the Game

```zig
// main.zig
const std = @import("std");
const engine = @import("labelle-engine");
const player_prefab = @import("prefabs/player.zig");
const movement_script = @import("scripts/movement.zig");

const Prefabs = engine.PrefabRegistry(.{player_prefab});
const Scripts = engine.ScriptRegistry(struct {
    pub const movement = movement_script;
});
const Loader = engine.SceneLoader(Prefabs, engine.ComponentRegistry(struct {}), Scripts);

pub fn main() !void {
    var game = try engine.Game.init(std.heap.page_allocator, .{
        .width = 800,
        .height = 600,
        .title = "My Game",
    });
    defer game.deinit();
    game.fixPointers();

    var scene = Loader.load(&game, @embedFile("scenes/main.zon"));
    scene.initScripts(&game);

    while (game.isRunning()) {
        const dt = game.getDeltaTime();
        scene.update(&game, dt);
        game.render();
    }
}
```

## Project Generator

For larger projects, use the project generator to auto-generate build files:

1. Create a `project.labelle` file:

```zig
.{
    .version = 1,
    .name = "my_game",
    .description = "My awesome game",
    .initial_scene = "main",
    .backend = .raylib,
    .ecs_backend = .zig_ecs,
    .window = .{
        .width = 800,
        .height = 600,
        .title = "My Game",
        .target_fps = 60,
    },
}
```

2. Organize your project:
```
my_game/
  project.labelle
  prefabs/
    player.zig
  components/
    health.zig
  scripts/
    movement.zig
  hooks/
    game_hooks.zig
  scenes/
    main.zon
```

3. Run the generator:
```bash
zig build generate
```

This generates `build.zig`, `build.zig.zon`, and `main.zig`.

## Build Options

```bash
# Graphics backend (default: raylib)
zig build -Dbackend=sokol

# ECS backend (default: zig_ecs)
zig build -Decs_backend=zflecs
```

## Physics Benchmarks

The physics module includes benchmarks for ECS integration patterns. Run them with:

```bash
cd physics && zig build bench-all
```

**Key findings for ECS integration:**

| Pattern | Best Approach | Performance Gain |
|---------|---------------|------------------|
| Compound Shapes | Shapes array in component | 2400x faster than multi-component |
| Velocity Control | Component sync for R/W loops | 1.66x faster than direct methods |
| Collision State | Bitmask (≤64 entities) | 9x faster queries |

See [CLAUDE.md](CLAUDE.md) for detailed design recommendations.

## Examples

See the `usage/` directory for complete examples:

- **example_1** - Basic game with prefabs, components, and scripts (raylib)
- **example_2** - Sokol backend demonstration
- **example_3** - Plugin integration (labelle-pathfinding)
- **example_hooks** - Two-way plugin hook binding pattern
- **example_hooks_generator** - Hooks folder pattern with generator

Run examples:
```bash
cd usage/example_1 && zig build run
```

For CI/headless mode:
```bash
CI_TEST=1 zig build run
```

## Architecture

```
labelle-engine
├── Game            - High-level facade for window, entities, scenes
├── Scene           - Entity container with script orchestration
├── RenderPipeline  - Bridges ECS to graphics with dirty tracking
├── SceneLoader     - Comptime .zon parser for scene definitions
├── PrefabRegistry  - Comptime map of prefab definitions
├── ComponentRegistry - Comptime map of custom component types
├── ScriptRegistry  - Comptime map of scene scripts
└── Generator       - Project file generator from .labelle config
```

## Documentation

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation and development guidance.

## License

MIT License - see LICENSE for details.

## Part of labelle-toolkit

labelle-engine is part of the [labelle-toolkit](https://github.com/labelle-toolkit) ecosystem:

- [labelle-gfx](https://github.com/labelle-toolkit/labelle-gfx) - Graphics library
- [labelle-pathfinding](https://github.com/labelle-toolkit/labelle-pathfinding) - Pathfinding algorithms
