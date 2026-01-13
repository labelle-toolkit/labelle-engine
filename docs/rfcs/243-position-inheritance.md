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

### Position Component Changes

```zig
pub const Position = struct {
    // Local coordinates (relative to parent, or world if no parent)
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,

    // Inheritance flags
    inherit_rotation: bool = true,
    inherit_scale: bool = true,
};
```

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
    const parent = registry.getParent(entity);

    if (parent == null) {
        // Root entity: local transform is world transform
        return .{
            .x = pos.x,
            .y = pos.y,
            .rotation = pos.rotation,
            .scale_x = pos.scale_x,
            .scale_y = pos.scale_y,
        };
    }

    const parent_world = computeWorldTransform(parent.?, registry);

    var world: WorldTransform = undefined;

    // Inherit scale
    if (pos.inherit_scale) {
        world.scale_x = parent_world.scale_x * pos.scale_x;
        world.scale_y = parent_world.scale_y * pos.scale_y;
    } else {
        world.scale_x = pos.scale_x;
        world.scale_y = pos.scale_y;
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

### Proposed (hierarchy with relative positions)
```zig
.entities = .{
    .{
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

1. **Should we store WorldTransform as a component?**
   - Pro: Easy access, can query entities by world position
   - Con: Must keep in sync, memory overhead

2. ~~**What about scale inheritance?**~~ **Resolved:** Scale fields added to Position, simplified composition (no shear).

3. **Maximum hierarchy depth?**
   - Deep hierarchies = expensive world transform computation
   - Limit to 8? 16? Unlimited with warnings?

4. **Editor implications?**
   - labelle-html-editor needs to visualize and edit hierarchies
   - Drag to reparent, show local vs world coordinates

5. **Serialization?**
   - Save local positions (natural for hierarchy)
   - Or save world positions (lossy if hierarchy changes)?

---

## Implementation Plan

### Phase 1: Core hierarchy transform
- [ ] Add `WorldTransform` computation
- [ ] Update RenderPipeline to use world transforms
- [ ] Scene loader supports `.children` syntax
- [ ] Tests for transform math

### Phase 2: Physics integration
- [ ] Validate: no RigidBody on child entities (Option A)
- [ ] Physics sync updates root entity Position
- [ ] Children follow automatically

### Phase 3: API polish
- [ ] `game.getWorldPosition()` / `game.setWorldPosition()`
- [ ] `game.setParent()` / `game.removeParent()`
- [ ] Dirty flag optimization if needed

### Phase 4: Editor support
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
