const std = @import("std");
const labelle_core = @import("labelle-core");
const scene = @import("scene");

const SimpleSceneLoader = scene.SimpleSceneLoader;

// =============================================================================
// Shared mock types
// =============================================================================

const MockEcs = labelle_core.MockEcsBackend(u32);
const MockSprite = struct { texture: []const u8 = "" };
const MockShape = struct { kind: []const u8 = "" };

/// Shared mock game for all scene loader tests.
const TestGame = struct {
    const Self = @This();
    pub const EntityType = u32;
    pub const EcsBackend = MockEcs;
    pub const SpriteComp = MockSprite;
    pub const ShapeComp = MockShape;

    ecs_backend: MockEcs,
    allocator: std.mem.Allocator,
    nested_entity_arena: std.heap.ArenaAllocator,

    pub fn createEntity(self: *Self) u32 {
        return self.ecs_backend.createEntity();
    }
    pub fn setPosition(_: *Self, _: u32, _: anytype) void {}
    pub fn addSprite(_: *Self, _: u32, _: MockSprite) void {}
    pub fn addShape(_: *Self, _: u32, _: MockShape) void {}
    pub fn fireOnReady(_: *Self, _: u32, comptime _: type) void {}
    pub fn setParent(_: *Self, _: u32, _: u32, _: anytype) void {}
    pub fn destroyEntityOnly(_: *Self, _: u32) void {}
    pub fn setActiveScene(_: *Self, _: *anyopaque, _: anytype, _: anytype, _: anytype) void {}

    fn init(allocator: std.mem.Allocator) Self {
        return .{
            .ecs_backend = MockEcs.init(allocator),
            .allocator = allocator,
            .nested_entity_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.nested_entity_arena.deinit();
        self.ecs_backend.deinit();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "addCustomComponent handles union and enum component types" {
    const allocator = std.testing.allocator;

    const DamageType = union(enum) {
        fire: f32,
        ice: f32,
        physical: void,
    };
    const Team = enum { red, blue, neutral };

    const Components = scene.ComponentRegistry(.{
        .DamageType = DamageType,
        .Team = Team,
    });
    const Prefabs = scene.PrefabRegistry(.{});
    const Loader = SimpleSceneLoader(TestGame, Prefabs, Components);

    var game = TestGame.init(allocator);
    defer game.deinit();

    const scene_data = .{
        .name = "test_scene",
        .entities = .{
            .{ .name = "fire_entity", .components = .{ .DamageType = .{ .fire = 25.0 }, .Team = .red } },
            .{ .name = "ice_entity", .components = .{ .DamageType = .{ .ice = 10.0 }, .Team = .blue } },
            .{ .name = "physical_entity", .components = .{ .DamageType = .{ .physical = {} }, .Team = .neutral } },
        },
    };

    var s = try Loader.load(scene_data, &game, allocator);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 3), s.entityCount());

    const fire_entity = s.getEntityByName("fire_entity").?;
    const fire_dmg = game.ecs_backend.getComponent(fire_entity, DamageType).?;
    try std.testing.expectEqual(DamageType{ .fire = 25.0 }, fire_dmg.*);

    const ice_entity = s.getEntityByName("ice_entity").?;
    const ice_dmg = game.ecs_backend.getComponent(ice_entity, DamageType).?;
    try std.testing.expectEqual(DamageType{ .ice = 10.0 }, ice_dmg.*);

    const phys_entity = s.getEntityByName("physical_entity").?;
    const phys_dmg = game.ecs_backend.getComponent(phys_entity, DamageType).?;
    try std.testing.expectEqual(DamageType{ .physical = {} }, phys_dmg.*);

    const fire_team = game.ecs_backend.getComponent(fire_entity, Team).?;
    try std.testing.expectEqual(Team.red, fire_team.*);

    const ice_team = game.ecs_backend.getComponent(ice_entity, Team).?;
    try std.testing.expectEqual(Team.blue, ice_team.*);

    const phys_team = game.ecs_backend.getComponent(phys_entity, Team).?;
    try std.testing.expectEqual(Team.neutral, phys_team.*);
}

test "nested entity arrays in prefab components spawn child entities" {
    const allocator = std.testing.allocator;

    const Health = struct { hp: f32 = 100 };
    const Room = struct {
        name: []const u8 = "",
        workstations: []const u64 = &.{},
    };

    const Components = scene.ComponentRegistry(.{ .Health = Health, .Room = Room });
    const Prefabs = scene.PrefabRegistry(.{
        .workstation = .{ .components = .{ .Health = .{ .hp = 50 } } },
    });
    const Loader = SimpleSceneLoader(TestGame, Prefabs, Components);

    var game = TestGame.init(allocator);
    defer game.deinit();

    const scene_data = .{
        .name = "test_nested",
        .entities = .{
            .{
                .name = "bakery",
                .prefab = "workstation",
                .components = .{
                    .Room = .{
                        .name = "Bakery",
                        .workstations = .{
                            .{ .prefab = "workstation", .components = .{ .Position = .{ .x = 10, .y = 20 } } },
                            .{ .prefab = "workstation", .components = .{ .Position = .{ .x = 30, .y = 40 } } },
                        },
                    },
                },
            },
        },
    };

    var s = try Loader.load(scene_data, &game, allocator);
    defer s.deinit();

    const bakery = s.getEntityByName("bakery").?;
    const room = game.ecs_backend.getComponent(bakery, Room).?;

    try std.testing.expectEqualStrings("Bakery", room.name);
    try std.testing.expectEqual(@as(usize, 2), room.workstations.len);

    for (room.workstations) |child_id| {
        const child_entity: u32 = @intCast(child_id);
        const child_health = game.ecs_backend.getComponent(child_entity, Health).?;
        try std.testing.expectEqual(@as(f32, 50), child_health.hp);
    }

    // Nested entity slices are allocated from game.nested_entity_arena,
    // freed automatically by game.deinit().
}

test "nested entity arrays with inline component entities" {
    const allocator = std.testing.allocator;

    const Health = struct { hp: f32 = 100 };
    const Container = struct { items: []const u64 = &.{} };

    const Components = scene.ComponentRegistry(.{ .Health = Health, .Container = Container });
    const Prefabs = scene.PrefabRegistry(.{});
    const Loader = SimpleSceneLoader(TestGame, Prefabs, Components);

    var game = TestGame.init(allocator);
    defer game.deinit();

    const scene_data = .{
        .name = "test_inline_nested",
        .entities = .{
            .{
                .name = "chest",
                .components = .{
                    .Container = .{
                        .items = .{
                            .{ .components = .{ .Health = .{ .hp = 10 } } },
                            .{ .components = .{ .Health = .{ .hp = 20 } } },
                            .{ .components = .{ .Health = .{ .hp = 30 } } },
                        },
                    },
                },
            },
        },
    };

    var s = try Loader.load(scene_data, &game, allocator);
    defer s.deinit();

    const chest = s.getEntityByName("chest").?;
    const container = game.ecs_backend.getComponent(chest, Container).?;

    try std.testing.expectEqual(@as(usize, 3), container.items.len);

    const expected_hp = [_]f32{ 10, 20, 30 };
    for (container.items, 0..) |child_id, i| {
        const child_entity: u32 = @intCast(child_id);
        const child_health = game.ecs_backend.getComponent(child_entity, Health).?;
        try std.testing.expectEqual(expected_hp[i], child_health.hp);
    }

    // Nested entity slices are allocated from game.nested_entity_arena,
    // freed automatically by game.deinit().
}
