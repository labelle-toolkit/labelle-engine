// Kitchen Task Demo - demonstrates labelle-tasks integration with labelle-engine
//
// This script creates a visual kitchen workflow where:
// - A chef worker picks up ingredients from storage (fridge/pantry)
// - Cooks at a workstation (stove)
// - Stores finished meals in output storage
//
// Uses the script lifecycle hooks (init/update/deinit) for proper resource management.
const std = @import("std");
const engine = @import("labelle-engine");
const tasks = @import("labelle-tasks");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Shape = engine.Shape;
const Color = engine.Color;

// ============================================================================
// Game Item and Entity Types
// ============================================================================

const Item = enum {
    Meat,
    Vegetable,
    Meal,
};

const GameId = u32;
const TaskEngine = tasks.Engine(GameId, Item);
const StepType = tasks.StepType;

// Entity IDs for game objects
const CHEF_ID: GameId = 1;
const STOVE_ID: GameId = 100;

// Storage entity IDs
const FRIDGE_EIS_ID: GameId = 200;
const FRIDGE_IIS_ID: GameId = 201;
const STOVE_IOS_ID: GameId = 202;
const COUNTER_EOS_ID: GameId = 203;

// ============================================================================
// Visual Layout Constants
// ============================================================================

const GRID_SIZE: f32 = 100.0;
// Centered around origin (0,0) since camera is at (0,0) with screen center offset
const OFFSET_X: f32 = -200.0;
const OFFSET_Y: f32 = -150.0;

// Positions in grid coordinates
const FRIDGE_POS = .{ .x = 0, .y = 0 };
const STOVE_POS = .{ .x = 2, .y = 1 };
const COUNTER_POS = .{ .x = 4, .y = 0 };
const CHEF_START_POS = .{ .x = 2, .y = 2 };

fn gridToScreen(gx: i32, gy: i32) Position {
    return .{
        .x = OFFSET_X + @as(f32, @floatFromInt(gx)) * GRID_SIZE,
        .y = OFFSET_Y + @as(f32, @floatFromInt(gy)) * GRID_SIZE,
    };
}

// ============================================================================
// Script State
// ============================================================================

var task_engine: ?TaskEngine = null;

// Visual entities
var chef_entity: ?engine.Entity = null;
var fridge_entity: ?engine.Entity = null;
var stove_entity: ?engine.Entity = null;
var counter_entity: ?engine.Entity = null;
var status_text: ?engine.Entity = null;

// Chef movement state
var chef_target: ?Position = null;
var chef_speed: f32 = 150.0;
var chef_grid_pos: struct { x: i32, y: i32 } = CHEF_START_POS;

// Current step tracking
var current_step: ?StepType = null;
var pickup_item_index: u8 = 0;
var meals_produced: u32 = 0;

// ============================================================================
// Task Engine Callbacks
// ============================================================================

fn findBestWorker(
    workstation_game_id: ?GameId,
    available_workers: []const GameId,
) ?GameId {
    _ = workstation_game_id;
    // Simple: just return first available worker
    if (available_workers.len > 0) return available_workers[0];
    return null;
}

fn onPickupStarted(
    worker_game_id: GameId,
    workstation_game_id: GameId,
    eis_game_id: GameId,
) void {
    _ = worker_game_id;
    _ = workstation_game_id;
    _ = eis_game_id;

    current_step = .Pickup;
    // Move chef to fridge
    const target = gridToScreen(FRIDGE_POS.x, FRIDGE_POS.y);
    chef_target = target;
    std.debug.print("Chef moving to fridge to pickup ingredient {}\n", .{pickup_item_index + 1});
}

fn onProcessStarted(
    worker_game_id: GameId,
    workstation_game_id: GameId,
) void {
    _ = worker_game_id;
    _ = workstation_game_id;

    current_step = .Process;
    // Move chef to stove
    const target = gridToScreen(STOVE_POS.x, STOVE_POS.y);
    chef_target = target;
    std.debug.print("Chef moving to stove to cook\n", .{});
}

fn onProcessComplete(
    worker_game_id: GameId,
    workstation_game_id: GameId,
) void {
    _ = worker_game_id;
    _ = workstation_game_id;
    std.debug.print("Cooking complete!\n", .{});
}

fn onStoreStarted(
    worker_game_id: GameId,
    workstation_game_id: GameId,
    eos_game_id: GameId,
) void {
    _ = worker_game_id;
    _ = workstation_game_id;
    _ = eos_game_id;

    current_step = .Store;
    // Move chef to counter
    const target = gridToScreen(COUNTER_POS.x, COUNTER_POS.y);
    chef_target = target;
    std.debug.print("Chef moving to counter to store meal\n", .{});
}

fn onWorkerReleased(
    worker_game_id: GameId,
    workstation_game_id: GameId,
) void {
    _ = worker_game_id;
    _ = workstation_game_id;

    meals_produced += 1;
    pickup_item_index = 0;
    current_step = null;

    // Move chef back to center
    const target = gridToScreen(CHEF_START_POS.x, CHEF_START_POS.y);
    chef_target = target;
    std.debug.print("Chef released! Meals produced: {}\n", .{meals_produced});
}

fn onTransportStarted(
    worker_game_id: GameId,
    from_storage_game_id: GameId,
    to_storage_game_id: GameId,
    item: Item,
) void {
    _ = worker_game_id;
    _ = from_storage_game_id;
    _ = to_storage_game_id;
    _ = item;
}

// ============================================================================
// Script Lifecycle
// ============================================================================

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;
    const allocator = game.allocator;

    std.debug.print("\n========================================\n", .{});
    std.debug.print("  Kitchen Task Demo                     \n", .{});
    std.debug.print("========================================\n\n", .{});

    // Initialize task engine
    task_engine = TaskEngine.init(allocator);
    var te = &task_engine.?;

    // Set up callbacks
    te.setFindBestWorker(findBestWorker);
    te.setOnPickupStarted(onPickupStarted);
    te.setOnProcessStarted(onProcessStarted);
    te.setOnProcessComplete(onProcessComplete);
    te.setOnStoreStarted(onStoreStarted);
    te.setOnWorkerReleased(onWorkerReleased);
    te.setOnTransportStarted(onTransportStarted);

    // Create storages
    // EIS (External Input Storage) - Fridge with ingredients
    const eis_slots = [_]TaskEngine.Slot{
        .{ .item = .Meat, .capacity = 10 },
        .{ .item = .Vegetable, .capacity = 10 },
    };
    _ = te.addStorage(FRIDGE_EIS_ID, .{ .slots = &eis_slots });

    // IIS (Internal Input Storage) - Recipe requirements
    const iis_slots = [_]TaskEngine.Slot{
        .{ .item = .Meat, .capacity = 1 },
        .{ .item = .Vegetable, .capacity = 1 },
    };
    _ = te.addStorage(FRIDGE_IIS_ID, .{ .slots = &iis_slots });

    // IOS (Internal Output Storage) - Produced items
    const ios_slots = [_]TaskEngine.Slot{
        .{ .item = .Meal, .capacity = 1 },
    };
    _ = te.addStorage(STOVE_IOS_ID, .{ .slots = &ios_slots });

    // EOS (External Output Storage) - Counter for finished meals
    const eos_slots = [_]TaskEngine.Slot{
        .{ .item = .Meal, .capacity = 5 },
    };
    _ = te.addStorage(COUNTER_EOS_ID, .{ .slots = &eos_slots });

    // Create workstation (stove)
    _ = te.addWorkstation(STOVE_ID, .{
        .eis = FRIDGE_EIS_ID,
        .iis = FRIDGE_IIS_ID,
        .ios = STOVE_IOS_ID,
        .eos = COUNTER_EOS_ID,
        .process_duration = 60, // 60 ticks to cook
        .priority = .Normal,
    });

    // Register worker (chef)
    _ = te.addWorker(CHEF_ID, .{});

    // Add initial ingredients to fridge
    _ = te.addToStorage(FRIDGE_EIS_ID, .Meat, 5);
    _ = te.addToStorage(FRIDGE_EIS_ID, .Vegetable, 5);

    // Create visual entities
    createVisualEntities(game);

    std.debug.print("Kitchen initialized with 5 meat and 5 vegetables\n", .{});
    std.debug.print("Chef will cook meals automatically\n\n", .{});
}

fn createVisualEntities(game: *Game) void {
    // Create fridge (blue rectangle)
    const fridge_pos = gridToScreen(FRIDGE_POS.x, FRIDGE_POS.y);
    fridge_entity = game.createEntity();
    game.addPosition(fridge_entity.?, fridge_pos);
    game.addShape(fridge_entity.?, Shape.rectangle(60.0, 70.0)) catch return;
    if (game.getComponent(Shape, fridge_entity.?)) |shape| {
        shape.color = Color{ .r = 100, .g = 150, .b = 255, .a = 255 };
    }

    // Create stove (red rectangle)
    const stove_pos = gridToScreen(STOVE_POS.x, STOVE_POS.y);
    stove_entity = game.createEntity();
    game.addPosition(stove_entity.?, stove_pos);
    game.addShape(stove_entity.?, Shape.rectangle(70.0, 70.0)) catch return;
    if (game.getComponent(Shape, stove_entity.?)) |shape| {
        shape.color = Color{ .r = 255, .g = 100, .b = 100, .a = 255 };
    }

    // Create counter (green rectangle)
    const counter_pos = gridToScreen(COUNTER_POS.x, COUNTER_POS.y);
    counter_entity = game.createEntity();
    game.addPosition(counter_entity.?, counter_pos);
    game.addShape(counter_entity.?, Shape.rectangle(60.0, 50.0)) catch return;
    if (game.getComponent(Shape, counter_entity.?)) |shape| {
        shape.color = Color{ .r = 100, .g = 200, .b = 100, .a = 255 };
    }

    // Create chef (orange circle)
    const chef_pos = gridToScreen(CHEF_START_POS.x, CHEF_START_POS.y);
    chef_entity = game.createEntity();
    game.addPosition(chef_entity.?, chef_pos);
    game.addShape(chef_entity.?, Shape.circle(25.0)) catch return;
    if (game.getComponent(Shape, chef_entity.?)) |shape| {
        shape.color = Color{ .r = 255, .g = 180, .b = 50, .a = 255 };
    }
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    var te = &(task_engine orelse return);
    const ce = chef_entity orelse return;

    // Update task engine
    te.update();

    // Move chef towards target
    if (chef_target) |target| {
        if (game.getComponent(Position, ce)) |pos| {
            const dx = target.x - pos.x;
            const dy = target.y - pos.y;
            const dist = @sqrt(dx * dx + dy * dy);

            if (dist < 5.0) {
                // Arrived at target - use setPosition to mark dirty
                game.setPosition(ce, .{ .x = target.x, .y = target.y });
                chef_target = null;

                // Notify task engine based on current step
                if (current_step) |step| {
                    switch (step) {
                        .Pickup => {
                            te.notifyPickupComplete(CHEF_ID);
                            pickup_item_index += 1;
                        },
                        .Process => {
                            // Process completes automatically via timer
                        },
                        .Store => {
                            te.notifyStoreComplete(CHEF_ID);
                        },
                    }
                }
            } else {
                // Move towards target - use setPosition to mark dirty for render sync
                const speed = chef_speed * dt;
                const new_x = pos.x + (dx / dist) * speed;
                const new_y = pos.y + (dy / dist) * speed;
                game.setPosition(ce, .{ .x = new_x, .y = new_y });
            }
        }
    }

    // Update stove color based on processing state
    if (stove_entity) |se| {
        if (game.getComponent(Shape, se)) |shape| {
            if (current_step == .Process and chef_target == null) {
                // Cooking in progress - make stove glow
                shape.color = Color{ .r = 255, .g = 50, .b = 50, .a = 255 };
            } else {
                // Normal color
                shape.color = Color{ .r = 255, .g = 100, .b = 100, .a = 255 };
            }
        }
    }

    // Update counter color based on meals
    if (counter_entity) |ce_ent| {
        if (game.getComponent(Shape, ce_ent)) |shape| {
            // Brighter green with more meals
            const green: u8 = @min(255, 100 + meals_produced * 30);
            shape.color = Color{ .r = 100, .g = green, .b = 100, .a = 255 };
        }
    }
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = scene;

    // Clean up task engine
    if (task_engine) |*te| {
        te.deinit();
        task_engine = null;
    }

    // Destroy visual entities
    const registry = game.getRegistry();

    if (chef_entity) |e| registry.destroy(e);
    if (fridge_entity) |e| registry.destroy(e);
    if (stove_entity) |e| registry.destroy(e);
    if (counter_entity) |e| registry.destroy(e);

    // Reset state
    chef_entity = null;
    fridge_entity = null;
    stove_entity = null;
    counter_entity = null;
    chef_target = null;
    current_step = null;
    pickup_item_index = 0;
    meals_produced = 0;

    std.debug.print("Kitchen demo cleanup complete.\n", .{});
}
