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
/// Stores LOCAL coordinates (offset from parent if parented)
pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
};

/// Parent - optional, marks entity as child of another
/// Inheritance flags control how parent transforms affect child
pub const Parent = struct {
    entity: Entity,
    inherit_rotation: bool = false,  // default: don't inherit rotation
    inherit_scale: bool = false,     // default: don't inherit scale
};

/// Children - tracks child entities (auto-managed)
pub const Children = struct {
    entities: []const Entity = &.{},
};
```

**Design rationale:**
- **Position is pure data** - just x, y, rotation; no inheritance flags
- **Parent has inheritance flags** - controls rotation/scale inheritance per-relationship
- **Scale on visuals** - scale_x/scale_y are on Sprite/Shape components, not Position
- **Parent as component** - enables queries like "all root entities" via `Not(Parent)`
- **Children component** - tracks children for hierarchy traversal and cascade destroy

### Visual Scale

Scale is stored on visual components (Sprite, Shape), not Position:

```zig
pub const Sprite = struct {
    scale_x: f32 = 1.0,   // horizontal scale
    scale_y: f32 = 1.0,   // vertical scale
    flip_x: bool = false, // mirrors sprite rendering only
    flip_y: bool = false,
    // ...
};

pub const Shape = struct {
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    // ...
};
```

**Design rationale:**
- **Scale is per-visual** - different visuals on same entity can have different scales
- **Flip is visual-only** - doesn't affect children positions
- **Parent.inherit_scale** - when true, child inherits parent's computed scale

### Coordinate System Convention

labelle-engine standardizes on **Y-up** coordinates (mathematical convention):

| Property | Value |
|----------|-------|
| Origin | Bottom-left corner (0, 0) |
| X axis | Positive → right |
| Y axis | Positive → up |
| Rotation | Counter-clockwise (positive radians) |

**Rationale:**
- **Mathematical convention** - Matches standard math/physics conventions
- **Intuitive** - "Higher Y = higher on screen" is natural
- **Box2D compatible** - Physics engine uses Y-up natively

**Coordinate transformation at boundaries:**

The engine transforms coordinates at the render and input boundaries:

```zig
// Game space (Y-up) → Screen space (Y-down) at render time
fn toScreenY(game_y: f32, screen_height: f32) f32 {
    return screen_height - game_y;
}

// Screen space (Y-down) → Game space (Y-up) at input time
fn toGameY(screen_y: f32, screen_height: f32) f32 {
    return screen_height - screen_y;
}
```

**API:**
- `game.getMousePosition()` - Returns Y-up game coordinates
- `game.getTouch(index)` - Returns Y-up game coordinates
- `game.getInput().getMousePosition()` - Returns raw Y-down screen coordinates
- Position components use Y-up game coordinates

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

### Cycle Detection

The `setParent()` API must prevent circular parent references which would cause infinite recursion in transform computation:

```zig
pub fn setParent(child: Entity, new_parent: Entity, registry: *Registry) !void {
    // Prevent self-parenting
    if (child.eql(new_parent)) {
        return error.CircularHierarchy;
    }

    // Walk up ancestor chain to detect cycles
    var ancestor = registry.tryGet(new_parent, Parent);
    var depth: u8 = 0;
    while (ancestor) |p| : (depth += 1) {
        if (p.entity.eql(child)) {
            return error.CircularHierarchy;  // child is ancestor of new_parent
        }
        if (depth > 32) {
            return error.HierarchyTooDeep;  // safety limit
        }
        ancestor = registry.tryGet(p.entity, Parent);
    }

    // Safe to set parent
    registry.set(child, Parent{ .entity = new_parent });
}
```

**Rationale:** Circular references (A→B→A) would cause `computeWorldTransform()`, `getEffectiveZIndex()`, and `markDescendantsDirty()` to recurse infinitely. Prevention at `setParent()` is more efficient than runtime detection in every recursive call.

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
const WorldTransform = struct {
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
};

/// Recursively compute world transform for an entity
/// Traverses parent hierarchy to build cumulative transform
fn computeWorldTransform(registry: *Registry, entity: Entity, depth: u8) WorldTransform {
    // Prevent infinite recursion from circular hierarchies
    if (depth > 32) {
        std.log.warn("Position hierarchy too deep (>32), possible cycle detected", .{});
        return .{};
    }

    // Get this entity's local position
    const local_pos = if (registry.tryGet(Position, entity)) |p| p.* else Position{};

    // Check if this entity has a parent
    if (registry.tryGet(Parent, entity)) |parent_comp| {
        // Recursively get parent's world transform
        const parent_world = computeWorldTransform(registry, parent_comp.entity, depth + 1);

        // Compute this entity's world position
        var world = WorldTransform{
            .rotation = local_pos.rotation,
            .scale_x = 1,
            .scale_y = 1,
        };

        // Apply rotation inheritance if enabled
        if (parent_comp.inherit_rotation) {
            world.rotation += parent_world.rotation;

            // Rotate local offset around parent's rotation
            const cos_r = @cos(parent_world.rotation);
            const sin_r = @sin(parent_world.rotation);
            world.x = parent_world.x + local_pos.x * cos_r - local_pos.y * sin_r;
            world.y = parent_world.y + local_pos.x * sin_r + local_pos.y * cos_r;
        } else {
            // No rotation - simple offset
            world.x = parent_world.x + local_pos.x;
            world.y = parent_world.y + local_pos.y;
        }

        // Apply scale inheritance if enabled
        if (parent_comp.inherit_scale) {
            world.scale_x = parent_world.scale_x;
            world.scale_y = parent_world.scale_y;
        }

        return world;
    }

    // Root entity - local position is world position
    return WorldTransform{
        .x = local_pos.x,
        .y = local_pos.y,
        .rotation = local_pos.rotation,
        .scale_x = 1,
        .scale_y = 1,
    };
}
```

**Key design decisions:**
- **Depth limit (32)** - Prevents infinite recursion from circular hierarchies
- **Default values** - WorldTransform fields have defaults, avoiding undefined values
- **Inheritance flags on Parent** - Not on Position, giving per-relationship control
- **Safe component access** - Uses `tryGet` to handle missing components gracefully

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
    // Use Children component to get child entities
    if (registry.tryGet(Children, entity)) |children_comp| {
        for (children_comp.entities) |child| {
            if (registry.tryGet(TransformDirty, child)) |dirty| {
                dirty.world_dirty = true;
            }
            markDescendantsDirty(child, registry);
        }
    }
}

// Compute only when dirty
fn getWorldTransform(entity: Entity, registry: *Registry) WorldTransform {
    if (registry.tryGet(TransformDirty, entity)) |dirty| {
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
// Explicit local position (relative to parent)
game.setLocalPosition(entity, x, y);
const local = game.getLocalPosition(entity);

// Explicit world position (computed)
game.setWorldPosition(entity, x, y);  // computes and sets local offset
const world = game.getWorldPosition(entity);

// Reparent entity (returns error on cycle)
try game.setParent(child, new_parent);
game.removeParent(child);  // becomes root

// Query hierarchy
const children = game.getChildren(entity);
const parent = game.getParent(entity);  // null if root
```

### Gradual Migration Path

To minimize disruption, we introduce explicit methods first and deprecate ambiguous ones:

**Phase 1: Add explicit methods (non-breaking)**
```zig
// New methods - always explicit about coordinate space
game.getLocalPosition(entity)   // returns Position component values
game.setLocalPosition(entity, x, y)
game.getWorldPosition(entity)   // computes world transform
game.setWorldPosition(entity, x, y)  // reverse-computes local offset
```

**Phase 2: Deprecate ambiguous methods**
```zig
// Deprecated - logs warning in debug builds
pub fn getPosition(entity: Entity) Position {
    if (builtin.mode == .Debug) {
        std.log.warn("getPosition() is deprecated, use getLocalPosition() or getWorldPosition()", .{});
    }
    return self.getLocalPosition(entity);
}

pub fn setPosition(entity: Entity, x: f32, y: f32) void {
    if (builtin.mode == .Debug) {
        std.log.warn("setPosition() is deprecated, use setLocalPosition() or setWorldPosition()", .{});
    }
    self.setLocalPosition(entity, x, y);
}
```

**Phase 3: Remove deprecated methods (future major version)**

### Migration Guide

```zig
// Before (current)
const pos = game.getPosition(entity);
game.setPosition(entity, x, y);

// After - choose based on intent:

// For local/relative positioning (e.g., child offset from parent)
const local = game.getLocalPosition(entity);
game.setLocalPosition(entity, x, y);

// For world coordinates (e.g., collision checks, screen position)
const world = game.getWorldPosition(entity);
game.setWorldPosition(entity, x, y);
```

**Key insight:** For root entities (no parent), local and world positions are identical. The explicit API makes intent clear and prevents subtle bugs when hierarchies are introduced later.

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

9. ~~**Coordinate system mismatch?**~~ **Resolved:** Standardize on Y-up with coordinate transformation at boundaries. See [Coordinate System Convention](#coordinate-system-convention) section.

---

## Implementation Plan

### Phase 1: Core components ✅
- [x] Add `Parent` component with `inherit_rotation` and `inherit_scale` flags
- [x] Add `Children` component for tracking child entities
- [x] Add `WorldTransform` computation function with depth limit
- [x] Position component stores local coordinates
- [x] Tests for transform math

### Phase 2: RenderPipeline integration ✅
- [x] RenderPipeline resolves world position from hierarchy
- [x] Children follow parent automatically (computed on sync)
- [x] Y-up to Y-down coordinate transform at render boundary
- [x] Support for legacy Gizmo parent_entity

### Phase 3: Input integration ✅
- [x] `game.getMousePosition()` returns Y-up game coordinates
- [x] `game.getTouch()` returns Y-up game coordinates
- [x] Gesture recognition uses transformed coordinates

### Phase 4: Entity lifecycle (partial)
- [ ] Cascade destroy: destroying parent destroys children
- [ ] `game.removeParent()` to unparent before destroy
- [x] Depth limit (32) prevents infinite recursion

### Phase 5: Physics integration
- [ ] Validate: no RigidBody on entities with `Parent` (Option A)
- [ ] Physics sync updates root entity Position
- [ ] Warning/error if RigidBody added to child

### Phase 6: API polish
- [ ] `game.getLocalPosition()` / `game.setLocalPosition()` (explicit local)
- [ ] `game.getWorldPosition()` / `game.setWorldPosition()` (explicit world)
- [ ] `game.setParent()` / `game.removeParent()` (with cycle detection)
- [ ] `game.getChildren()` / `game.getParent()` helpers
- [ ] Deprecate `game.getPosition()` / `game.setPosition()` with warnings

### Phase 7: Editor support
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
