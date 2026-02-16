//! Integration tests for labelle-tasks + labelle-engine
//! Tests the task engine with recording hooks to verify full workflow cycles,
//! concurrent workers, and hook dispatch ordering.

const std = @import("std");
const zspec = @import("zspec");
const tasks = @import("labelle_tasks");

const Item = enum { Flour, Water, Dough, Bread, Sugar };

const Recorder = tasks.RecordingHooks(u32, Item);
const TestEngine = tasks.Engine(u32, Item, Recorder);

// Shared IDs for readability
const PANTRY_EIS: u32 = 1;
const MIXER_IIS: u32 = 2;
const MIXER_IOS: u32 = 3;
const TABLE_EOS: u32 = 4;
const SECOND_EOS: u32 = 5;
const MIXER_WS: u32 = 100;
const BAKER_1: u32 = 10;
const BAKER_2: u32 = 20;
const DANGLING_FLOUR_ID: u32 = 50;

fn createEngine() TestEngine {
    var hooks: Recorder = .{};
    hooks.init(std.testing.allocator);
    return TestEngine.init(std.testing.allocator, hooks, null);
}

/// Cleanup helper: engine.deinit() does NOT free recorder hooks,
/// so we must deinit hooks separately to avoid leaking the event list.
fn deinitEngine(engine: *TestEngine) void {
    engine.dispatcher.hooks.deinit();
    engine.deinit();
}

fn setupBasicWorkstation(engine: *TestEngine) !void {
    try engine.addStorage(PANTRY_EIS, .{ .role = .eis, .initial_item = .Flour });
    try engine.addStorage(MIXER_IIS, .{ .role = .iis });
    try engine.addStorage(MIXER_IOS, .{ .role = .ios });
    try engine.addStorage(TABLE_EOS, .{ .role = .eos });
    try engine.addWorkstation(MIXER_WS, .{
        .eis = &.{PANTRY_EIS},
        .iis = &.{MIXER_IIS},
        .ios = &.{MIXER_IOS},
        .eos = &.{TABLE_EOS},
    });
}

const TwoWorkstationIds = struct {
    ws_a: u32,
    ws_b: u32,
};

fn setupTwoWorkstations(engine: *TestEngine) !TwoWorkstationIds {
    const WS_A_EIS: u32 = 1;
    const WS_A_IIS: u32 = 2;
    const WS_A_IOS: u32 = 3;
    const WS_A_EOS: u32 = 4;
    const WS_A_ID: u32 = 100;

    try engine.addStorage(WS_A_EIS, .{ .role = .eis, .initial_item = .Flour });
    try engine.addStorage(WS_A_IIS, .{ .role = .iis });
    try engine.addStorage(WS_A_IOS, .{ .role = .ios });
    try engine.addStorage(WS_A_EOS, .{ .role = .eos });
    try engine.addWorkstation(WS_A_ID, .{
        .eis = &.{WS_A_EIS},
        .iis = &.{WS_A_IIS},
        .ios = &.{WS_A_IOS},
        .eos = &.{WS_A_EOS},
    });

    const WS_B_EIS: u32 = 11;
    const WS_B_IIS: u32 = 12;
    const WS_B_IOS: u32 = 13;
    const WS_B_EOS: u32 = 14;
    const WS_B_ID: u32 = 200;

    try engine.addStorage(WS_B_EIS, .{ .role = .eis, .initial_item = .Water });
    try engine.addStorage(WS_B_IIS, .{ .role = .iis });
    try engine.addStorage(WS_B_IOS, .{ .role = .ios });
    try engine.addStorage(WS_B_EOS, .{ .role = .eos });
    try engine.addWorkstation(WS_B_ID, .{
        .eis = &.{WS_B_EIS},
        .iis = &.{WS_B_IIS},
        .ios = &.{WS_B_IOS},
        .eos = &.{WS_B_EOS},
    });

    return .{ .ws_a = WS_A_ID, .ws_b = WS_B_ID };
}

test {
    zspec.runAll(@This());
}

pub const TasksIntegration = zspec.describe("Tasks Integration", struct {
    pub const full_workflow = zspec.describe("full workflow cycle", struct {
        pub fn @"complete cycle emits correct hook sequence"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            try setupBasicWorkstation(&engine);
            try engine.addWorker(BAKER_1);

            engine.dispatcher.hooks.clear();

            // Worker becomes available → should be assigned
            _ = engine.workerAvailable(BAKER_1);

            _ = try engine.dispatcher.hooks.expectNext(.worker_assigned);
            _ = try engine.dispatcher.hooks.expectNext(.workstation_activated);
            const pickup = try engine.dispatcher.hooks.expectNext(.pickup_started);
            try std.testing.expectEqual(BAKER_1, pickup.worker_id);
            try std.testing.expectEqual(PANTRY_EIS, pickup.storage_id);
            try std.testing.expectEqual(Item.Flour, pickup.item);

            // Pickup completed → process should start
            engine.dispatcher.hooks.clear();
            _ = engine.pickupCompleted(BAKER_1);

            const process = try engine.dispatcher.hooks.expectNext(.process_started);
            try std.testing.expectEqual(MIXER_WS, process.workstation_id);
            try std.testing.expectEqual(BAKER_1, process.worker_id);

            // Work completed → store should start
            engine.dispatcher.hooks.clear();
            _ = engine.workCompleted(MIXER_WS);

            _ = try engine.dispatcher.hooks.expectNext(.input_consumed);
            _ = try engine.dispatcher.hooks.expectNext(.process_completed);
            const store = try engine.dispatcher.hooks.expectNext(.store_started);
            try std.testing.expectEqual(BAKER_1, store.worker_id);
            try std.testing.expectEqual(TABLE_EOS, store.storage_id);

            // Store completed → cycle complete, worker released
            engine.dispatcher.hooks.clear();
            _ = engine.storeCompleted(BAKER_1);

            _ = try engine.dispatcher.hooks.expectNext(.cycle_completed);
            _ = try engine.dispatcher.hooks.expectNext(.worker_released);
            try engine.dispatcher.hooks.expectEmpty();

            // Final state verification
            try std.testing.expect(engine.getWorkerState(BAKER_1).? == .Idle);
            try std.testing.expect(engine.getStorageHasItem(PANTRY_EIS).? == false);
            try std.testing.expect(engine.getStorageHasItem(TABLE_EOS).? == true);
        }

        pub fn @"two consecutive cycles with refill"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            // Setup with 2 EOS so second cycle has space
            try engine.addStorage(PANTRY_EIS, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(MIXER_IIS, .{ .role = .iis });
            try engine.addStorage(MIXER_IOS, .{ .role = .ios });
            try engine.addStorage(TABLE_EOS, .{ .role = .eos });
            try engine.addStorage(SECOND_EOS, .{ .role = .eos });
            try engine.addWorkstation(MIXER_WS, .{
                .eis = &.{PANTRY_EIS},
                .iis = &.{MIXER_IIS},
                .ios = &.{MIXER_IOS},
                .eos = &.{ TABLE_EOS, SECOND_EOS },
            });
            try engine.addWorker(BAKER_1);

            // First cycle
            _ = engine.workerAvailable(BAKER_1);
            _ = engine.pickupCompleted(BAKER_1);
            _ = engine.workCompleted(MIXER_WS);
            _ = engine.storeCompleted(BAKER_1);

            // Refill EIS for second cycle
            _ = engine.itemAdded(PANTRY_EIS, .Flour);

            engine.dispatcher.hooks.clear();

            // Worker should be idle, make available again
            _ = engine.workerAvailable(BAKER_1);

            // Should start second cycle
            try std.testing.expect(engine.getWorkerState(BAKER_1).? == .Working);
            _ = try engine.dispatcher.hooks.expectNext(.worker_assigned);

            // Complete second cycle
            _ = try engine.dispatcher.hooks.expectNext(.workstation_activated);
            _ = try engine.dispatcher.hooks.expectNext(.pickup_started);

            _ = engine.pickupCompleted(BAKER_1);
            _ = engine.workCompleted(MIXER_WS);
            _ = engine.storeCompleted(BAKER_1);

            // Both EOS should be full
            try std.testing.expect(engine.isStorageFull(TABLE_EOS));
            try std.testing.expect(engine.isStorageFull(SECOND_EOS));
        }
    });

    pub const concurrent_workers = zspec.describe("concurrent workers", struct {
        pub fn @"two workers operate two workstations independently"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            const ws_ids = try setupTwoWorkstations(&engine);

            try engine.addWorker(BAKER_1);
            try engine.addWorker(BAKER_2);

            // Both workers become available
            _ = engine.workerAvailable(BAKER_1);
            _ = engine.workerAvailable(BAKER_2);

            // Both should be working at different workstations
            try std.testing.expect(engine.getWorkerState(BAKER_1).? == .Working);
            try std.testing.expect(engine.getWorkerState(BAKER_2).? == .Working);

            const w1_ws = engine.getWorkerAssignment(BAKER_1).?;
            const w2_ws = engine.getWorkerAssignment(BAKER_2).?;
            try std.testing.expect(w1_ws != w2_ws);

            // Complete both cycles independently
            _ = engine.pickupCompleted(BAKER_1);
            _ = engine.pickupCompleted(BAKER_2);
            _ = engine.workCompleted(w1_ws);
            _ = engine.workCompleted(w2_ws);
            _ = engine.storeCompleted(BAKER_1);
            _ = engine.storeCompleted(BAKER_2);

            // Both should be idle now
            try std.testing.expect(engine.getWorkerState(BAKER_1).? == .Idle);
            try std.testing.expect(engine.getWorkerState(BAKER_2).? == .Idle);

            // Both EOS should have items — check via workstation assignment
            try std.testing.expect(engine.isStorageFull(4)); // WS_A_EOS
            try std.testing.expect(engine.isStorageFull(14)); // WS_B_EOS
            _ = ws_ids;
        }

        pub fn @"worker released from one workstation gets reassigned to another"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            _ = try setupTwoWorkstations(&engine);

            try engine.addWorker(BAKER_1);
            _ = engine.workerAvailable(BAKER_1);

            // Complete first workstation cycle
            const first_ws = engine.getWorkerAssignment(BAKER_1).?;
            _ = engine.pickupCompleted(BAKER_1);
            _ = engine.workCompleted(first_ws);
            _ = engine.storeCompleted(BAKER_1);

            // Worker should auto-assign to second workstation (still queued)
            try std.testing.expect(engine.getWorkerState(BAKER_1).? == .Working);
            const second_ws = engine.getWorkerAssignment(BAKER_1).?;
            try std.testing.expect(first_ws != second_ws);
        }
    });

    pub const dangling_items = zspec.describe("dangling item integration", struct {
        pub fn @"dangling item delivered to EIS triggers workstation"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            // Empty EIS — workstation is blocked
            try engine.addStorage(PANTRY_EIS, .{ .role = .eis, .accepts = .Flour });
            try engine.addStorage(MIXER_IIS, .{ .role = .iis });
            try engine.addStorage(MIXER_IOS, .{ .role = .ios });
            try engine.addStorage(TABLE_EOS, .{ .role = .eos });
            try engine.addWorkstation(MIXER_WS, .{
                .eis = &.{PANTRY_EIS},
                .iis = &.{MIXER_IIS},
                .ios = &.{MIXER_IOS},
                .eos = &.{TABLE_EOS},
            });

            try std.testing.expect(engine.getWorkstationStatus(MIXER_WS).? == .Blocked);

            // Two workers
            try engine.addWorker(BAKER_1);
            try engine.addWorker(BAKER_2);
            _ = engine.workerAvailable(BAKER_1);
            _ = engine.workerAvailable(BAKER_2);

            // Both idle (nothing to do)
            try std.testing.expect(engine.getWorkerState(BAKER_1).? == .Idle);
            try std.testing.expect(engine.getWorkerState(BAKER_2).? == .Idle);

            engine.dispatcher.hooks.clear();

            // Dangling item appears — one worker picks it up
            try engine.addDanglingItem(DANGLING_FLOUR_ID, .Flour);

            const dangling_pickup = try engine.dispatcher.hooks.expectNext(.pickup_dangling_started);
            try std.testing.expectEqual(Item.Flour, dangling_pickup.item_type);
            try std.testing.expectEqual(PANTRY_EIS, dangling_pickup.target_eis_id);

            // One worker is working (dangling), one idle
            const delivery_worker = dangling_pickup.worker_id;

            // Complete dangling delivery
            _ = engine.pickupCompleted(delivery_worker);
            _ = engine.storeCompleted(delivery_worker);

            // EIS should now have the item
            try std.testing.expect(engine.isStorageFull(PANTRY_EIS));
            try std.testing.expect(engine.getStorageItemType(PANTRY_EIS).? == .Flour);

            // Workstation should now be queued (has input)
            try std.testing.expect(engine.getWorkstationStatus(MIXER_WS).? == .Queued or
                engine.getWorkstationStatus(MIXER_WS).? == .Active);
        }
    });

    pub const producer_workflow = zspec.describe("producer workstation", struct {
        pub fn @"producer generates output without input"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            // Producer: no EIS/IIS, just IOS→EOS
            try engine.addStorage(MIXER_IOS, .{ .role = .ios });
            try engine.addStorage(TABLE_EOS, .{ .role = .eos });
            try engine.addWorkstation(MIXER_WS, .{
                .eis = &.{},
                .iis = &.{},
                .ios = &.{MIXER_IOS},
                .eos = &.{TABLE_EOS},
            });

            try engine.addWorker(BAKER_1);

            engine.dispatcher.hooks.clear();
            _ = engine.workerAvailable(BAKER_1);

            // Should go straight to process (no pickup)
            _ = try engine.dispatcher.hooks.expectNext(.worker_assigned);
            _ = try engine.dispatcher.hooks.expectNext(.workstation_activated);
            const process = try engine.dispatcher.hooks.expectNext(.process_started);
            try std.testing.expectEqual(MIXER_WS, process.workstation_id);

            // Complete cycle
            _ = engine.workCompleted(MIXER_WS);
            _ = engine.storeCompleted(BAKER_1);

            try std.testing.expect(engine.isStorageFull(TABLE_EOS));
            try std.testing.expect(engine.getWorkerState(BAKER_1).? == .Idle);
        }
    });

    pub const state_consistency = zspec.describe("state consistency", struct {
        pub fn @"engine counts remain consistent through full lifecycle"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            var counts = engine.getCounts();
            try std.testing.expectEqual(@as(u32, 0), counts.storages);

            try setupBasicWorkstation(&engine);
            try engine.addWorker(BAKER_1);

            counts = engine.getCounts();
            try std.testing.expectEqual(@as(u32, 4), counts.storages);
            try std.testing.expectEqual(@as(u32, 1), counts.workers);
            try std.testing.expectEqual(@as(u32, 1), counts.workstations);
            try std.testing.expectEqual(@as(u32, 1), counts.idle_workers);
            try std.testing.expectEqual(@as(u32, 1), counts.queued_workstations);

            // Assign worker
            _ = engine.workerAvailable(BAKER_1);

            counts = engine.getCounts();
            try std.testing.expectEqual(@as(u32, 0), counts.idle_workers);
            try std.testing.expectEqual(@as(u32, 0), counts.queued_workstations);

            // Complete cycle
            _ = engine.pickupCompleted(BAKER_1);
            _ = engine.workCompleted(MIXER_WS);
            _ = engine.storeCompleted(BAKER_1);

            counts = engine.getCounts();
            try std.testing.expectEqual(@as(u32, 1), counts.idle_workers);
            // Workstation blocked (EOS full, EIS empty)
            try std.testing.expectEqual(@as(u32, 0), counts.queued_workstations);
        }

        pub fn @"dumpState produces valid output"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            try setupBasicWorkstation(&engine);
            try engine.addWorker(BAKER_1);
            _ = engine.workerAvailable(BAKER_1);

            var list: std.ArrayListUnmanaged(u8) = .{};
            defer list.deinit(std.testing.allocator);
            try engine.dumpState(list.writer(std.testing.allocator));

            const output = list.items;
            try std.testing.expect(output.len > 0);
            try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Task Engine State"));
            try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Storages: 4"));
        }
    });

    pub const multi_ingredient = zspec.describe("multi-ingredient workflow", struct {
        pub fn @"workstation with two EIS requires both ingredients"() !void {
            var engine = createEngine();
            defer deinitEngine(&engine);

            // Two EIS (Flour + Water), two IIS
            const FLOUR_EIS: u32 = 1;
            const WATER_EIS: u32 = 5;
            const IIS_1: u32 = 2;
            const IIS_2: u32 = 6;
            const IOS: u32 = 3;
            const EOS: u32 = 4;
            const WS_ID: u32 = 100;

            try engine.addStorage(FLOUR_EIS, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(WATER_EIS, .{ .role = .eis, .initial_item = .Water });
            try engine.addStorage(IIS_1, .{ .role = .iis });
            try engine.addStorage(IIS_2, .{ .role = .iis });
            try engine.addStorage(IOS, .{ .role = .ios });
            try engine.addStorage(EOS, .{ .role = .eos });

            try engine.addWorkstation(WS_ID, .{
                .eis = &.{ FLOUR_EIS, WATER_EIS },
                .iis = &.{ IIS_1, IIS_2 },
                .ios = &.{IOS},
                .eos = &.{EOS},
            });

            try engine.addWorker(BAKER_1);

            engine.dispatcher.hooks.clear();
            _ = engine.workerAvailable(BAKER_1);

            // First pickup
            _ = try engine.dispatcher.hooks.expectNext(.worker_assigned);
            _ = try engine.dispatcher.hooks.expectNext(.workstation_activated);
            _ = try engine.dispatcher.hooks.expectNext(.pickup_started);

            engine.dispatcher.hooks.clear();
            _ = engine.pickupCompleted(BAKER_1);

            // Should get second pickup (not process yet — need both ingredients)
            const second_pickup = try engine.dispatcher.hooks.expectNext(.pickup_started);
            try std.testing.expect(second_pickup.storage_id == FLOUR_EIS or second_pickup.storage_id == WATER_EIS);

            engine.dispatcher.hooks.clear();
            _ = engine.pickupCompleted(BAKER_1);

            // Now both IIS filled — process should start
            _ = try engine.dispatcher.hooks.expectNext(.process_started);
        }
    });
});
