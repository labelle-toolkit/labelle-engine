const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

var sets: usize = 0;
var removes: usize = 0;
var remove_action: enum { none, remove_self, destroy_self } = .none;
var sibling_removes: usize = 0;

const Sibling = struct {
    pub fn onRemove(p: engine.ComponentPayload) void {
        sibling_removes += 1;
        p.getGame(Game).removeComponent(@intCast(p.entity_id), Footprint);
    }
};

const Footprint = struct {
    width: f32 = 1,

    pub fn onSet(p: engine.ComponentPayload) void {
        const game = p.getGame(Game);
        std.debug.assert(game.getComponent(@intCast(p.entity_id), Footprint).?.width == 4);
        sets += 1;
    }

    pub fn onRemove(p: engine.ComponentPayload) void {
        const game = p.getGame(Game);
        const entity: u32 = @intCast(p.entity_id);
        std.debug.assert(game.getComponent(entity, Footprint) != null);
        removes += 1;
        switch (remove_action) {
            .none => {},
            .remove_self => game.removeComponent(entity, Footprint),
            .destroy_self => game.destroyEntity(entity),
        }
    }
};

const Recorder = struct {
    ctx: engine.HookContext = .{},
    positions: usize = 0,
    removing: usize = 0,
    destroyed: usize = 0,
    last_change: engine.ComponentChange = .added,
    last_x: f32 = 0,
    remove_on_change: bool = false,

    pub fn component_changed(self: *Recorder, p: engine.ComponentChangeInfo(u32)) void {
        const game = self.ctx.gameAs(Game);
        // Immediate, before removal, and available with preview disabled.
        std.debug.assert(game.ecs_backend.entityExists(p.entity_id));
        if (std.mem.eql(u8, p.component_name, @typeName(core.Position))) {
            self.positions += 1;
            self.last_change = p.change;
            self.last_x = game.getPosition(p.entity_id).x;
        }
        if (std.mem.eql(u8, p.component_name, @typeName(Footprint)) and p.change == .removing) {
            std.debug.assert(game.getComponent(p.entity_id, Footprint) != null);
            self.removing += 1;
        }
        if (self.remove_on_change and std.mem.eql(u8, p.component_name, @typeName(Footprint))) {
            game.removeComponent(p.entity_id, Footprint);
        }
    }

    pub fn entity_destroyed(self: *Recorder, p: anytype) void {
        std.debug.assert(!self.ctx.gameAs(Game).ecs_backend.entityExists(p.entity_id));
        self.destroyed += 1;
    }
};

const Components = engine.ComponentRegistry(.{ .Footprint = Footprint, .Alias = Footprint, .Position = core.Position, .Sibling = Sibling });
const Game = engine.GameConfig(core.StubRender(u32), core.MockEcsBackend(u32), engine.StubInput, engine.StubAudio, engine.StubVideo, engine.StubGui, *Recorder, core.StubLogSink, Components, &.{}, void);

test "position setters notify synchronously without preview or a game event subscriber" {
    var recorder = Recorder{};
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    const entity = game.createEntity();
    game.setPosition(entity, .{ .x = 1 });
    try testing.expectEqual(@as(usize, 1), recorder.positions);
    try testing.expectEqual(engine.ComponentChange.added, recorder.last_change);
    game.setPosition(entity, .{ .x = 2 });
    game.setWorldPosition(entity, .{ .x = 3 });
    game.setField(core.Position, .x, entity, 4);
    game.setComponent(entity, core.Position{ .x = 5 });
    try testing.expectEqual(@as(usize, 5), recorder.positions);
    try testing.expectEqual(engine.ComponentChange.set, recorder.last_change);
    try testing.expectEqual(@as(f32, 5), recorder.last_x);
}

test "field mutation calls onSet after writing; absent removal does not call onRemove" {
    sets = 0;
    removes = 0;
    remove_action = .none;
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const entity = game.createEntity();
    game.setField(Footprint, .width, entity, 4);
    game.removeComponent(entity, Footprint);
    try testing.expectEqual(@as(usize, 0), sets);
    try testing.expectEqual(@as(usize, 0), removes);
    game.addComponent(entity, Footprint{});
    game.setField(Footprint, .width, entity, 4);
    try testing.expectEqual(@as(usize, 1), sets);
    game.removeComponent(entity, Footprint);
    game.removeComponent(entity, Footprint);
    try testing.expectEqual(@as(usize, 1), removes);
}

test "both destroy APIs call onRemove once while readable, even with aliases and reentry" {
    inline for (.{ false, true }) |only| {
        inline for (.{ .none, .remove_self, .destroy_self }) |action| {
            removes = 0;
            remove_action = action;
            var recorder = Recorder{};
            var game = Game.init(testing.allocator);
            defer game.deinit();
            game.setHooks(&recorder);
            const entity = game.createEntity();
            game.addComponent(entity, Footprint{});
            if (only) game.destroyEntityOnly(entity) else game.destroyEntity(entity);
            game.destroyEntity(entity);
            try testing.expectEqual(@as(usize, 1), removes);
            try testing.expectEqual(@as(usize, 1), recorder.removing);
            try testing.expectEqual(@as(usize, 1), recorder.destroyed);
            try testing.expect(!game.ecs_backend.entityExists(entity));
        }
    }
}

test "explicit onRemove may destroy the entity without repeated callbacks" {
    removes = 0;
    remove_action = .destroy_self;
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const entity = game.createEntity();
    game.addComponent(entity, Footprint{});
    game.removeComponent(entity, Footprint);
    try testing.expectEqual(@as(usize, 1), removes);
    try testing.expect(!game.ecs_backend.entityExists(entity));
}

test "hook receivers may remove the changed component without stale pointer use" {
    removes = 0;
    remove_action = .none;
    var recorder = Recorder{ .remove_on_change = true };
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    const entity = game.createEntity();
    game.addComponent(entity, Footprint{});
    try testing.expect(!game.hasComponent(entity, Footprint));
    try testing.expectEqual(@as(usize, 1), recorder.removing);
    try testing.expectEqual(@as(usize, 1), removes);
}

test "cascading deletion calls child and parent removals exactly once" {
    removes = 0;
    remove_action = .destroy_self;
    var recorder = Recorder{};
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    const parent = game.createEntity();
    const child = game.createEntity();
    game.addComponent(parent, Footprint{});
    game.addComponent(child, Footprint{});
    game.setParent(child, parent, .{});
    game.destroyEntity(parent);
    try testing.expectEqual(@as(usize, 2), removes);
    try testing.expectEqual(@as(usize, 2), recorder.destroyed);
}

test "a later destruction callback cannot repeat an earlier component removal" {
    removes = 0;
    sibling_removes = 0;
    remove_action = .none;
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const entity = game.createEntity();
    game.addComponent(entity, Footprint{});
    game.addComponent(entity, Sibling{});
    game.destroyEntity(entity);
    try testing.expectEqual(@as(usize, 1), removes);
    try testing.expectEqual(@as(usize, 1), sibling_removes);
}
