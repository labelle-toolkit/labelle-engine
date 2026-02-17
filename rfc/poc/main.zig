const std = @import("std");
const core = @import("core");
const engine_mod = @import("engine");
const micro_plugin = @import("micro_plugin");

const MyEcs = engine_mod.EcsType;
const GameItem = enum { sword, shield, potion, arrow };
const Inventory = micro_plugin.InventoryPlugin(MyEcs, GameItem);

/// Game-side receiver — handles notifications from the inventory plugin
const GameReceiver = struct {
    pub fn item_added(_: @This(), p: anytype) void {
        std.debug.print("[game] item added to entity {}: {} x{} (total: {})\n", .{ p.entity_id, p.item, p.quantity, p.new_total });
    }

    pub fn inventory_full(_: @This(), p: anytype) void {
        std.debug.print("[game] inventory full for entity {}: can't add {}\n", .{ p.entity_id, p.item });
    }

    pub fn inventory_cleared(_: @This(), p: anytype) void {
        std.debug.print("[game] inventory cleared for entity {}: {} items removed\n", .{ p.entity_id, p.items_removed });
    }
};

/// Lifecycle hooks — merged with game-specific hooks
const LifecycleHooks = struct {
    pub fn game_init(_: @This(), _: core.GameInitInfo) void {
        std.debug.print("[game] initialized\n", .{});
    }
    pub fn scene_load(_: @This(), info: core.SceneInfo) void {
        std.debug.print("[game] scene loaded: {s}\n", .{info.name});
    }
    pub fn entity_created(_: @This(), info: anytype) void {
        std.debug.print("[game] entity created: {}\n", .{info.entity_id});
    }
    pub fn entity_destroyed(_: @This(), info: anytype) void {
        std.debug.print("[game] entity destroyed: {}\n", .{info.entity_id});
    }
};

const Merged = core.MergeHooks(core.EngineHookPayload(u32), .{LifecycleHooks});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Backend owned here — passed to game by pointer, no fixPointers needed
    var backend = engine_mod.Backend.init(gpa.allocator());
    defer backend.deinit();

    // Create game with lifecycle hooks
    var game = engine_mod.Game(Merged).init(&backend, .{
        .receivers = .{.{}},
    });
    defer game.deinit();

    // Start game
    game.start();
    game.loadScene("demo_level");

    // Create entities
    const e1 = game.createEntity();
    const e2 = game.createEntity();

    // Set up inventory plugin
    var inventory = Inventory.init(gpa.allocator(), game.ecs);
    inventory.registerEntity(e1, 4);
    inventory.registerEntity(e2, 2);

    // Wire split hooks: InHooks dispatches to BoundReceiver → plugin + GameReceiver
    const in_hooks = Inventory.InHooks(GameReceiver){
        .receiver = .{
            .plugin = &inventory,
            .out = .{ .receiver = .{} },
        },
    };

    // Add items via in_hooks — full round-trip:
    // emit → BoundReceiver.add_item → plugin.addItem + out.emit → GameReceiver.item_added
    in_hooks.emit(.{ .add_item = .{ .entity_id = e1, .item = .sword, .quantity = 1 } });
    in_hooks.emit(.{ .add_item = .{ .entity_id = e1, .item = .potion, .quantity = 3 } });
    in_hooks.emit(.{ .add_item = .{ .entity_id = e2, .item = .arrow, .quantity = 10 } });

    // Query inventory state
    if (inventory.getInventory(e1)) |inv| {
        std.debug.print("\n--- Entity {} Inventory ---\n", .{e1});
        std.debug.print("items: {}, capacity: {}\n", .{ inv.itemCount(), inv.capacity });
    }

    // Run a few frames
    for (0..3) |_| {
        game.tick(0.016);
    }

    // Clear entity 1's inventory — triggers inventory_cleared notification
    in_hooks.emit(.{ .clear_inventory = .{ .entity_id = e1 } });

    // Destroy entity — lifecycle receiver cleans up
    const lifecycle = inventory.lifecycleReceiver();
    Inventory.LifecycleReceiver.entity_destroyed(lifecycle, .{ .entity_id = e2 });
    game.destroyEntity(e2);

    std.debug.print("\n--- Inventory Plugin Stats ---\n", .{});
    std.debug.print("total items tracked: {}\n", .{inventory.total_items});
}
