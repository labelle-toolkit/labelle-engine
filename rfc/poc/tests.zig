const std = @import("std");
const testing = std.testing;
const core = @import("core");
const engine = @import("engine");
const micro_plugin = @import("micro_plugin");

// ============================================================
// 1. HookDispatcher — receiver-based dispatching
// ============================================================

const SimplePayload = union(enum) {
    ping: u32,
    pong: []const u8,
};

test "dispatcher: basic emit calls receiver method" {
    const Receiver = struct {
        ping_value: u32 = 0,

        pub fn ping(self: *@This(), value: u32) void {
            self.ping_value = value;
        }
        // pong not handled — should be a no-op
    };

    var recv = Receiver{};
    const D = core.HookDispatcher(SimplePayload, *Receiver, .{});
    const d = D{ .receiver = &recv };

    d.emit(.{ .ping = 42 });
    try testing.expectEqual(42, recv.ping_value);

    // pong is a no-op — no crash, no error
    d.emit(.{ .pong = "hello" });
    try testing.expectEqual(42, recv.ping_value); // unchanged
}

test "dispatcher: stateless receiver (empty struct)" {
    // Validate that the pattern from the RFC works
    var called = false;
    const flag = &called;

    const Receiver = struct {
        flag: *bool,

        pub fn ping(self: @This(), _: u32) void {
            self.flag.* = true;
        }
    };

    const D = core.HookDispatcher(SimplePayload, Receiver, .{});
    const d = D{ .receiver = .{ .flag = flag } };
    d.emit(.{ .ping = 1 });
    try testing.expect(called);
}

// ============================================================
// 2. Comptime validation — typos caught at compile time
// ============================================================

// NOTE: We can't test compile errors at runtime. But we CAN verify that
// valid handlers compile fine, which implicitly validates the validation
// logic doesn't reject good code.

test "dispatcher: partial handling compiles (no exhaustive)" {
    const Receiver = struct {
        pub fn ping(_: @This(), _: u32) void {}
        // pong intentionally missing — partial handling is OK
    };

    const D = core.HookDispatcher(SimplePayload, Receiver, .{});
    const d = D{ .receiver = .{} };
    d.emit(.{ .ping = 1 });
    d.emit(.{ .pong = "test" }); // no-op, no error
}

// Uncomment to verify compile error for typo:
// test "dispatcher: typo causes compile error" {
//     const BadReceiver = struct {
//         pub fn pimg(_: @This(), _: u32) void {} // typo: pimg instead of ping
//     };
//     _ = core.HookDispatcher(SimplePayload, BadReceiver, .{});
// }

// Uncomment to verify compile error for exhaustive mode:
// test "dispatcher: exhaustive rejects missing handler" {
//     const Partial = struct {
//         pub fn ping(_: @This(), _: u32) void {}
//         // pong missing — exhaustive mode should reject this
//     };
//     _ = core.HookDispatcher(SimplePayload, Partial, .{ .exhaustive = true });
// }

// ============================================================
// 3. MergeHooks — compose multiple receivers
// ============================================================

test "MergeHooks: calls receivers in tuple order" {
    var order: [3]u8 = .{ 0, 0, 0 };
    var idx: u8 = 0;
    const idx_ptr = &idx;
    const order_ptr = &order;

    const ReceiverA = struct {
        order: *[3]u8,
        idx: *u8,

        pub fn ping(self: @This(), _: u32) void {
            self.order[self.idx.*] = 'A';
            self.idx.* += 1;
        }
    };

    const ReceiverB = struct {
        order: *[3]u8,
        idx: *u8,

        pub fn ping(self: @This(), _: u32) void {
            self.order[self.idx.*] = 'B';
            self.idx.* += 1;
        }

        pub fn pong(self: @This(), _: []const u8) void {
            self.order[self.idx.*] = 'b';
            self.idx.* += 1;
        }
    };

    const Merged = core.MergeHooks(SimplePayload, .{ ReceiverA, ReceiverB });
    const merged = Merged{ .receivers = .{
        ReceiverA{ .order = order_ptr, .idx = idx_ptr },
        ReceiverB{ .order = order_ptr, .idx = idx_ptr },
    } };

    merged.emit(.{ .ping = 1 });
    // A called first, then B
    try testing.expectEqual('A', order[0]);
    try testing.expectEqual('B', order[1]);

    merged.emit(.{ .pong = "x" });
    // Only B handles pong
    try testing.expectEqual('b', order[2]);
}

// ============================================================
// 4. Ecs trait — comptime interface for ECS backends
// ============================================================

test "Ecs: create entity, add/get/has/remove component" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();


    const ecs = MyEcs{ .backend = &backend };

    const e = ecs.createEntity();
    try testing.expect(ecs.entityExists(e));

    const Position = struct { x: f32, y: f32 };

    ecs.add(e, Position{ .x = 10, .y = 20 });
    try testing.expect(ecs.has(e, Position));

    const pos = ecs.get(e, Position).?;
    try testing.expectEqual(10.0, pos.x);
    try testing.expectEqual(20.0, pos.y);

    // Modify through pointer
    pos.x = 99;
    try testing.expectEqual(99.0, ecs.get(e, Position).?.x);

    ecs.remove(e, Position);
    try testing.expect(!ecs.has(e, Position));

    ecs.destroyEntity(e);
    try testing.expect(!ecs.entityExists(e));
}

test "Ecs: multiple component types on same entity" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();


    const ecs = MyEcs{ .backend = &backend };

    const Position = struct { x: f32, y: f32 };
    const Health = struct { current: u32, max: u32 };

    const e = ecs.createEntity();
    ecs.add(e, Position{ .x = 1, .y = 2 });
    ecs.add(e, Health{ .current = 100, .max = 100 });

    try testing.expect(ecs.has(e, Position));
    try testing.expect(ecs.has(e, Health));
    try testing.expectEqual(100, ecs.get(e, Health).?.current);

    ecs.remove(e, Position);
    try testing.expect(!ecs.has(e, Position));
    try testing.expect(ecs.has(e, Health)); // Health unaffected
}

// ============================================================
// 5. ComponentPayload — comptime Entity type
// ============================================================

test "ComponentPayload: getGame returns typed pointer" {
    const Payload = core.ComponentPayload(u32);

    var game_state: u64 = 42;
    const payload = Payload{
        .entity_id = 7,
        .game_ptr = @ptrCast(&game_state),
    };

    try testing.expectEqual(7, payload.entity_id);
    const game = payload.getGame(u64);
    try testing.expectEqual(42, game.*);
}

// ============================================================
// 6. Split hook ownership — bidirectional dispatch
// ============================================================

test "split hooks: bound receiver bridges in-dispatcher to out-dispatcher" {
    const InPayload = union(enum) {
        do_work: u32,
    };

    const OutPayload = union(enum) {
        work_done: u32,
    };

    // "Plugin" state
    var work_count: u32 = 0;
    const work_ptr = &work_count;

    // Game receiver — handles out-events
    const GameRecv = struct {
        last_result: u32 = 0,

        pub fn work_done(self: *@This(), value: u32) void {
            self.last_result = value;
        }
    };

    const OutDispatcher = core.HookDispatcher(OutPayload, *GameRecv, .{});

    // Bound receiver — handles in-events, emits out-events
    const BoundRecv = struct {
        work: *u32,
        out: OutDispatcher,

        pub fn do_work(self: @This(), value: u32) void {
            self.work.* += value;
            self.out.emit(.{ .work_done = self.work.* });
        }
    };

    const InDispatcher = core.HookDispatcher(InPayload, BoundRecv, .{});

    var game_recv = GameRecv{};
    const in_hooks = InDispatcher{
        .receiver = .{
            .work = work_ptr,
            .out = .{ .receiver = &game_recv },
        },
    };

    // Full round-trip: in_hooks.emit → BoundRecv.do_work → work + out.emit → GameRecv.work_done
    in_hooks.emit(.{ .do_work = 5 });
    try testing.expectEqual(5, work_count);
    try testing.expectEqual(5, game_recv.last_result);

    in_hooks.emit(.{ .do_work = 3 });
    try testing.expectEqual(8, work_count);
    try testing.expectEqual(8, game_recv.last_result);
}

// ============================================================
// 7. Micro plugin — inventory (full plugin pattern)
// ============================================================

const GameItem = enum { sword, shield, potion, arrow };
const MyEcs = core.Ecs(core.MockEcsBackend(u32));
const Inventory = micro_plugin.InventoryPlugin(MyEcs, GameItem);

test "micro plugin: register entity with inventory via ECS" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs = MyEcs{ .backend = &backend };

    var plugin = Inventory.init(testing.allocator, ecs);
    const entity = ecs.createEntity();

    plugin.registerEntity(entity, 4);
    try testing.expect(plugin.hasInventory(entity));

    const inv = plugin.getInventory(entity).?;
    try testing.expectEqual(0, inv.itemCount());
    try testing.expectEqual(4, inv.capacity);
}

test "micro plugin: add and query items" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs = MyEcs{ .backend = &backend };

    var plugin = Inventory.init(testing.allocator, ecs);
    const entity = ecs.createEntity();
    plugin.registerEntity(entity, 4);

    // Add items via plugin receiver (simulates game -> plugin hook)
    const recv = plugin.pluginReceiver();
    Inventory.PluginReceiver.add_item(recv, .{
        .entity_id = entity,
        .item = .sword,
        .quantity = 1,
    });
    Inventory.PluginReceiver.add_item(recv, .{
        .entity_id = entity,
        .item = .potion,
        .quantity = 5,
    });

    const inv = plugin.getInventory(entity).?;
    try testing.expectEqual(6, inv.itemCount());
    try testing.expect(inv.hasItem(.sword));
    try testing.expect(inv.hasItem(.potion));
    try testing.expect(!inv.hasItem(.shield));
    try testing.expectEqual(1, inv.getQuantity(.sword));
    try testing.expectEqual(5, inv.getQuantity(.potion));
    try testing.expectEqual(6, plugin.total_items);
}

test "micro plugin: remove items" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs = MyEcs{ .backend = &backend };

    var plugin = Inventory.init(testing.allocator, ecs);
    const entity = ecs.createEntity();
    plugin.registerEntity(entity, 4);

    const recv = plugin.pluginReceiver();
    Inventory.PluginReceiver.add_item(recv, .{
        .entity_id = entity,
        .item = .arrow,
        .quantity = 10,
    });
    Inventory.PluginReceiver.remove_item(recv, .{
        .entity_id = entity,
        .item = .arrow,
        .quantity = 3,
    });

    const inv = plugin.getInventory(entity).?;
    try testing.expectEqual(7, inv.getQuantity(.arrow));
    try testing.expectEqual(7, plugin.total_items);
}

test "micro plugin: clear inventory" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs = MyEcs{ .backend = &backend };

    var plugin = Inventory.init(testing.allocator, ecs);
    const entity = ecs.createEntity();
    plugin.registerEntity(entity, 4);

    const recv = plugin.pluginReceiver();
    Inventory.PluginReceiver.add_item(recv, .{
        .entity_id = entity,
        .item = .sword,
        .quantity = 1,
    });
    Inventory.PluginReceiver.add_item(recv, .{
        .entity_id = entity,
        .item = .potion,
        .quantity = 3,
    });
    try testing.expectEqual(4, plugin.total_items);

    Inventory.PluginReceiver.clear_inventory(recv, .{ .entity_id = entity });

    const inv = plugin.getInventory(entity).?;
    try testing.expectEqual(0, inv.itemCount());
    try testing.expectEqual(0, plugin.total_items);
}

test "micro plugin: full round-trip via split hooks" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs = MyEcs{ .backend = &backend };

    var plugin = Inventory.init(testing.allocator, ecs);
    const entity = ecs.createEntity();
    plugin.registerEntity(entity, 2); // capacity 2 — will test inventory_full

    // Game receiver — tracks out-events from the plugin
    const GameRecv = struct {
        items_added: u32 = 0,
        last_item: ?GameItem = null,
        last_total: u32 = 0,
        full_count: u32 = 0,
        cleared_count: u32 = 0,

        pub fn item_added(self: *@This(), p: anytype) void {
            self.items_added += 1;
            self.last_item = p.item;
            self.last_total = p.new_total;
        }

        pub fn inventory_full(self: *@This(), _: anytype) void {
            self.full_count += 1;
        }

        pub fn inventory_cleared(self: *@This(), _: anytype) void {
            self.cleared_count += 1;
        }
    };

    var game_recv = GameRecv{};

    // Wire: InHooks dispatches to BoundReceiver → plugin + GameRecv
    const in_hooks = Inventory.InHooks(*GameRecv){
        .receiver = .{
            .plugin = &plugin,
            .out = .{ .receiver = &game_recv },
        },
    };

    // 1. Add sword — succeeds, emits item_added
    in_hooks.emit(.{ .add_item = .{ .entity_id = entity, .item = .sword, .quantity = 1 } });
    try testing.expect(plugin.getInventory(entity).?.hasItem(.sword));
    try testing.expectEqual(1, plugin.total_items);
    try testing.expectEqual(1, game_recv.items_added);
    try testing.expectEqual(.sword, game_recv.last_item.?);
    try testing.expectEqual(1, game_recv.last_total);

    // 2. Add potion — succeeds (second slot), emits item_added
    in_hooks.emit(.{ .add_item = .{ .entity_id = entity, .item = .potion, .quantity = 3 } });
    try testing.expectEqual(2, game_recv.items_added);
    try testing.expectEqual(.potion, game_recv.last_item.?);
    try testing.expectEqual(4, game_recv.last_total); // 1 sword + 3 potions

    // 3. Add arrow — fails (capacity 2, both slots used), emits inventory_full
    in_hooks.emit(.{ .add_item = .{ .entity_id = entity, .item = .arrow, .quantity = 5 } });
    try testing.expectEqual(2, game_recv.items_added); // unchanged
    try testing.expectEqual(1, game_recv.full_count);
    try testing.expectEqual(4, plugin.total_items); // unchanged

    // 4. Stack potions — succeeds (existing slot), emits item_added
    in_hooks.emit(.{ .add_item = .{ .entity_id = entity, .item = .potion, .quantity = 2 } });
    try testing.expectEqual(3, game_recv.items_added);
    try testing.expectEqual(6, game_recv.last_total); // 1 sword + 5 potions

    // 5. Clear inventory — emits inventory_cleared
    in_hooks.emit(.{ .clear_inventory = .{ .entity_id = entity } });
    try testing.expectEqual(1, game_recv.cleared_count);
    try testing.expectEqual(0, plugin.total_items);
}

test "micro plugin: lifecycle receiver cleans up on entity destroy" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs = MyEcs{ .backend = &backend };

    var plugin = Inventory.init(testing.allocator, ecs);
    const entity = ecs.createEntity();
    plugin.registerEntity(entity, 4);

    try testing.expect(plugin.hasInventory(entity));

    // Simulate entity_destroyed hook
    const lifecycle = plugin.lifecycleReceiver();
    Inventory.LifecycleReceiver.entity_destroyed(lifecycle, .{
        .entity_id = entity,
    });

    try testing.expect(!plugin.hasInventory(entity));
}

test "micro plugin: stacking items in same slot" {
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs = MyEcs{ .backend = &backend };

    var plugin = Inventory.init(testing.allocator, ecs);
    const entity = ecs.createEntity();
    plugin.registerEntity(entity, 4);

    const recv = plugin.pluginReceiver();
    // Add potions twice — should stack, not create two slots
    Inventory.PluginReceiver.add_item(recv, .{
        .entity_id = entity,
        .item = .potion,
        .quantity = 3,
    });
    Inventory.PluginReceiver.add_item(recv, .{
        .entity_id = entity,
        .item = .potion,
        .quantity = 2,
    });

    const inv = plugin.getInventory(entity).?;
    try testing.expectEqual(5, inv.getQuantity(.potion));
    try testing.expectEqual(1, inv.len); // one slot, not two
    try testing.expectEqual(5, plugin.total_items);
}

// ============================================================
// 8. PluginContext — comptime plugin contract validation
// ============================================================

test "PluginContext: validates and exposes correct types" {
    const Ctx = core.PluginContext(.{ .EcsType = MyEcs });

    // If types don't match, this won't compile — proves validation works
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs: Ctx.EcsType = .{ .backend = &backend };

    const entity: Ctx.Entity = ecs.createEntity();
    try testing.expect(ecs.entityExists(entity));

    // Payload correctly parameterized with Entity type
    var dummy: u64 = 0;
    const payload = Ctx.Payload{ .entity_id = entity, .game_ptr = @ptrCast(&dummy) };
    try testing.expectEqual(entity, payload.entity_id);
}

test "PluginContext: micro_plugin uses it internally" {
    // InventoryPlugin now uses PluginContext for validation.
    // If EcsType were invalid, this would fail at comptime.
    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();
    const ecs = MyEcs{ .backend = &backend };

    var plugin = Inventory.init(testing.allocator, ecs);
    const entity = ecs.createEntity();
    plugin.registerEntity(entity, 2);
    try testing.expect(plugin.hasInventory(entity));
}

// Uncomment to verify compile error for invalid EcsType:
// test "PluginContext: rejects type without Entity" {
//     const Bad = struct {};
//     _ = core.PluginContext(.{ .EcsType = Bad });
// }

// ============================================================
// 9. TestContext — convenience wrapper for plugin testing
// ============================================================

test "TestContext: provides ECS without boilerplate" {
    var ctx = core.TestContext(u32).init(testing.allocator);
    defer ctx.deinit();

    const ecs = ctx.ecs();
    const entity = ecs.createEntity();

    const Position = struct { x: f32, y: f32 };
    ecs.add(entity, Position{ .x = 10, .y = 20 });

    try testing.expect(ecs.has(entity, Position));
    try testing.expectEqual(10.0, ecs.get(entity, Position).?.x);
}

test "TestContext: works with PluginContext" {
    const TC = core.TestContext(u32);
    var ctx = TC.init(testing.allocator);
    defer ctx.deinit();

    // PluginContext validates TestContext's EcsType
    const Ctx = core.PluginContext(.{ .EcsType = TC.EcsType });
    const ecs: Ctx.EcsType = ctx.ecs();

    const entity: Ctx.Entity = ecs.createEntity();
    try testing.expect(ecs.entityExists(entity));
}

test "TestContext: micro plugin integration" {
    const TC = core.TestContext(u32);
    var ctx = TC.init(testing.allocator);
    defer ctx.deinit();

    const Inv = micro_plugin.InventoryPlugin(TC.EcsType, GameItem);
    const ecs = ctx.ecs();
    var plugin = Inv.init(testing.allocator, ecs);

    const entity = ecs.createEntity();
    plugin.registerEntity(entity, 4);

    const recv = plugin.pluginReceiver();
    Inv.PluginReceiver.add_item(recv, .{ .entity_id = entity, .item = .sword, .quantity = 1 });

    try testing.expect(plugin.hasInventory(entity));
    try testing.expectEqual(1, plugin.total_items);
}

// ============================================================
// 10. RecordingHooks — event recording for test assertions
// ============================================================

test "RecordingHooks: records and asserts event sequence" {
    var recorder = core.RecordingHooks(SimplePayload).init(testing.allocator);
    defer recorder.deinit();

    recorder.emit(.{ .ping = 42 });
    recorder.emit(.{ .pong = "hello" });
    recorder.emit(.{ .ping = 99 });

    try testing.expectEqual(3, recorder.len());
    try testing.expectEqual(2, recorder.count(.ping));
    try testing.expectEqual(1, recorder.count(.pong));

    try recorder.expectNext(.ping);
    try recorder.expectNext(.pong);
    try recorder.expectNext(.ping);
    try recorder.expectEmpty();
}

test "RecordingHooks: reset clears recordings" {
    var recorder = core.RecordingHooks(SimplePayload).init(testing.allocator);
    defer recorder.deinit();

    recorder.emit(.{ .ping = 1 });
    recorder.emit(.{ .pong = "x" });
    try testing.expectEqual(2, recorder.len());

    recorder.reset();
    try testing.expectEqual(0, recorder.len());
    try recorder.expectEmpty();
}

test "RecordingHooks: integration with micro engine" {
    const Payload = core.EngineHookPayload(u32);
    var recorder = core.RecordingHooks(Payload).init(testing.allocator);
    defer recorder.deinit(); // runs LAST

    var backend = core.MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const GameType = engine.Game(*core.RecordingHooks(Payload));
    var game = GameType.init(&backend, &recorder);
    defer game.deinit(); // runs FIRST — emits game_deinit to recorder

    game.start();
    game.loadScene("test_level");
    _ = game.createEntity();
    game.tick(0.016);

    // Exact event sequence: game_init, scene_load, entity_created, frame_start, frame_end
    try recorder.expectNext(.game_init);
    try recorder.expectNext(.scene_load);
    try recorder.expectNext(.entity_created);
    try recorder.expectNext(.frame_start);
    try recorder.expectNext(.frame_end);
    try recorder.expectEmpty();
}
