# RFC #243: Position Inheritance for Parent-Child Entity Hierarchies

## Summary

Add position inheritance so that child entities are positioned relative to their parent, and moving a parent automatically moves all descendants.

## Motivation

Currently, `parent`/`children` fields on entities are organizational only. Position is stored as absolute world coordinates, so moving a parent does not affect children.

**Use cases:**
- Composite visuals: Character with weapon/hat/armor as child entities
- Hierarchical objects: Tank body + turret, car + wheels
- Attached effects: Shadow, particles following entity
- UI layouts: Panel with child buttons/labels

## Proposed Design

### Core Concept

```
Position component stores LOCAL coordinates (offset from parent)
World position is computed: parent.worldPosition + local.position
```

### ECS Component Design

Following ECS best practices, hierarchy is expressed through small, focused components:

```zig
/// Position - local transform (required for all positioned entities)
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    inherit_rotation: bool = true,
};

/// Scale - optional, only for entities that need scaling
/// Most entities won't need this (default 1,1 assumed)
pub const Scale = struct {
    x: f32 = 1.0,
    y: f32 = 1.0,
    inherit: bool = true,
};

/// Parent - optional, marks entity as child of another
/// Children derived by querying entities with Parent component
pub const Parent = struct {
    entity: Entity,
};
```

**Design rationale:**
- **Separate components** follow ECS philosophy (small, focused data)
- **Scale is optional** - most entities don't scale, saves memory
- **Parent as component** - enables queries like "all root entities" via `Not(Parent)`
- **Children derived** - no sync issues, query `Parent.entity == X` when needed

### Visual Flip vs Transform Scale

labelle-engine distinguishes between visual flip and hierarchy scale:

```zig
// Sprite.flip_x/flip_y - visual only, does NOT affect children
pub const Sprite = struct {
    flip_x: bool = false,  // mirrors sprite rendering only
    flip_y: bool = false,
};

// Scale component - affects hierarchy (children mirror too)
pub const Scale = struct {
    x: f32 = 1.0,  // negative = mirror children positions
    y: f32 = 1.0,
};
```

This matches Unity/Godot behavior where `SpriteRenderer.flipX` vs `Transform.scale` are separate concepts.

### Z-Index Inheritance

Following Godot's approach, z-index is relative to parent by default:

```zig
pub const Sprite = struct {
    z_index: i16 = 0,
    z_relative: bool = true,  // if true, z_index is relative to parent
    // ...
};
```

**Effective z-index computation:**
```zig
fn getEffectiveZIndex(entity: Entity, registry: *Registry) i16 {
    const sprite = registry.get(entity, Sprite);
    if (!sprite.z_relative) return sprite.z_index;

    const parent_comp = registry.tryGet(entity, Parent);
    if (parent_comp == null) return sprite.z_index;

    const parent_z = getEffectiveZIndex(parent_comp.?.entity, registry);
    return parent_z + sprite.z_index;
}
```

**Example:**
```zig
// Parent z_index = 10
// Child z_index = 2, z_relative = true
// Effective child z_index = 10 + 2 = 12
```

### Entity Destruction Behavior

When a parent entity is destroyed, **all children are destroyed too** (cascade destroy). This matches Unity and Godot behavior.

```zig
// Destroying parent destroys entire subtree
game.destroyEntity(parent);  // also destroys all children

// To keep children alive, unparent first
for (game.getChildren(parent)) |child| {
    game.removeParent(child);  // child becomes root
}
game.destroyEntity(parent);  // only destroys parent
```

**Rationale:** Based on research:
- [Unity](https://discussions.unity.com/t/does-destroying-a-parent-also-destroy-the-child/666891): Children destroyed with parent
- [Godot](https://forum.godotengine.org/t/what-is-difference-queue-free-and-remove-child-what-is-queue/22333): `queue_free()` destroys subtree
- Unreal: Does NOT cascade (requires manual iteration)

We follow Unity/Godot as the more intuitive default.

### Hierarchy Depth Warning

No hard limit on hierarchy depth, but warn in debug builds if depth exceeds 8:

```zig
fn computeWorldTransform(entity: Entity, registry: *Registry, depth: u8) WorldTransform {
    if (builtin.mode == .Debug and depth > 8) {
        std.log.warn("Hierarchy depth > 8 for entity {}. Consider flattening.", .{entity});
    }
    // ...
}
```

Based on [Unity performance guidelines](https://thegamedev.guru/unity-performance/scene-hierarchy-optimization/) recommending max 4 levels for dynamic objects.

### World Transform Computation

```zig
pub const WorldTransform = struct {
    x: f32,
    y: f32,
    rotation: f32,
    scale_x: f32,
    scale_y: f32,
};

pub fn computeWorldTransform(entity: Entity, registry: *Registry) WorldTransform {
    const pos = registry.get(entity, Position);
    const scale = registry.tryGet(entity, Scale) orelse Scale{};  // default 1,1
    const parent_comp = registry.tryGet(entity, Parent);

    if (parent_comp == null) {
        // Root entity: local transform is world transform
        return .{
            .x = pos.x,
            .y = pos.y,
            .rotation = pos.rotation,
            .scale_x = scale.x,
            .scale_y = scale.y,
        };
    }

    const parent_world = computeWorldTransform(parent_comp.?.entity, registry);

    var world: WorldTransform = undefined;

    // Inherit scale
    if (scale.inherit) {
        world.scale_x = parent_world.scale_x * scale.x;
        world.scale_y = parent_world.scale_y * scale.y;
    } else {
        world.scale_x = scale.x;
        world.scale_y = scale.y;
    }

    // Apply parent scale and rotation to local position
    // Order: scale local position by parent scale, then rotate
    const scaled_x = pos.x * parent_world.scale_x;
    const scaled_y = pos.y * parent_world.scale_y;

    const cos_r = @cos(parent_world.rotation);
    const sin_r = @sin(parent_world.rotation);
    world.x = parent_world.x + scaled_x * cos_r - scaled_y * sin_r;
    world.y = parent_world.y + scaled_x * sin_r + scaled_y * cos_r;

    // Inherit rotation
    if (pos.inherit_rotation) {
        world.rotation = parent_world.rotation + pos.rotation;
    } else {
        world.rotation = pos.rotation;
    }

    return world;
}
```

**Note:** This simplified transform composition (separate scale + rotation) does not produce shear effects that would occur with full matrix transforms. This is intentional for 2D game simplicity.

### Querying Hierarchy

```zig
// Get all root entities (no parent)
var roots = registry.query(.{ Position, Not(Parent) });

// Get children of a specific entity
fn getChildren(registry: *Registry, parent_entity: Entity) []Entity {
    var children = std.ArrayList(Entity).init(allocator);
    var iter = registry.query(.{ Parent });
    while (iter.next()) |entity, parent| {
        if (parent.entity.eql(parent_entity)) {
            children.append(entity);
        }
    }
    return children.toOwnedSlice();
}
```

---

## Physics Integration

This is the most complex aspect. Box2D (and most physics engines) operate in world coordinates and have their own transform hierarchy via joints.

### Box2D's Recommended Patterns

labelle-engine uses [Box2D](https://box2d.org/) for physics. Box2D provides two ways to compose physical objects:

| Approach | Description | Use Case |
|----------|-------------|----------|
| **Compound Body** | Multiple fixtures (shapes) on a single body | Rigid assemblies with no relative motion |
| **Joints** | Separate bodies connected by constraints | Articulated objects (hinges, pistons, ragdolls) |

**Key insight from [Box2D documentation](https://box2d.org/documentation/md_simulation.html):**
> "Shapes attached to the same body don't collide"

This means:
- **Compound bodies** are for parts that move as one rigid unit (e.g., a car chassis with multiple collision shapes)
- **Joints** are for parts that need relative motion (e.g., wheels that rotate, turrets that aim)

**Box2D does NOT have a parent-child hierarchy concept.** All bodies are equal within a world. This confirms that:

1. **Visual hierarchy ≠ Physics hierarchy** - These serve different purposes
2. **Entity children should not have RigidBody** - If a child needs physics, use Box2D joints instead
3. **Compound shapes** - For complex collision geometry on a single entity, use multiple fixtures (already supported via `Collider.shapes` array)

References:
- [Box2D Simulation Documentation](https://box2d.org/documentation/md_simulation.html)
- [Box2D Joints Overview (iforce2d)](https://www.iforce2d.net/b2dtut/joints-overview)

### Question 1: Can child entities have physics bodies?

**Option A: No physics on children**
- Only root entities (no parent) can have RigidBody components
- Children are purely visual attachments
- Simple, no conflicts

**Option B: Children sync world position to physics**
- Child computes world transform, syncs to physics body
- Physics responses update the local position (reverse transform)
- Complex: physics can fight with hierarchy

**Option C: Children use kinematic bodies**
- Child entities with physics use `body_type = .kinematic`
- They follow parent but can still participate in collisions
- Cannot be pushed by other objects

**Recommendation:** Option A (no physics on children). This aligns with Box2D's design philosophy where hierarchy is expressed via joints, not parent-child relationships. Option C could be added later for specific use cases (e.g., trigger volumes on children).

### Question 2: How do compound visuals vs compound physics relate?

| Visual Hierarchy | Physics Approach | Example |
|-----------------|------------------|---------|
| Parent + children | Single body, multiple fixtures | Tank body + turret (rotates visually, one physics shape) |
| Parent + children | Parent body + child kinematic | Tank + detachable turret |
| Parent + children | Parent body + joint to child body | Ragdoll limbs |
| Independent entities | Independent bodies | Unrelated objects |

**Proposal:**
- Entity hierarchy is for **visual composition**
- Physics compound shapes are for **collision composition**
- They can overlap but serve different purposes

### Question 3: Physics-driven parent, what happens to children?

When a dynamic body moves/rotates due to physics:

```
Frame N: Physics step moves parent body
Frame N: Parent Position updated from physics world position
Frame N: Children world positions recomputed from parent
Frame N: Render uses world positions
```

Children automatically follow because their world transform depends on parent.

**Edge case:** If child has `inherit_rotation = false`, it maintains its own rotation while following parent position.

### Question 4: Transform propagation direction

Normal hierarchy: Parent → Child (local to world)
Physics: World → Entity (physics to ECS)

**Resolution:**
1. Physics updates parent's Position (which is local, but for root = world)
2. RenderPipeline computes world transforms for all entities
3. Children get world positions derived from parent

No conflict because:
- Physics only touches root entities (Option A)
- Or physics touches kinematic children which don't get pushed (Option C)

---

## Caching Strategy

Computing world transforms every frame for deep hierarchies is expensive.

### Option 1: Compute on demand
```zig
// In RenderPipeline.sync()
for (entities) |entity| {
    const world = computeWorldTransform(entity, registry);
    graphics.setPosition(entity, world.x, world.y);
}
```
- Simple
- Redundant computation for shared ancestors

### Option 2: Dirty flag propagation
```zig
pub const TransformDirty = struct {
    world_dirty: bool = true,
};

// When parent moves, mark all descendants dirty
fn markDescendantsDirty(entity: Entity, registry: *Registry) void {
    for (registry.getChildren(entity)) |child| {
        if (registry.tryGet(child, TransformDirty)) |dirty| {
            dirty.world_dirty = true;
        }
        markDescendantsDirty(child, registry);
    }
}

// Compute only when dirty
fn getWorldTransform(entity: Entity, registry: *Registry) WorldTransform {
    if (registry.tryGet(entity, TransformDirty)) |dirty| {
        if (!dirty.world_dirty) {
            return cached_transforms.get(entity);
        }
    }
    // Compute and cache
}
```
- More complex
- Better performance for large hierarchies

### Option 3: Hierarchical iteration order
```zig
// Process entities in parent-before-child order
for (entitiesInHierarchyOrder()) |entity| {
    if (parent) |p| {
        world = parent_world_cache.get(p);
    }
    // Compute this entity's world transform
    world_cache.put(entity, computed);
}
```
- Single pass
- Requires sorted iteration

**Recommendation:** Start with Option 1, optimize to Option 3 if needed.

---

## Scene File Syntax

### Current (absolute positions)
```zig
.entities = .{
    .{ .prefab = "tank", .components = .{ .Position = .{ .x = 100, .y = 100 } } },
    .{ .prefab = "turret", .components = .{ .Position = .{ .x = 100, .y = 80 } } },  // manual offset
}
```

### Authoring format (nested .children)

For hand-authored scenes, nested `.children` syntax is intuitive:

```zig
.entities = .{
    .{
        .id = "tank_1",
        .prefab = "tank",
        .components = .{ .Position = .{ .x = 100, .y = 100 } },
        .children = .{
            .{
                .prefab = "turret",
                .components = .{ .Position = .{ .x = 0, .y = -20 } },  // relative to tank
            },
        },
    },
}
```

### Serialization format (flat with .parent)

For saved scenes (editor output), flat structure with `.parent` reference:

```zig
.entities = .{
    .{
        .id = "tank_1",
        .prefab = "tank",
        .components = .{ .Position = .{ .x = 100, .y = 100 } },
    },
    .{
        .id = "turret_1",
        .prefab = "turret",
        .parent = "tank_1",  // top-level field, NOT in components
        .components = .{
            .Position = .{ .x = 0, .y = -20 },  // LOCAL position
        },
    },
}
```

**Design rationale (based on [Unity](https://blog.unity.com/engine-platform/understanding-unitys-serialization-language-yaml) and [Godot](https://docs.godotengine.org/en/4.4/contributing/development/file_formats/tscn.html)):**
- **Flat structure** - simpler parsing, matches Unity YAML and Godot TSCN
- **Local positions** - meaningful offsets preserved when reparenting
- **`.parent` as top-level field** - relationship is not a user component
- **Entity IDs required** - for parent references

The scene loader:
1. Accepts both formats (nested `.children` or flat `.parent`)
2. Internally creates `Parent` component in ECS
3. User never puts `Parent` in `.components` block

### Mirrored entities (with Scale)
```zig
.entities = .{
    .{
        .id = "enemy_1",
        .prefab = "enemy",
        .components = .{
            .Position = .{ .x = 200, .y = 100 },
            .Scale = .{ .x = -1 },  // mirrored horizontally, children mirror too
        },
    },
    .{
        .id = "weapon_1",
        .prefab = "weapon",
        .parent = "enemy_1",
        .components = .{ .Position = .{ .x = 10, .y = 0 } },
    },
}
```

---

## API Changes

### Game facade
```zig
// Set local position (relative to parent)
game.setPosition(entity, x, y);

// Get world position (computed)
const world = game.getWorldPosition(entity);

// Reparent entity
game.setParent(child, new_parent);
game.removeParent(child);  // becomes root
```

### Breaking changes
- `game.getPosition()` returns local position (was world position when no hierarchy)
- Need `game.getWorldPosition()` for world coordinates

### Migration Guide

For existing code that uses `game.getPosition()`:

```zig
// Before (v0.x)
const pos = game.getPosition(entity);
// pos.x and pos.y were always world coordinates

// After (v1.x) - for entities WITHOUT parents, behavior is unchanged
const pos = game.getPosition(entity);
// pos.x and pos.y are still world coordinates (local = world for root entities)

// After (v1.x) - for entities WITH parents, use getWorldPosition()
const world_pos = game.getWorldPosition(entity);
// world_pos.x and world_pos.y are computed world coordinates
```

**Key insight:** If your code doesn't use parent-child hierarchies, `getPosition()` behavior is unchanged since local = world for root entities.

---

## Open Questions

1. ~~**Should we store WorldTransform as a component?**~~ **Resolved:** Compute on demand (start simple, optimize later if needed).

2. ~~**What about scale inheritance?**~~ **Resolved:** Separate `Scale` component, opt-in.

3. ~~**How to express parent-child relationship?**~~ **Resolved:** `Parent` component, children derived via query.

4. ~~**Maximum hierarchy depth?**~~ **Resolved:** No hard limit, warn at depth > 8 in debug builds. Based on [Unity performance guidelines](https://thegamedev.guru/unity-performance/scene-hierarchy-optimization/).

5. ~~**Parent destroyed → children?**~~ **Resolved:** Cascade destroy (children destroyed with parent). Matches Unity/Godot behavior.

6. ~~**Z-index inheritance?**~~ **Resolved:** Relative by default (like Godot's `z_as_relative`). Child z-index = parent z-index + local z-index.

7. **Editor implications?**
   - labelle-html-editor needs to visualize and edit hierarchies
   - Drag to reparent, show local vs world coordinates

8. ~~**Serialization?**~~ **Resolved:** Flat structure with `.parent` as top-level field (not in components). Local positions. Matches Unity/Godot approach.

---

## Implementation Plan

### Phase 1: New components
- [ ] Add `Scale` component (optional, defaults to 1,1)
- [ ] Add `Parent` component (marks entity as child)
- [ ] Add `z_relative: bool` to Sprite component
- [ ] Add `WorldTransform` computation function
- [ ] Add `getEffectiveZIndex()` function
- [ ] Tests for transform math

### Phase 2: Scene loader & RenderPipeline
- [ ] Scene loader supports `.children` syntax
- [ ] Scene loader auto-adds `Parent` component to children
- [ ] Update RenderPipeline to compute world transforms
- [ ] Update RenderPipeline to use effective z-index
- [ ] Children follow parent automatically

### Phase 3: Entity lifecycle
- [ ] Cascade destroy: destroying parent destroys children
- [ ] `game.removeParent()` to unparent before destroy
- [ ] Depth warning in debug builds (> 8 levels)

### Phase 4: Physics integration
- [ ] Validate: no RigidBody on entities with `Parent` (Option A)
- [ ] Physics sync updates root entity Position
- [ ] Warning/error if RigidBody added to child

### Phase 5: API polish
- [ ] `game.getWorldPosition()` / `game.setWorldPosition()`
- [ ] `game.setParent()` / `game.removeParent()`
- [ ] `game.getChildren()` helper (query wrapper)
- [ ] Dirty flag optimization if needed

### Phase 6: Editor support
- [ ] labelle-html-editor hierarchy visualization
- [ ] Reparenting via drag-drop
- [ ] Toggle local/world coordinate display

---

## Alternatives Considered

### A: Keep positions absolute, auto-update children
When parent moves, iterate children and update their positions.
- Simpler mental model (all positions are world)
- Expensive: O(n) position updates per parent move
- Lossy: can't recover original offset if parent moves

### B: Separate LocalPosition and WorldPosition components
Two components per entity.
- Explicit, no ambiguity
- Memory overhead
- Must keep both in sync

### C: Transform component with matrix
Store full 3x3 or 4x4 matrix instead of x/y/rotation.
- Powerful, handles all transforms
- Overkill for 2D, complex API
- Matrix math less intuitive for game devs

### D: Combined Position+Scale+Parent component (Transform)
Single component with all transform data including parent reference.
- Matches Unity/Godot terminology
- Simpler API (one component)
- **Rejected:** Not idiomatic ECS, wastes memory for entities that don't need scale/parent

### E: Parent + Children components (Bevy-style)
Store both directions of hierarchy.
- Fast access both ways
- **Rejected for now:** Sync complexity, can add Children later if performance requires
