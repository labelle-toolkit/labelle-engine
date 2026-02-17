const std = @import("std");
const ecs_mod = @import("ecs.zig");
const component_mod = @import("component.zig");

/// Comptime plugin context — validates that the provided ECS type satisfies the
/// core trait interface and bundles convenience type aliases for plugin development.
///
/// Replaces ad-hoc comptime parameter validation in each plugin with a single,
/// reusable validator. If the ECS type is missing required operations, the plugin
/// gets a clear compile error pointing to the specific missing function.
///
/// Usage:
///   pub fn MyPlugin(comptime EcsType: type) type {
///       const Ctx = core.PluginContext(.{ .EcsType = EcsType });
///       const Entity = Ctx.Entity;
///       const Payload = Ctx.Payload;
///       ...
///   }
pub fn PluginContext(comptime cfg: struct { EcsType: type }) type {
    comptime {
        if (!@hasDecl(cfg.EcsType, "Entity"))
            @compileError(
                "PluginContext: EcsType must expose Entity type (got " ++ @typeName(cfg.EcsType) ++ ")",
            );

        const required_fns = .{ "createEntity", "destroyEntity", "entityExists", "add", "get", "has", "remove" };
        for (required_fns) |name| {
            if (!@hasDecl(cfg.EcsType, name))
                @compileError(
                    "PluginContext: EcsType must implement '" ++ name ++ "' (got " ++ @typeName(cfg.EcsType) ++ ")",
                );
        }
    }

    return struct {
        pub const Entity = cfg.EcsType.Entity;
        pub const EcsType = cfg.EcsType;
        pub const Payload = component_mod.ComponentPayload(cfg.EcsType.Entity);
    };
}

/// Test context — wraps MockEcsBackend with convenience init/deinit.
/// Provides everything a plugin test needs without importing the engine.
///
/// Replaces the common boilerplate:
///   var backend = core.MockEcsBackend(u32).init(allocator);
///   defer backend.deinit();
///   const ecs = core.Ecs(core.MockEcsBackend(u32)){ .backend = &backend };
///
/// With:
///   var ctx = core.TestContext(u32).init(allocator);
///   defer ctx.deinit();
///   const ecs = ctx.ecs();
pub fn TestContext(comptime Entity: type) type {
    const Backend = ecs_mod.MockEcsBackend(Entity);

    return struct {
        pub const EcsType = ecs_mod.Ecs(Backend);
        pub const Payload = component_mod.ComponentPayload(Entity);

        backend: Backend,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .backend = Backend.init(allocator) };
        }

        /// Returns an Ecs wrapper pointing to this context's backend.
        /// Valid for the lifetime of the TestContext.
        pub fn ecs(self: *Self) EcsType {
            return .{ .backend = &self.backend };
        }

        pub fn deinit(self: *Self) void {
            self.backend.deinit();
        }
    };
}

/// Recording hooks — records dispatched event tags for test assertions.
/// Use as a drop-in HookSystem replacement (pass `*RecordingHooks` to Game).
///
/// Usage:
///   var recorder = core.RecordingHooks(MyPayload).init(allocator);
///   defer recorder.deinit();
///   recorder.emit(.{ .some_event = data });
///   try recorder.expectNext(.some_event);
///   try recorder.expectEmpty();
pub fn RecordingHooks(comptime PayloadUnion: type) type {
    const Tag = std.meta.Tag(PayloadUnion);

    return struct {
        tags: std.ArrayListUnmanaged(Tag) = .{},
        allocator: std.mem.Allocator,
        cursor: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.tags.deinit(self.allocator);
        }

        /// Record an event. Compatible with HookSystem emit interface.
        pub fn emit(self: *Self, payload: PayloadUnion) void {
            switch (payload) {
                inline else => |_, tag| {
                    self.tags.append(self.allocator, tag) catch @panic("OOM in RecordingHooks");
                },
            }
        }

        /// Assert the next recorded event matches the expected tag.
        pub fn expectNext(self: *Self, expected: Tag) !void {
            try std.testing.expect(self.cursor < self.tags.items.len);
            try std.testing.expectEqual(expected, self.tags.items[self.cursor]);
            self.cursor += 1;
        }

        /// Assert no more events remain after current cursor position.
        pub fn expectEmpty(self: Self) !void {
            try std.testing.expectEqual(self.tags.items.len, self.cursor);
        }

        /// Count occurrences of a specific event tag.
        pub fn count(self: Self, tag: Tag) usize {
            var n: usize = 0;
            for (self.tags.items) |t| {
                if (t == tag) n += 1;
            }
            return n;
        }

        /// Total number of recorded events.
        pub fn len(self: Self) usize {
            return self.tags.items.len;
        }

        /// Reset all recordings and cursor.
        pub fn reset(self: *Self) void {
            self.tags.clearRetainingCapacity();
            self.cursor = 0;
        }
    };
}
