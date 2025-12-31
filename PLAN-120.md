# Plan: Split labelle-engine into Zig Submodules (Issue #120)

## Summary
Restructure labelle-engine into separate Zig submodules for better modularity, faster compile times, and granular imports.

## Decisions Made
- **Generator**: Will be extracted to separate package (future work, not this PR)
- **labelle-render**: Public module, importable directly
- **labelle-core**: Create with foundation types

## Target Module Structure
```
src/
  root.zig                    # Unified entry (backward compatible)
  core/                       # Foundation types
    mod.zig
    zon_coercion.zig          # MOVE from src/
    entity_utils.zig          # NEW: entityToU64, entityFromU64
  ecs/                        # KEEP as-is
  input/                      # KEEP as-is
  audio/                      # KEEP as-is
  hooks/
    mod.zig                   # ADD module root
    types.zig                 # KEEP
    dispatcher.zig            # KEEP
  render/                     # NEW
    mod.zig
    pipeline.zig              # MOVE from render_pipeline.zig
    types.zig                 # EXTRACT visual types
  scene/                      # NEW
    mod.zig
    loader.zig                # MOVE from src/
    prefab.zig                # MOVE from src/
    component.zig             # MOVE from src/
    script.zig                # MOVE from src/
    scene.zig                 # EXTRACT Scene, SceneContext, EntityInstance
  engine/                     # NEW
    mod.zig
    game.zig                  # MOVE from src/
  generator/                  # KEEP in-tree for now (future extraction)
    ...
```

## Dependency DAG
```
Layer 0: core/, ecs/, input/, audio/, hooks/ (no internal deps)
Layer 1: render/ -> core/, ecs/, labelle-gfx
Layer 2: scene/ -> core/, ecs/, render/, hooks/
Layer 3: engine/ -> all above
```

## Public Modules (build.zig)
- `labelle-engine` - Unified import (backward compatible)
- `labelle-core` - Foundation types
- `labelle-render` - Render pipeline only
- `labelle-ecs`, `labelle-input`, `labelle-audio`, `labelle-hooks` - Existing subsystems

---

## Implementation Phases

### Phase 1: Core Module ✅
**Files to create/modify:**
- `src/core/mod.zig` (new)
- `src/core/entity_utils.zig` (new - extract from scene.zig:292-302)
- `src/core/zon_coercion.zig` (move from src/)

**Changes:**
1. Create `src/core/` directory
2. Create `entity_utils.zig` with `entityToU64`, `entityFromU64`, `EntityBits`
3. Move `zon_coercion.zig` to `src/core/`
4. Create `mod.zig` re-exporting both

### Phase 2: Hooks Module Update
**Files to modify:**
- `src/hooks/mod.zig` (new)
- `src/hooks.zig` (update to thin wrapper)

**Changes:**
1. Create `src/hooks/mod.zig` mirroring current `hooks.zig` structure
2. Update `src/hooks.zig` to re-export from `mod.zig`

### Phase 3: Render Module
**Files to create/modify:**
- `src/render/mod.zig` (new)
- `src/render/pipeline.zig` (move from render_pipeline.zig)
- `src/render/types.zig` (new - extract Position, Sprite, Shape, Text)

**Changes:**
1. Create `src/render/` directory
2. Extract visual component types to `types.zig`
3. Move `render_pipeline.zig` to `render/pipeline.zig`
4. Create `mod.zig` with all exports
5. Update `render_pipeline.zig` (now `pipeline.zig`) imports

### Phase 4: Scene Module
**Files to create/modify:**
- `src/scene/mod.zig` (new)
- `src/scene/scene.zig` (new - extract from src/scene.zig)
- `src/scene/loader.zig` (move)
- `src/scene/prefab.zig` (move)
- `src/scene/component.zig` (move)
- `src/scene/script.zig` (move)

**Changes:**
1. Create `src/scene/` directory
2. Extract `Scene`, `SceneContext`, `EntityInstance` to `scene/scene.zig`
3. Move `loader.zig`, `prefab.zig`, `component.zig`, `script.zig`
4. Create `mod.zig` with all exports
5. Update internal imports in all moved files

### Phase 5: Engine Module
**Files to create/modify:**
- `src/engine/mod.zig` (new)
- `src/engine/game.zig` (move from src/game.zig)

**Changes:**
1. Create `src/engine/` directory
2. Move `game.zig` to `engine/game.zig`
3. Create `mod.zig` exporting Game types
4. Update imports

### Phase 6: Root Module & build.zig
**Files to create/modify:**
- `src/root.zig` (new - replaces scene.zig as entry)
- `build.zig` (update module definitions)

**Changes:**
1. Create `src/root.zig` with all backward-compatible re-exports
2. Update `build.zig` to expose multiple modules:
   - `labelle-engine` -> `src/root.zig`
   - `labelle-core` -> `src/core/mod.zig`
   - `labelle-render` -> `src/render/mod.zig`
3. Rename/remove old `scene.zig`

### Phase 7: Cleanup & Testing
1. Run `zig build test` after each phase
2. Test all example projects: `cd usage/example_* && zig build run`
3. Update CLAUDE.md with new structure
4. Close issue #120

---

## Critical Files
- `src/scene.zig` - Current entry, ~120 lines of re-exports to preserve
- `src/render_pipeline.zig` - 382 lines, cleanly isolated
- `src/loader.zig` - 1075 lines, most dependencies
- `src/game.zig` - 620 lines, core facade
- `build.zig` - Module exposure configuration

## Backward Compatibility
`@import("labelle-engine")` continues to work identically - `root.zig` re-exports all 80+ types from the original `scene.zig`.

## Out of Scope (Future Work)
- Generator extraction to separate package (separate issue)
- Test file reorganization
- Example project updates (should work without changes)
