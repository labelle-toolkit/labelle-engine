# Plan v2: Clean Module Structure (No Backward Compatibility)

## Goal
Create a clean, modular structure without backward compatibility wrappers.
Breaking changes are acceptable.

## Target Structure
```
src/
  root.zig                    # ✅ Done - Single entry point for labelle-engine
  core/
    mod.zig                   # ✅ Done
    entity_utils.zig          # ✅ Done
    zon_coercion.zig          # ✅ Done
  ecs/                        # ✅ Unchanged
  input/                      # ✅ Unchanged
  audio/                      # ✅ Unchanged
  hooks/
    mod.zig                   # ✅ Done
    types.zig                 # ✅ Unchanged
    dispatcher.zig            # ✅ Unchanged
  render/
    mod.zig                   # ✅ Done
    pipeline.zig              # ✅ Done
  scene/
    mod.zig                   # ✅ Done
    core.zig                  # ✅ Done - Scene, SceneContext, EntityInstance
    loader.zig                # ✅ Done
    prefab.zig                # ✅ Done
    component.zig             # ✅ Done
    script.zig                # ✅ Done (updated to use opaque pointers)
  engine/
    mod.zig                   # ✅ Done
    game.zig                  # ✅ Done
  generator/                  # Keep in src/ for now (future extraction)
    generator.zig
    project_config.zig
  build_helpers.zig           # Keep in src/
  generator_cli.zig           # Keep in src/
  cli.zig                     # Keep in src/
```

## Files to DELETE
- `src/scene.zig` - Replace with root.zig
- `src/hooks.zig` - Use hooks/mod.zig directly

## Implementation Phases

### Phase 1: Move Scene types to scene/core.zig ✅
Extract from scene.zig:
- SceneContext
- Scene
- EntityInstance

### Phase 2: Create root.zig ✅
Clean entry point that imports from all submodules.
No massive re-export list - use namespaced imports.

### Phase 3: Update scene/mod.zig ✅
Import Scene types from core.zig instead of ../scene.zig

### Phase 4: Delete old files ✅
- Delete src/scene.zig
- Delete src/hooks.zig

### Phase 5: Update build.zig ✅
- Change labelle-engine root to src/root.zig
- Update test module paths

### Phase 6: Update internal imports ✅
Fix any remaining imports that reference deleted files.

### Phase 7: Test ✅
- Run zig build test (344 tests pass)
- Build examples (example_1, example_2, example_3 pass)

---

## New Import Pattern

**Before (backward compatible):**
```zig
const engine = @import("labelle-engine");
const Game = engine.Game;
const Position = engine.Position;
const SceneLoader = engine.SceneLoader;
```

**After (clean namespaced):**
```zig
const labelle = @import("labelle-engine");
const Game = labelle.engine.Game;
const Position = labelle.render.Position;
const SceneLoader = labelle.scene.SceneLoader;

// Or import submodules directly
const engine = @import("labelle-engine").engine;
const render = @import("labelle-engine").render;
```
