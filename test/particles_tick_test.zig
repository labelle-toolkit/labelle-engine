/// End-to-end tests for the particle ECS tick + render pass (#750).
///
/// Uses a recording renderer (mirrors `render_mesh_test.zig`) that captures
/// `drawMesh` submissions so the draw path is verifiable headless. Covers:
/// the tick lazily creating + stepping a `ParticleSystem` per `Emitter`
/// entity, origin sync from `Position`, the render pass batching live
/// particles into `drawMesh`, reaping on component removal, and the
/// `resetEcsBackend` side-table clear.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");
const BlendMode = core.BlendMode;

const GameConfig = engine.GameConfig;
const MockEcsBackend = engine.MockEcsBackend;
const StubInput = engine.StubInput;
const StubAudio = engine.StubAudio;
const StubVideo = engine.StubVideo;
const StubGui = engine.StubGui;
const StubLogSink = engine.StubLogSink;
const Emitter = engine.Emitter;
const ptick = engine.particles_tick;

/// Renderer satisfying the RenderInterface (like `StubRender`) that records
/// `drawMesh` calls.
fn RecordingRender(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            shape: union(enum) { rectangle: struct { width: f32 = 10, height: f32 = 10 } } = .{ .rectangle = .{} },
            color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        const MeshCall = struct {
            texture_id: u32,
            vertex_count: usize,
            index_count: usize,
            blend: BlendMode,
        };

        mesh_calls: std.ArrayListUnmanaged(MeshCall) = .empty,
        alloc: std.mem.Allocator = undefined,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .alloc = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.mesh_calls.deinit(self.alloc);
        }

        pub fn trackEntity(_: *Self, _: Entity, _: core.render.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(_: *Self, _: Entity) void {}
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.gizmos.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
        pub fn render(_: *Self) void {}
        pub fn clear(_: *Self) void {}

        pub fn drawMesh(
            self: *Self,
            texture_id: u32,
            positions: []const f32,
            _: []const f32,
            _: []const u32,
            indices: []const u16,
            blend: BlendMode,
        ) void {
            self.mesh_calls.append(self.alloc, .{
                .texture_id = texture_id,
                .vertex_count = positions.len / 2,
                .index_count = indices.len,
                .blend = blend,
            }) catch {};
        }
    };
}

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

fn TestGame() type {
    return GameConfig(
        RecordingRender(u32),
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubVideo,
        StubGui,
        void,
        StubLogSink,
        EmptyComponents,
        &.{},
        void,
    );
}

fn totalMeshVertices(game: anytype) usize {
    var n: usize = 0;
    for (game.renderer.mesh_calls.items) |c| n += c.vertex_count;
    return n;
}

test "tick lazily creates and steps a ParticleSystem per Emitter entity" {
    const G = TestGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 5, .y = 7 });
    game.addComponent(e, Emitter{ .config = .{ .rate = 100, .lifetime = 100, .speed = 0, .max_particles = 256, .seed = 1 } });

    // No system until the first tick.
    try testing.expect(game.particleSystem(e) == null);

    ptick.tick(&game, 0.1);
    const sys = game.particleSystem(e) orelse return error.NoSystem;
    try testing.expect(sys.liveCount() > 0);
    // Origin synced from Position.
    try testing.expectEqual(@as(f32, 5), sys.origin_x);
    try testing.expectEqual(@as(f32, 7), sys.origin_y);

    // Subsequent ticks keep stepping the same system (not recreated).
    const before = sys.liveCount();
    ptick.tick(&game, 0.1);
    try testing.expect(game.particleSystem(e).? == sys);
    try testing.expect(sys.liveCount() >= before);
}

test "render batches live particles into drawMesh (4 verts / 6 indices each)" {
    const G = TestGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addComponent(e, Emitter{ .config = .{ .rate = 50, .lifetime = 100, .speed = 0, .max_particles = 256, .seed = 2 } });

    ptick.tick(&game, 0.2);
    const live = game.particleSystem(e).?.liveCount();
    try testing.expect(live > 0);

    ptick.render(&game);

    const calls = game.renderer.mesh_calls.items;
    try testing.expect(calls.len >= 1);
    // Solid-colour → texture 0, normal blend.
    try testing.expectEqual(@as(u32, 0), calls[0].texture_id);
    try testing.expectEqual(BlendMode.normal, calls[0].blend);
    // One quad per live particle: 4 verts + 6 indices each, summed across
    // any batch splits.
    try testing.expectEqual(live * 4, totalMeshVertices(&game));
    var idx_total: usize = 0;
    for (calls) |c| idx_total += c.index_count;
    try testing.expectEqual(live * 6, idx_total);
}

test "render is a no-op when no emitter has particles" {
    const G = TestGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    ptick.render(&game);
    try testing.expectEqual(@as(usize, 0), game.renderer.mesh_calls.items.len);
}

test "tick reaps the side-table entry when the Emitter component is removed" {
    const G = TestGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addComponent(e, Emitter{ .config = .{ .rate = 60, .lifetime = 100, .max_particles = 64, .seed = 3 } });
    ptick.tick(&game, 0.1);
    try testing.expect(game.particleSystem(e) != null);

    // Strip the component; the next tick reaps the orphaned pool.
    game.ecs_backend.removeComponent(e, Emitter);
    ptick.tick(&game, 0.1);
    try testing.expect(game.particleSystem(e) == null);
}

test "resetEcsBackend clears the particle side-table" {
    const G = TestGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addComponent(e, Emitter{ .config = .{ .rate = 60, .lifetime = 100, .max_particles = 64, .seed = 4 } });
    ptick.tick(&game, 0.1);
    try testing.expect(game.particle_systems.count() == 1);

    game.resetEcsBackend();
    try testing.expectEqual(@as(usize, 0), game.particle_systems.count());
}

test "drive_particles gates the render pass through game.render()" {
    const G = TestGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addComponent(e, Emitter{ .config = .{ .rate = 60, .lifetime = 100, .speed = 0, .max_particles = 64, .seed = 5 } });
    ptick.tick(&game, 0.2);
    try testing.expect(game.particleSystem(e).?.liveCount() > 0);

    // drive_particles off → game.render() must not draw particles.
    game.drive_particles = false;
    game.render();
    try testing.expectEqual(@as(usize, 0), game.renderer.mesh_calls.items.len);

    // drive_particles on → game.render() composites them.
    game.drive_particles = true;
    game.render();
    try testing.expect(game.renderer.mesh_calls.items.len >= 1);
}
