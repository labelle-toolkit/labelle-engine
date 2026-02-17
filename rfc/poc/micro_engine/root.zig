const std = @import("std");
const core = @import("core");

/// Concrete ECS backend — simple HashMap-based, satisfies core.Ecs trait.
pub const Backend = core.MockEcsBackend(u32);

/// The engine's ECS type — wraps the backend through core's trait.
pub const EcsType = core.Ecs(Backend);

/// Engine's Entity type.
pub const Entity = u32;

/// Engine hook payload — using core's standard lifecycle events.
pub const HookPayload = core.EngineHookPayload(Entity);

/// Component lifecycle payload for this engine.
pub const Payload = core.ComponentPayload(Entity);

/// Micro game — holds ECS, dispatches hooks, runs a simple loop.
///
/// HookSystem can be:
/// - A HookDispatcher (single receiver)
/// - A MergeHooks result (multiple receivers)
/// - Any type with .emit(HookPayload) -> void
pub fn Game(comptime HookSystem: type) type {
    return struct {
        ecs: EcsType,
        frame: u64,
        hooks: HookSystem,

        const Self = @This();

        /// Backend is owned by the caller — no self-reference, no fixPointers.
        pub fn init(backend: *Backend, hooks: HookSystem) Self {
            return .{
                .ecs = .{ .backend = backend },
                .frame = 0,
                .hooks = hooks,
            };
        }

        pub fn deinit(self: *Self) void {
            self.hooks.emit(.{ .game_deinit = {} });
        }

        pub fn start(self: *Self) void {
            self.hooks.emit(.{ .game_init = .{ .allocator = @ptrCast(self.ecs.backend) } });
        }

        pub fn loadScene(self: *Self, name: []const u8) void {
            self.hooks.emit(.{ .scene_load = .{ .name = name } });
        }

        pub fn unloadScene(self: *Self, name: []const u8) void {
            self.hooks.emit(.{ .scene_unload = .{ .name = name } });
        }

        pub fn tick(self: *Self, dt: f32) void {
            self.frame += 1;
            self.hooks.emit(.{ .frame_start = .{
                .frame_number = self.frame,
                .dt = dt,
            } });
            self.hooks.emit(.{ .frame_end = .{
                .frame_number = self.frame,
                .dt = dt,
            } });
        }

        pub fn createEntity(self: *Self) Entity {
            const entity = self.ecs.createEntity();
            self.hooks.emit(.{ .entity_created = .{
                .entity_id = entity,
            } });
            return entity;
        }

        pub fn destroyEntity(self: *Self, entity: Entity) void {
            self.hooks.emit(.{ .entity_destroyed = .{
                .entity_id = entity,
            } });
            self.ecs.destroyEntity(entity);
        }
    };
}
