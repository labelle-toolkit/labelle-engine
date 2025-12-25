// Example: Task hooks for labelle-tasks plugin
//
// This file demonstrates the task hook pattern. When the generator finds
// any of these hook functions, it automatically:
// 1. Detects the labelle-tasks plugin in project.labelle
// 2. Generates a TaskEngine type with these hooks wired up
// 3. Makes TaskEngine available as a public type in main.zig
//
// Available task hooks:
// - pickup_started: Worker starts moving to EIS for pickup
// - process_started: Worker begins processing at workstation
// - store_started: Worker starts moving to EOS for storage
// - worker_released: Worker is released from workstation
//
// Additional hooks available in EngineWithHooks:
// - process_completed, worker_assigned, workstation_blocked/queued/activated
// - transport_started/completed, cycle_completed

const std = @import("std");
const tasks = @import("labelle_tasks");

// Import the item types directly
const items = @import("../components/items.zig");

// Type alias for our hook payload
const HookPayload = tasks.hooks.HookPayload(u32, items.ItemType);

/// Called when a worker starts the pickup step.
/// Game should start worker movement animation toward the EIS.
pub fn pickup_started(payload: HookPayload) void {
    const info = payload.pickup_started;
    std.log.info("[tasks] Pickup started: worker={d}, workstation={d}, eis={d}", .{
        info.worker_id,
        info.workstation_id,
        info.eis_id,
    });
    // In a real game:
    // - Start worker walk animation toward EIS
    // - Play pickup sound
    // - Show UI indicator
}

/// Called when a worker starts the process step.
/// Engine handles timing; game can play animations.
pub fn process_started(payload: HookPayload) void {
    const info = payload.process_started;
    std.log.info("[tasks] Process started: worker={d}, workstation={d}", .{
        info.worker_id,
        info.workstation_id,
    });
    // In a real game:
    // - Start crafting animation
    // - Play workstation sounds
    // - Show progress bar
}

/// Called when a worker starts the store step.
/// Game should start worker movement animation toward the EOS.
pub fn store_started(payload: HookPayload) void {
    const info = payload.store_started;
    std.log.info("[tasks] Store started: worker={d}, workstation={d}, eos={d}", .{
        info.worker_id,
        info.workstation_id,
        info.eos_id,
    });
    // In a real game:
    // - Start worker walk animation toward EOS
    // - Worker should be carrying the output item
}

/// Called when a worker is released from a workstation.
/// Worker becomes idle and can be assigned to new work.
pub fn worker_released(payload: HookPayload) void {
    const info = payload.worker_released;
    std.log.info("[tasks] Worker released: worker={d}, workstation={d}", .{
        info.worker_id,
        info.workstation_id,
    });
    // In a real game:
    // - Play completion sound
    // - Update worker state/animation to idle
    // - Maybe show floating +1 or completion effect
}
