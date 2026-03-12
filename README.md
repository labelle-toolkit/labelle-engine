# labelle-engine

Declarative 2D game engine for Zig with comptime scenes, ECS abstraction, prefabs, and scripts.

Part of the [labelle-toolkit](https://github.com/labelle-toolkit) ecosystem.

## Features

- **Declarative Scenes** — define entities in `.zon` files at compile time, no runtime parsing
- **ECS Abstraction** — pluggable backends (zig-ecs, zflecs, mr-ecs) behind a unified interface
- **Prefab System** — reusable entity templates with comptime registries
- **Script System** — lifecycle hooks (init, update, deinit) for game logic
- **Scene Loader** — automatic entity spawning with component assignment, nested entities, and parent-child hierarchies
- **GUI Views** — declarative UI definitions bound to scenes
- **Hook System** — type-safe, zero-overhead lifecycle hooks
- **Input & Gestures** — abstracted input handling with gesture recognition
- **Audio** — audio playback types and management
- **Query System** — ECS queries with filtering and iteration

## Requirements

- Zig 0.15.2+
- [labelle-core](https://github.com/labelle-toolkit/labelle-core) (sibling dependency)

## Build

```bash
zig build        # build the library
zig build test   # run tests (64 tests)
```

## Project Structure

```
src/
  game.zig          # Core game loop and lifecycle
  scene.zig         # Scene management
  query.zig         # ECS query abstraction
  input.zig         # Input handling
  audio.zig         # Audio system
  gui.zig           # GUI runtime
  gestures.zig      # Gesture recognition
  hooks_types.zig   # Hook system types
  form_binder.zig   # Form data binding
scene/
  src/
    core.zig        # Scene runtime (entities, scripts)
    loader.zig      # Scene loader (comptime entity spawning)
    prefab.zig      # Prefab registry and instantiation
    script.zig      # Script function table
    types.zig       # Scene configuration types
test/               # 64 tests across 9 test files
```

## Usage with labelle-cli

The recommended way to use this engine is through the [labelle-cli](https://github.com/labelle-toolkit/labelle-cli):

```bash
# Install the CLI
curl -fsSL https://labelle.games/install.sh | bash

# Create a new project
labelle init my-game --backend=raylib --ecs=zig_ecs

# Build and run
cd my-game && labelle run
```

## Integration

labelle-engine works with other labelle-toolkit libraries:

| Library | Role |
|---------|------|
| [labelle-core](https://github.com/labelle-toolkit/labelle-core) | Shared types, ECS interface, components |
| [labelle-gfx](https://github.com/labelle-toolkit/labelle-gfx) | 2D rendering, animations, cameras |
| [labelle-cli](https://github.com/labelle-toolkit/labelle-cli) | Project scaffolding and build orchestration |

## License

See [LICENSE](LICENSE) for details.
