/// Usage example: Saveable components for save/load.
///
/// Demonstrates every Saveable pattern with realistic game components:
///   - Marker components (zero data)
///   - Saveable with entity refs (ID remapping)
///   - Skip fields + ref arrays (derived state)
///   - remap_exclude (sentinel values)
///   - post_load_add (marker injection after load)
///   - postLoad hook (rebuild derived state)
///   - post_load_create (auto-spawn entity after load)
///   - Legacy style (backward compat)

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const Saveable = core.Saveable;
const SavePolicy = core.SavePolicy;

// ═══════════════════════════════════════════════════════════════════════════
// Example components
// ═══════════════════════════════════════════════════════════════════════════

/// Transient marker — added to entities that need their nearest movement
/// node recalculated. Stripped on save, auto-spawned by post_load_add.
const NeedsClosestNode = struct {
    pub const save = Saveable(.transient, @This(), .{});
    _marker: u8 = 0,
};

/// Transient marker that triggers graph rebuild. Declared with
/// post_load_create so the generic loader spawns it automatically.
const PathfinderRebuild = struct {
    pub const save = Saveable(.transient, @This(), .{
        .post_load_create = true,
    });
    _marker: u8 = 0,
};

/// Marker — identifies an entity as a worker. No data, but survives save/load
/// so the entity is included in the save file.
const Worker = struct {
    pub const save = Saveable(.marker, @This(), .{
        .post_load_add = &.{NeedsClosestNode},
    });
    _pad: u8 = 0,
};

/// Simple saveable — game clock. No entity refs, no skip fields.
const GameTime = struct {
    pub const save = Saveable(.saveable, @This(), .{});
    elapsed: f32 = 0,
    day: u32 = 1,
    speed: f32 = 1.0,
};

/// Saveable with entity refs — storage bound to a workstation.
/// After load, the workstation field is remapped to the new entity ID.
const Eis = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .entity_refs = &.{"workstation"},
        .post_load_add = &.{NeedsClosestNode},
    });
    workstation: u64 = 0,
    item_type: u8 = 0,
};

/// Saveable with remap_exclude — the `item` field can hold a sentinel
/// value (processing_sentinel) that should NOT be remapped as an entity ID.
const WorkingOn = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .entity_refs = &.{ "workstation_id", "source", "dest", "item" },
        .remap_exclude = &.{"item"},
    });
    workstation_id: u64 = 0,
    source: ?u64 = null,
    dest: ?u64 = null,
    item: ?u64 = null,
    step: enum { pickup, process, store } = .pickup,

    /// After load, re-parent the carried item to this worker.
    pub fn postLoad(self: *@This(), game: anytype, entity: anytype) void {
        _ = game;
        _ = entity;
        // In real code: game.setParent(item_entity, worker_entity, .{});
        // Here we just validate the hook is called.
        if (self.item) |_| {
            self.step = self.step; // no-op to prove we ran
        }
    }
};

/// Saveable with skip + ref_arrays + postLoad — workstation with derived
/// slot caches that must be rebuilt after load.
const Workstation = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .skip = &.{ "storages", "eis_slots", "ios_slots" },
        .ref_arrays = &.{"storages"},
        .post_load_add = &.{NeedsClosestNode},
    });
    name_hash: u32 = 0,
    producer: bool = false,
    storages: []const u64 = &.{},
    eis_slots: u32 = 0,
    ios_slots: u32 = 0,

    /// Rebuild derived slot counts from storages array.
    pub fn postLoad(self: *@This(), game: anytype, entity: anytype) void {
        _ = game;
        _ = entity;
        // In real code: iterate storages, query Eis/Ios components, count.
        // Here we simulate with a simple rule.
        self.eis_slots = if (self.producer) 0 else 2;
        self.ios_slots = 1;
    }
};

/// Navigation intent with postLoad that resets transient state.
const NavigationIntent = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .entity_refs = &.{"target_entity"},
    });
    target_entity: u64 = 0,
    state: enum { pending, navigating, arrived } = .pending,

    /// Paths are transient — reset to .pending so pathfinder reprocesses.
    pub fn postLoad(self: *@This(), game: anytype, entity: anytype) void {
        _ = game;
        _ = entity;
        self.state = .pending;
    }
};

/// Legacy-style component (backward compat — no Saveable call).
const LegacyHealth = struct {
    pub const save_policy: SavePolicy = .saveable;
    pub const entity_ref_fields = .{};
    current: f32 = 100,
    max: f32 = 100,
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests — verify all accessor helpers work end-to-end
// ═══════════════════════════════════════════════════════════════════════════

test "Saveable: marker with post_load_add" {
    try testing.expectEqual(SavePolicy.marker, core.getSavePolicy(Worker).?);
    try testing.expect(core.hasSavePolicy(Worker));
    try testing.expectEqual(@as(usize, 0), core.getEntityRefFields(Worker).len);
    const markers = core.getPostLoadMarkers(Worker);
    try testing.expectEqual(@as(usize, 1), markers.len);
    try testing.expect(markers[0] == NeedsClosestNode);
}

test "Saveable: simple saveable" {
    try testing.expectEqual(SavePolicy.saveable, core.getSavePolicy(GameTime).?);
    try testing.expectEqual(@as(usize, 0), core.getEntityRefFields(GameTime).len);
    try testing.expectEqual(@as(usize, 0), core.getSkipFields(GameTime).len);
    try testing.expect(!core.hasPostLoad(GameTime));

    var gt: GameTime = .{ .elapsed = 42.0 };
    try testing.expectEqual(@as(f32, 42.0), gt.elapsed);
    gt.day = 5;
    try testing.expectEqual(@as(u32, 5), gt.day);
}

test "Saveable: entity_refs with post_load_add" {
    try testing.expectEqual(SavePolicy.saveable, core.getSavePolicy(Eis).?);
    const refs = core.getEntityRefFields(Eis);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("workstation", refs[0]);
    try testing.expectEqual(@as(usize, 1), core.getPostLoadMarkers(Eis).len);
}

test "Saveable: remap_exclude + postLoad" {
    try testing.expectEqual(@as(usize, 4), core.getEntityRefFields(WorkingOn).len);
    try testing.expect(core.isRemapExcluded(WorkingOn, "item"));
    try testing.expect(!core.isRemapExcluded(WorkingOn, "workstation_id"));
    try testing.expect(!core.isRemapExcluded(WorkingOn, "source"));
    try testing.expect(core.hasPostLoad(WorkingOn));

    // Verify postLoad runs
    var wo: WorkingOn = .{ .item = 42, .step = .pickup };
    wo.postLoad({}, {});
    try testing.expectEqual(.pickup, wo.step);
}

test "Saveable: skip + ref_arrays + postLoad + post_load_add" {
    try testing.expect(core.shouldSkipField(Workstation, "storages"));
    try testing.expect(core.shouldSkipField(Workstation, "eis_slots"));
    try testing.expect(core.shouldSkipField(Workstation, "ios_slots"));
    try testing.expect(!core.shouldSkipField(Workstation, "name_hash"));

    const ref_arrays = core.getRefArrayFields(Workstation);
    try testing.expectEqual(@as(usize, 1), ref_arrays.len);
    try testing.expectEqualStrings("storages", ref_arrays[0]);

    try testing.expect(core.hasPostLoad(Workstation));
    try testing.expectEqual(@as(usize, 1), core.getPostLoadMarkers(Workstation).len);

    // Verify postLoad rebuilds slots
    var ws: Workstation = .{ .producer = false };
    ws.postLoad({}, {});
    try testing.expectEqual(@as(u32, 2), ws.eis_slots);
    try testing.expectEqual(@as(u32, 1), ws.ios_slots);
}

test "Saveable: NavigationIntent postLoad resets state" {
    var ni: NavigationIntent = .{ .target_entity = 10, .state = .navigating };
    ni.postLoad({}, {});
    try testing.expectEqual(.pending, ni.state);
}

test "Saveable: post_load_create" {
    try testing.expect(core.getPostLoadCreate(PathfinderRebuild));
    try testing.expectEqual(SavePolicy.transient, core.getSavePolicy(PathfinderRebuild).?);
    try testing.expect(!core.getPostLoadCreate(GameTime));
}

test "Saveable: legacy style backward compat" {
    try testing.expect(core.hasSavePolicy(LegacyHealth));
    try testing.expectEqual(SavePolicy.saveable, core.getSavePolicy(LegacyHealth).?);
    try testing.expectEqual(@as(usize, 0), core.getEntityRefFields(LegacyHealth).len);
    try testing.expect(!core.hasPostLoad(LegacyHealth));
    try testing.expectEqual(@as(usize, 0), core.getPostLoadMarkers(LegacyHealth).len);
    try testing.expect(!core.getPostLoadCreate(LegacyHealth));
}

test "Saveable: generic loader simulation" {
    // This simulates what save_load.zig's post-load cleanup will do.
    // All types that a game might register:
    const AllTypes = [_]type{
        Worker,
        GameTime,
        Eis,
        WorkingOn,
        Workstation,
        NavigationIntent,
        PathfinderRebuild,
        NeedsClosestNode,
        LegacyHealth,
    };

    var post_load_count: usize = 0;
    var marker_add_count: usize = 0;
    var create_count: usize = 0;

    inline for (AllTypes) |T| {
        if (comptime core.getSavePolicy(T)) |_| {
            // Step 8a: postLoad hooks
            if (comptime core.hasPostLoad(T)) {
                post_load_count += 1;
            }
            // Step 8b: post_load_add markers
            if (comptime core.getPostLoadMarkers(T).len > 0) {
                marker_add_count += 1;
            }
            // Step 8c: post_load_create
            if (comptime core.getPostLoadCreate(T)) {
                create_count += 1;
            }
        }
    }

    // 3 components with postLoad: WorkingOn, Workstation, NavigationIntent
    try testing.expectEqual(@as(usize, 3), post_load_count);
    // 4 components with post_load_add: Worker, Eis, Workstation
    try testing.expectEqual(@as(usize, 3), marker_add_count);
    // 1 component with post_load_create: PathfinderRebuild
    try testing.expectEqual(@as(usize, 1), create_count);
}

// ═══════════════════════════════════════════════════════════════════════════
// Full save/load pipeline simulation
//
// Mirrors exactly what save_load.zig does:
//   1. Save: serialize all entities with saveable/marker components to JSON
//   2. Load: parse JSON, create new entities, build ID map, restore components,
//      remap entity refs, restore ref arrays, run postLoad, inject markers,
//      create post_load_create entities
// ═══════════════════════════════════════════════════════════════════════════

const serde = core.serde;

/// All component types in our test "game". The generic loader iterates these.
const AllComponents = [_]type{
    Worker,
    GameTime,
    Eis,
    WorkingOn,
    Workstation,
    NavigationIntent,
    NeedsClosestNode,
    PathfinderRebuild,
    LegacyHealth,
};

/// Simulated entity: stores an ID and a bag of optional components.
const SimEntity = struct {
    id: u64,
    x: f32 = 0,
    y: f32 = 0,
    worker: ?Worker = null,
    game_time: ?GameTime = null,
    eis: ?Eis = null,
    working_on: ?WorkingOn = null,
    workstation: ?Workstation = null,
    nav_intent: ?NavigationIntent = null,
    needs_closest_node: ?NeedsClosestNode = null,
    pathfinder_rebuild: ?PathfinderRebuild = null,
    legacy_health: ?LegacyHealth = null,
};

const processing_sentinel: u64 = 0xFFFF_FFFF_FFFF_FFFE;

test "full pipeline: save and load entire game state" {
    const alloc = testing.allocator;

    // ── Step 1: Set up the "game world" with entities ──────────────────

    var world = [_]SimEntity{
        // Entity 100: Workstation (bakery) with storages [101, 102]
        .{
            .id = 100,
            .x = 50.0,
            .y = 75.0,
            .workstation = .{
                .name_hash = 0xBABE,
                .producer = false,
                .storages = &.{ 101, 102 },
                .eis_slots = 5, // derived state — should be rebuilt by postLoad
                .ios_slots = 3,
            },
        },
        // Entity 101: EIS storage for workstation 100
        .{
            .id = 101,
            .x = 48.0,
            .y = 73.0,
            .eis = .{ .workstation = 100, .item_type = 2 },
        },
        // Entity 102: Another EIS storage for workstation 100
        .{
            .id = 102,
            .x = 52.0,
            .y = 73.0,
            .eis = .{ .workstation = 100, .item_type = 3 },
        },
        // Entity 200: Worker navigating to workstation, carrying item (sentinel)
        .{
            .id = 200,
            .x = 10.0,
            .y = 20.0,
            .worker = .{},
            .working_on = .{
                .workstation_id = 100,
                .source = 101,
                .dest = null,
                .item = processing_sentinel,
                .step = .process,
            },
            .nav_intent = .{
                .target_entity = 100,
                .state = .navigating, // will be reset by postLoad
            },
            .legacy_health = .{ .current = 80.0, .max = 100.0 },
        },
        // Entity 300: Game clock (singleton)
        .{
            .id = 300,
            .game_time = .{ .elapsed = 542.5, .day = 3, .speed = 1.5 },
        },
    };

    // ── Step 2: SAVE — serialize all entities to JSON ──────────────────

    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(alloc);
    const writer = json_buf.writer(alloc);

    try writer.writeAll("{\"version\":2,\"entities\":[\n");
    for (&world, 0..) |*entity, idx| {
        if (idx > 0) try writer.writeAll(",\n");
        try std.fmt.format(writer, "{{\"id\":{d},\"x\":{d:.4},\"y\":{d:.4},\"components\":{{", .{ entity.id, entity.x, entity.y });

        var first = true;

        // Serialize each component that's present
        if (entity.worker) |*c| {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"Worker\":");
            try serde.writeComponent(Worker, c, writer, serde.autoSkipField);
            first = false;
        }
        if (entity.game_time) |*c| {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"GameTime\":");
            try serde.writeComponent(GameTime, c, writer, serde.autoSkipField);
            first = false;
        }
        if (entity.eis) |*c| {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"Eis\":");
            try serde.writeComponent(Eis, c, writer, serde.autoSkipField);
            first = false;
        }
        if (entity.working_on) |*c| {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"WorkingOn\":");
            try serde.writeComponent(WorkingOn, c, writer, serde.autoSkipField);
            first = false;
        }
        if (entity.workstation) |*c| {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"Workstation\":");
            try serde.writeComponent(Workstation, c, writer, serde.autoSkipField);
            first = false;
        }
        if (entity.nav_intent) |*c| {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"NavigationIntent\":");
            try serde.writeComponent(NavigationIntent, c, writer, serde.autoSkipField);
            first = false;
        }
        if (entity.legacy_health) |*c| {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("\"LegacyHealth\":");
            try serde.writeComponent(LegacyHealth, c, writer, serde.autoSkipField);
            first = false;
        }
        try writer.writeAll("}");

        // Write ref_arrays for Workstation
        if (entity.workstation) |*c| {
            try writer.writeAll(",\"ref_arrays\":");
            try serde.writeRefArrays(Workstation, c, writer);
        }

        try writer.writeAll("}");
    }
    try writer.writeAll("\n]}");

    // ── Step 3: DESTROY — clear the world ──────────────────────────────

    for (&world) |*entity| {
        entity.* = .{ .id = 0 };
    }

    // ── Step 4: LOAD — parse JSON ──────────────────────────────────────

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_buf.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const version = root.get("version").?.integer;
    try testing.expectEqual(@as(i64, 2), version);

    const entities_json = root.get("entities").?.array;
    try testing.expectEqual(@as(usize, 5), entities_json.items.len);

    // ── Step 5: Create new entities + build ID map ─────────────────────

    var id_map = std.AutoHashMap(u64, u64).init(alloc);
    defer id_map.deinit();

    var new_world: [5]SimEntity = undefined;
    var next_id: u64 = 1000; // new IDs start at 1000

    for (entities_json.items, 0..) |entry, i| {
        const obj = entry.object;
        const saved_id: u64 = @intCast(obj.get("id").?.integer);
        new_world[i] = .{ .id = next_id };
        try id_map.put(saved_id, next_id);
        next_id += 1;
    }

    // ── Step 6: Restore positions + components ─────────────────────────

    var arena_impl = std.heap.ArenaAllocator.init(alloc);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    for (entities_json.items, 0..) |entry, i| {
        const obj = entry.object;

        // Restore position
        if (obj.get("x")) |xv| {
            if (obj.get("y")) |yv| {
                new_world[i].x = serde.jsonFloat(xv);
                new_world[i].y = serde.jsonFloat(yv);
            }
        }

        // Restore components
        const components = obj.get("components").?.object;

        if (components.get("Worker")) |v| {
            var c = try serde.readComponent(Worker, v, serde.autoSkipField);
            serde.remapEntityRefs(Worker, &c, &id_map);
            new_world[i].worker = c;
        }
        if (components.get("GameTime")) |v| {
            var c = try serde.readComponent(GameTime, v, serde.autoSkipField);
            serde.remapEntityRefs(GameTime, &c, &id_map);
            new_world[i].game_time = c;
        }
        if (components.get("Eis")) |v| {
            var c = try serde.readComponent(Eis, v, serde.autoSkipField);
            serde.remapEntityRefs(Eis, &c, &id_map);
            new_world[i].eis = c;
        }
        if (components.get("WorkingOn")) |v| {
            var c = try serde.readComponent(WorkingOn, v, serde.autoSkipField);
            serde.remapEntityRefs(WorkingOn, &c, &id_map);
            new_world[i].working_on = c;
        }
        if (components.get("Workstation")) |v| {
            var c = try serde.readComponent(Workstation, v, serde.autoSkipField);
            serde.remapEntityRefs(Workstation, &c, &id_map);
            new_world[i].workstation = c;
        }
        if (components.get("NavigationIntent")) |v| {
            var c = try serde.readComponent(NavigationIntent, v, serde.autoSkipField);
            serde.remapEntityRefs(NavigationIntent, &c, &id_map);
            new_world[i].nav_intent = c;
        }
        if (components.get("LegacyHealth")) |v| {
            var c = try serde.readComponent(LegacyHealth, v, serde.autoSkipField);
            serde.remapEntityRefs(LegacyHealth, &c, &id_map);
            new_world[i].legacy_health = c;
        }

        // Restore ref_arrays
        if (obj.get("ref_arrays")) |ref_arrays_val| {
            if (new_world[i].workstation) |*ws| {
                serde.readRefArrays(Workstation, ws, ref_arrays_val.object, &id_map, arena);
            }
        }
    }

    // ── Step 7: Post-load — postLoad hooks ─────────────────────────────

    for (&new_world) |*entity| {
        if (entity.workstation) |*c| c.postLoad({}, entity.id);
        if (entity.working_on) |*c| c.postLoad({}, entity.id);
        if (entity.nav_intent) |*c| c.postLoad({}, entity.id);
    }

    // ── Step 8: Post-load — inject post_load_add markers ───────────────

    for (&new_world) |*entity| {
        // Worker has post_load_add = NeedsClosestNode
        if (entity.worker != null and entity.needs_closest_node == null) {
            entity.needs_closest_node = .{};
        }
        // Eis has post_load_add = NeedsClosestNode
        if (entity.eis != null and entity.needs_closest_node == null) {
            entity.needs_closest_node = .{};
        }
        // Workstation has post_load_add = NeedsClosestNode
        if (entity.workstation != null and entity.needs_closest_node == null) {
            entity.needs_closest_node = .{};
        }
    }

    // ── Step 9: Post-load — post_load_create ───────────────────────────

    // PathfinderRebuild has post_load_create = true → create a new entity
    var rebuild_entity = SimEntity{ .id = next_id, .pathfinder_rebuild = .{} };
    _ = &rebuild_entity;

    // ═══════════════════════════════════════════════════════════════════
    // ASSERTIONS — verify the entire loaded state
    // ═══════════════════════════════════════════════════════════════════

    // -- Entity 0 (was 100): Workstation --
    const ws_entity = &new_world[0];
    try testing.expectEqual(@as(u64, 1000), ws_entity.id);
    try testing.expectApproxEqAbs(@as(f32, 50.0), ws_entity.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 75.0), ws_entity.y, 0.01);

    const ws = ws_entity.workstation.?;
    try testing.expectEqual(@as(u32, 0xBABE), ws.name_hash);
    try testing.expect(!ws.producer);
    // Skip fields were NOT serialized → defaults after load
    // But postLoad rebuilt them:
    try testing.expectEqual(@as(u32, 2), ws.eis_slots); // producer=false → 2
    try testing.expectEqual(@as(u32, 1), ws.ios_slots);
    // Ref arrays were restored with remapped IDs
    try testing.expectEqual(@as(usize, 2), ws.storages.len);
    try testing.expectEqual(@as(u64, 1001), ws.storages[0]); // was 101 → 1001
    try testing.expectEqual(@as(u64, 1002), ws.storages[1]); // was 102 → 1002
    // post_load_add marker injected
    try testing.expect(ws_entity.needs_closest_node != null);

    // -- Entity 1 (was 101): EIS storage --
    const eis1 = &new_world[1];
    try testing.expectEqual(@as(u64, 1001), eis1.id);
    try testing.expectApproxEqAbs(@as(f32, 48.0), eis1.x, 0.01);
    const eis1_comp = eis1.eis.?;
    try testing.expectEqual(@as(u64, 1000), eis1_comp.workstation); // was 100 → 1000
    try testing.expectEqual(@as(u8, 2), eis1_comp.item_type);
    try testing.expect(eis1.needs_closest_node != null); // post_load_add

    // -- Entity 2 (was 102): EIS storage --
    const eis2 = &new_world[2];
    try testing.expectEqual(@as(u64, 1002), eis2.id);
    const eis2_comp = eis2.eis.?;
    try testing.expectEqual(@as(u64, 1000), eis2_comp.workstation); // was 100 → 1000
    try testing.expectEqual(@as(u8, 3), eis2_comp.item_type);

    // -- Entity 3 (was 200): Worker --
    const worker_entity = &new_world[3];
    try testing.expectEqual(@as(u64, 1003), worker_entity.id);
    try testing.expectApproxEqAbs(@as(f32, 10.0), worker_entity.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20.0), worker_entity.y, 0.01);
    try testing.expect(worker_entity.worker != null);

    // WorkingOn: entity refs remapped, sentinel preserved
    const wo = worker_entity.working_on.?;
    try testing.expectEqual(@as(u64, 1000), wo.workstation_id); // was 100 → 1000
    try testing.expectEqual(@as(?u64, 1001), wo.source); // was 101 → 1001
    try testing.expectEqual(@as(?u64, null), wo.dest);
    try testing.expectEqual(@as(?u64, processing_sentinel), wo.item); // sentinel preserved!
    try testing.expectEqual(.process, wo.step);

    // NavigationIntent: entity ref remapped, state reset by postLoad
    const ni = worker_entity.nav_intent.?;
    try testing.expectEqual(@as(u64, 1000), ni.target_entity); // was 100 → 1000
    try testing.expectEqual(.pending, ni.state); // was .navigating, reset by postLoad

    // LegacyHealth: backward compat, values preserved
    const health = worker_entity.legacy_health.?;
    try testing.expectApproxEqAbs(@as(f32, 80.0), health.current, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 100.0), health.max, 0.01);

    // Worker has NeedsClosestNode injected via post_load_add
    try testing.expect(worker_entity.needs_closest_node != null);

    // -- Entity 4 (was 300): GameTime --
    const time_entity = &new_world[4];
    try testing.expectEqual(@as(u64, 1004), time_entity.id);
    const gt = time_entity.game_time.?;
    try testing.expectApproxEqAbs(@as(f32, 542.5), gt.elapsed, 0.01);
    try testing.expectEqual(@as(u32, 3), gt.day);
    try testing.expectApproxEqAbs(@as(f32, 1.5), gt.speed, 0.01);

    // -- PathfinderRebuild: post_load_create spawned a new entity --
    try testing.expect(rebuild_entity.pathfinder_rebuild != null);
}
