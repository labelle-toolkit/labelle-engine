# RFC-002: Physics Integration

## Summary

Add 2D physics support to labelle-engine via a new `physics/` module with its own `build.zig`, integrating Box2D through ECS components.

## Goals

1. Provide physics components (RigidBody, Collider) that work with the existing ECS
2. Keep physics optional - projects that don't need it shouldn't pay the cost
3. Maintain the declarative .zon scene approach
4. Support both zig_ecs and zflecs backends

## Module Structure

```
labelle-engine/
├── physics/
│   ├── build.zig          # Standalone build for physics module
│   ├── mod.zig            # Main module entry point
│   ├── world.zig          # Physics world wrapper
│   ├── components.zig     # RigidBody, Collider, etc.
│   ├── systems.zig        # Physics update systems
│   ├── debug.zig          # Debug rendering
│   └── box2d/
│       └── adapter.zig    # Box2D-specific implementation
├── build.zig              # Main engine build (imports physics)
└── ...
```

## Build System Design

### Option A: Submodule with Feature Flag

```zig
// labelle-engine/build.zig
const physics_enabled = b.option(bool, "physics", "Enable physics module") orelse false;

if (physics_enabled) {
    const physics_mod = b.addModule("labelle-physics", .{
        .root_source_file = b.path("physics/mod.zig"),
        // ...
    });
    engine_mod.addImport("physics", physics_mod);
}
```

### Option B: Separate build.zig (Recommended)

```zig
// physics/build.zig
pub fn build(b: *std.Build) void {
    // Standalone physics module build
}

pub fn addPhysicsModule(b: *std.Build, ...) *std.Build.Module {
    // Called by parent build.zig when physics is enabled
}
```

**Recommendation**: Option B - keeps physics self-contained, easier to test independently.

---

## ECS Integration Design

### Core Components (User-Facing)

```zig
// physics/components.zig

/// Rigid body dynamics - user configuration only, no runtime state
pub const RigidBody = struct {
    body_type: BodyType = .dynamic,
    mass: f32 = 1.0,
    gravity_scale: f32 = 1.0,
    linear_damping: f32 = 0.0,
    angular_damping: f32 = 0.0,
    fixed_rotation: bool = false,
    bullet: bool = false,  // CCD for fast-moving objects

    pub const BodyType = enum {
        static,    // Never moves
        kinematic, // Moved by code, not physics
        dynamic,   // Fully simulated
    };
};

/// Collision shape - user configuration only
pub const Collider = struct {
    shape: Shape,
    density: f32 = 1.0,
    friction: f32 = 0.3,
    restitution: f32 = 0.0,  // Bounciness
    is_sensor: bool = false,  // Triggers events but no collision response

    pub const Shape = union(enum) {
        box: struct { width: f32, height: f32 },
        circle: struct { radius: f32 },
        polygon: struct { vertices: []const [2]f32 },
        edge: struct { start: [2]f32, end: [2]f32 },
    };
};

/// Velocity component (optional, for direct access)
pub const Velocity = struct {
    linear: [2]f32 = .{ 0, 0 },
    angular: f32 = 0,
};
```

### Internal Physics State (Managed by PhysicsWorld)

```zig
// physics/world.zig

/// Internal mapping - NOT exposed as ECS components
/// Keeps user components clean and serializable
pub const PhysicsWorld = struct {
    world: box2d.World,

    // Entity <-> Physics body mapping (internal storage)
    body_map: std.AutoHashMap(Entity, BodyId),
    entity_map: std.AutoHashMap(BodyId, Entity),
    fixture_map: std.AutoHashMap(Entity, FixtureId),

    // ...
};
```

**Benefits of separate storage:**
- Components remain pure data (serializable to .zon)
- No runtime pointers in ECS storage
- Physics state doesn't leak into game logic
- Easy to reset physics without touching ECS
- Cleaner memory layout for ECS iteration

### Scene .zon Integration

```zig
// scenes/level1.zon
.{
    .name = "level1",
    .entities = .{
        // Static ground
        .{
            .components = .{
                .Position = .{ .x = 400, .y = 550 },
                .RigidBody = .{ .body_type = .static },
                .Collider = .{ .shape = .{ .box = .{ .width = 800, .height = 20 } } },
                .Shape = .{ .type = .rectangle, .width = 800, .height = 20 },
            },
        },
        // Dynamic ball
        .{
            .components = .{
                .Position = .{ .x = 400, .y = 100 },
                .RigidBody = .{ .body_type = .dynamic, .mass = 1.0 },
                .Collider = .{ .shape = .{ .circle = .{ .radius = 20 } } },
                .Shape = .{ .type = .circle, .radius = 20 },
            },
        },
    },
}
```

---

## Physics World Management

### World Wrapper

```zig
// physics/world.zig

pub const PhysicsWorld = struct {
    allocator: Allocator,
    world: box2d.World,

    // Entity <-> Body mappings using SparseSet (5-10x faster than HashMap)
    // O(1) lookup, O(1) insert/remove, cache-friendly iteration
    body_map: SparseSet(BodyId),        // entity -> body_id
    entity_map: SparseSet(u64),          // body_id -> entity
    fixture_map: SparseSet(FixtureList), // entity -> fixtures

    // Collision event buffers (cleared each step)
    collision_begin_events: std.ArrayList(CollisionEvent),
    collision_end_events: std.ArrayList(CollisionEvent),
    sensor_enter_events: std.ArrayList(SensorEvent),
    sensor_exit_events: std.ArrayList(SensorEvent),

    // Simulation parameters
    time_step: f32 = 1.0 / 60.0,
    velocity_iterations: i32 = 8,
    position_iterations: i32 = 3,
    accumulator: f32 = 0,
    pixels_per_meter: f32 = 100.0,
    max_entities: usize = 100_000,

    pub fn init(allocator: Allocator, gravity: [2]f32) !PhysicsWorld { ... }
    pub fn deinit(self: *PhysicsWorld) void { ... }

    /// Check if entity has a physics body - O(1)
    pub fn hasBody(self: *const PhysicsWorld, entity: u64) bool {
        return self.body_map.contains(entity);
    }

    /// Get number of physics bodies
    pub fn bodyCount(self: *const PhysicsWorld) usize {
        return self.body_map.len();
    }

    /// Iterate all entities with physics bodies (cache-friendly)
    pub fn entities(self: *const PhysicsWorld) []const u64 {
        return self.body_map.keys();
    }

    /// Step physics simulation with fixed timestep
    pub fn update(self: *PhysicsWorld, dt: f32) void { ... }

    /// Create body from ECS entity
    pub fn createBody(self: *PhysicsWorld, entity: u64, rigid_body: RigidBody, position: Position) !void { ... }

    /// Remove body for entity
    pub fn destroyBody(self: *PhysicsWorld, entity: u64) void { ... }

    // Collision event queries
    pub fn getCollisionBeginEvents(self: *const PhysicsWorld) []const CollisionEvent { ... }
    pub fn getCollisionEndEvents(self: *const PhysicsWorld) []const CollisionEvent { ... }
    pub fn getSensorEnterEvents(self: *const PhysicsWorld) []const SensorEvent { ... }
    pub fn getSensorExitEvents(self: *const PhysicsWorld) []const SensorEvent { ... }
};
```

### System Integration

```zig
// physics/systems.zig

/// Called each frame to update physics and sync positions
pub fn physicsSystem(world: *PhysicsWorld, registry: *Registry, dt: f32) void {
    // 1. Sync kinematic bodies from ECS -> Physics
    syncKinematicBodies(world, registry);

    // 2. Step physics simulation
    world.update(dt);

    // 3. Sync dynamic bodies from Physics -> ECS
    world.syncToEcs(registry);
}

/// Initialize physics bodies for new entities (checks internal body_map)
pub fn physicsInitSystem(world: *PhysicsWorld, registry: *Registry) void {
    var query = registry.query(.{ RigidBody, Position });
    while (query.next()) |item| {
        // Check if entity already has a physics body (via internal storage)
        if (!world.hasBody(item.entity)) {
            const rb = item.get(RigidBody);
            const pos = item.get(Position);
            world.createBody(item.entity, rb.*, pos.*);
        }
    }
}
```

---

## Collision Events (Query API)

The primary collision event interface uses a query-based approach for performance:

```zig
// physics/world.zig

pub const CollisionEvent = struct {
    entity_a: Entity,
    entity_b: Entity,
    contact_point: [2]f32,
    normal: [2]f32,
    impulse: f32,
};

pub const PhysicsWorld = struct {
    // ... existing fields ...

    // Collision event buffers (cleared each step)
    collision_begin_events: std.ArrayList(CollisionEvent),
    collision_end_events: std.ArrayList(CollisionEvent),
    sensor_enter_events: std.ArrayList(SensorEvent),
    sensor_exit_events: std.ArrayList(SensorEvent),

    /// Query collision events from last physics step
    pub fn getCollisionBeginEvents(self: *const PhysicsWorld) []const CollisionEvent {
        return self.collision_begin_events.items;
    }

    pub fn getCollisionEndEvents(self: *const PhysicsWorld) []const CollisionEvent {
        return self.collision_end_events.items;
    }

    pub fn getSensorEnterEvents(self: *const PhysicsWorld) []const SensorEvent {
        return self.sensor_enter_events.items;
    }

    pub fn getSensorExitEvents(self: *const PhysicsWorld) []const SensorEvent {
        return self.sensor_exit_events.items;
    }
};
```

**Usage in game code:**

```zig
// In a script or system
pub fn update(game: *Game, physics_world: *PhysicsWorld, dt: f32) void {
    // Process collision events
    for (physics_world.getCollisionBeginEvents()) |event| {
        // Handle collision between event.entity_a and event.entity_b
        if (hasComponent(event.entity_a, Health)) {
            applyDamage(event.entity_a, event.impulse);
        }
    }

    // Process sensor events (triggers)
    for (physics_world.getSensorEnterEvents()) |event| {
        if (isTriggerZone(event.sensor_entity)) {
            activateTrigger(event.sensor_entity, event.other_entity);
        }
    }
}
```

### Alternative: Hook Integration (Benchmark)

For comparison, hooks can also be implemented:

```zig
// Physics hooks for game code (alternative approach to benchmark)
pub const PhysicsHooks = struct {
    pub fn collision_begin(payload: HookPayload) void {
        const info = payload.collision_begin;
        // info.entity_a, info.entity_b, info.contact_point
    }

    pub fn collision_end(payload: HookPayload) void {
        const info = payload.collision_end;
    }

    pub fn sensor_enter(payload: HookPayload) void {
        const info = payload.sensor_enter;
    }

    pub fn sensor_exit(payload: HookPayload) void {
        const info = payload.sensor_exit;
    }
};
```

Benchmarks will determine if Query API is faster than hooks as assumed.

---

## Usage Example

### In Generated main.zig

```zig
const physics = @import("labelle-physics");

pub fn main() !void {
    // ... existing setup ...

    // Initialize physics world
    var physics_world = try physics.PhysicsWorld.init(allocator, .{ 0, 9.8 });
    defer physics_world.deinit();

    // Main loop
    while (!window.shouldClose()) {
        // ... input handling ...

        // Update physics
        physics.systems.physicsInitSystem(&physics_world, game.getRegistry());
        physics.systems.physicsSystem(&physics_world, game.getRegistry(), dt);

        // ... rendering ...
    }
}
```

### In project.labelle

```zig
.{
    .name = "my_physics_game",
    .physics = .{
        .enabled = true,
        .gravity = .{ 0, 9.8 },
        .debug_draw = true,
    },
    // ...
}
```

---

## Design Decisions

1. **Component Storage**: ~~Should physics runtime state (`_body_id`) be stored in the component, or in a separate internal component?~~
   - **DECIDED**: Option B - Separate internal storage in `PhysicsWorld` using **SparseSet** (5-10x faster than HashMap)

2. **Position Ownership**: Who owns Position during physics simulation?
   - **DECIDED**: Option A - Physics writes directly to Position component (simpler, standard pattern)

3. **Collision Callbacks**: How should collision events be exposed?
   - **DECIDED**: Option B - Query API for collision events each frame (assumed faster)
   - Benchmark against Option A (hooks) to validate assumption
   - Every physics adapter must include benchmarks

4. **Multiple Worlds**: Should we support multiple physics worlds (e.g., for different scenes)?
   - **DECIDED**: No - Single world, simplifies implementation

5. **Determinism**: Should we prioritize cross-platform determinism (important for netcode)?
   - **DECIDED**: Yes - Cross-platform determinism is a priority for netcode/replays

---

## Storage Performance (SparseSet vs HashMap)

Benchmarks comparing storage strategies for entity->body mappings (50k entities):

| Operation | HashMap | SparseSet | Improvement |
|-----------|---------|-----------|-------------|
| Insert | 42 ops/us | 312 ops/us | **7.4x faster** |
| Lookup | 128 ops/us | 830 ops/us | **6.5x faster** |
| Iteration | 1069 items/us | 13k items/us | **12x faster** |
| Remove | 111 ops/us | 801 ops/us | **7.2x faster** |
| Mixed workload | 134 us | 16 us | **8.4x faster** |

SparseSet provides O(1) operations with cache-friendly dense array iteration, making it ideal for the physics body mappings where we frequently iterate over all bodies during simulation sync.

---

## Benchmarking Requirements

Every physics adapter must include benchmarks to validate performance characteristics:

```zig
// physics/benchmark.zig

pub fn runBenchmarks(allocator: Allocator) !void {
    // 1. Body creation/destruction throughput
    try benchBodyLifecycle(allocator);

    // 2. Simulation step performance (varying entity counts)
    try benchSimulationStep(allocator, 100);
    try benchSimulationStep(allocator, 1000);
    try benchSimulationStep(allocator, 10000);

    // 3. Collision detection (broad phase + narrow phase)
    try benchCollisionDetection(allocator);

    // 4. Query API vs Hooks for collision events
    try benchCollisionQuery(allocator);
    try benchCollisionHooks(allocator);

    // 5. ECS sync overhead
    try benchEcsSync(allocator);
}
```

---

## Implementation Order

1. [ ] Create `physics/build.zig` with Box2D dependency
2. [ ] Implement basic `PhysicsWorld` wrapper
3. [ ] Add `RigidBody` and `Collider` components
4. [ ] Implement ECS sync systems
5. [ ] Add collision hooks
6. [ ] Update generator for physics configuration
7. [ ] Create `usage/example_physics` demo
8. [ ] Add debug rendering
9. [ ] Write tests and documentation
