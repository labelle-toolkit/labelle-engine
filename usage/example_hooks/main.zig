// Example: Hook System with Two-Way Plugin Binding
//
// Demonstrates the labelle-engine hook system:
// 1. Game hooks for engine lifecycle events
// 2. Plugin hooks that the game can subscribe to
// 3. MergeEngineHooks to combine game + plugin engine hooks
//
// This shows the "two-way binding" pattern:
// - Plugins listen to engine hooks (plugin -> engine)
// - Game listens to plugin hooks (engine -> plugin)

const std = @import("std");
const engine = @import("labelle-engine");

// ============================================
// Example Plugin: Task Scheduler
// ============================================
// A plugin that schedules and executes tasks over time.
// Uses engine hooks to:
// - Initialize on game_init
// - Process tasks on frame_start
// - Clean up on game_deinit

/// Example plugin that demonstrates practical use of engine hooks.
/// In a real project, this would be in a separate package (e.g., labelle-tasks).
const TasksPlugin = struct {
    // ---- Plugin State ----
    // In a real plugin, this would be managed differently (passed via context, etc.)
    // For this example, we use module-level state for simplicity.

    var initialized: bool = false;
    var current_time: f32 = 0;
    var tasks_completed: u32 = 0;

    const ScheduledTask = struct {
        id: u32,
        name: []const u8,
        execute_at: f32, // seconds from start
        completed: bool = false,
    };

    var scheduled_tasks: [10]ScheduledTask = undefined;
    var task_count: usize = 0;

    // ---- Public API ----

    pub fn scheduleTask(name: []const u8, delay_seconds: f32) u32 {
        if (task_count >= scheduled_tasks.len) return 0;

        const id: u32 = @intCast(task_count + 1);
        scheduled_tasks[task_count] = .{
            .id = id,
            .name = name,
            .execute_at = current_time + delay_seconds,
        };
        task_count += 1;

        std.log.info("[tasks] Scheduled task #{d} '{s}' for t={d:.2}s", .{
            id,
            name,
            current_time + delay_seconds,
        });

        return id;
    }

    pub fn getCompletedCount() u32 {
        return tasks_completed;
    }

    pub fn isInitialized() bool {
        return initialized;
    }

    // ---- Engine Hooks (plugin listens to engine) ----

    pub const EngineHooks = struct {
        /// Called when game initializes - plugin sets up its state
        pub fn game_init(_: engine.HookPayload) void {
            std.log.info("[tasks] Plugin initializing...", .{});

            initialized = true;
            current_time = 0;
            tasks_completed = 0;
            task_count = 0;

            std.log.info("[tasks] Plugin ready! Use TasksPlugin.scheduleTask() to queue work.", .{});
        }

        /// Called each frame - plugin processes scheduled tasks
        pub fn frame_start(payload: engine.HookPayload) void {
            if (!initialized) return;

            const info = payload.frame_start;
            current_time += info.dt;

            // Check for tasks that should execute
            for (&scheduled_tasks, 0..) |*task, i| {
                if (i >= task_count) break;
                if (task.completed) continue;

                if (current_time >= task.execute_at) {
                    // Execute the task
                    task.completed = true;
                    tasks_completed += 1;

                    std.log.info("[tasks] Executing task #{d} '{s}' at t={d:.2}s", .{
                        task.id,
                        task.name,
                        current_time,
                    });

                    // Emit event for game to react to
                    const dispatcher = Dispatcher(GameTasksHandlers);
                    dispatcher.emit(.{ .task_completed = .{
                        .id = task.id,
                        .name = task.name,
                    } });
                }
            }
        }

        /// Called when game shuts down - plugin cleans up
        pub fn game_deinit(_: engine.HookPayload) void {
            std.log.info("[tasks] Plugin shutting down. Completed {d} tasks total.", .{tasks_completed});
            initialized = false;
        }

        /// Called when scene loads - plugin could load scene-specific tasks
        pub fn scene_load(payload: engine.HookPayload) void {
            const info = payload.scene_load;
            std.log.info("[tasks] Scene '{s}' loaded - plugin could load scene-specific tasks here", .{info.name});
        }
    };

    // ---- Plugin Hooks (game listens to plugin) ----

    pub const Hook = enum {
        task_completed,
        task_started,
    };

    pub const TaskInfo = struct {
        id: u32,
        name: []const u8,
    };

    pub const Payload = union(Hook) {
        task_completed: TaskInfo,
        task_started: TaskInfo,
    };

    /// Create a dispatcher for game to listen to plugin hooks
    pub fn Dispatcher(comptime GameHandlers: type) type {
        return engine.HookDispatcher(Hook, Payload, GameHandlers);
    }
};

// ============================================
// Game's Hook Handlers
// ============================================

// Game's own engine hook handlers
const GameHooks = struct {
    pub fn game_init(_: engine.HookPayload) void {
        std.log.info("[game] Game initialized", .{});
    }

    /// Schedule tasks after plugin is ready (called from scene load)
    pub fn scheduleDemoTasks() void {
        // Schedule some tasks using the plugin's API
        // The plugin will process these during frame_start hooks
        _ = TasksPlugin.scheduleTask("Load player data", 0.5);
        _ = TasksPlugin.scheduleTask("Initialize AI", 1.0);
        _ = TasksPlugin.scheduleTask("Start background music", 1.5);
    }

    pub fn game_deinit(_: engine.HookPayload) void {
        std.log.info("[game] Game shutting down", .{});
    }

    pub fn frame_start(payload: engine.HookPayload) void {
        const info = payload.frame_start;
        // Log every 60 frames
        if (info.frame_number % 60 == 0 and info.frame_number > 0) {
            std.log.info("[game] Frame {d}, plugin completed {d} tasks so far", .{
                info.frame_number,
                TasksPlugin.getCompletedCount(),
            });
        }
    }

    pub fn scene_load(payload: engine.HookPayload) void {
        const info = payload.scene_load;
        std.log.info("[game] Scene loaded: {s}", .{info.name});
    }
};

// Game's handlers for plugin hooks (game subscribes to plugin events)
const GameTasksHandlers = struct {
    pub fn task_completed(payload: TasksPlugin.Payload) void {
        const info = payload.task_completed;
        std.log.info("[game] Received task_completed event: #{d} '{s}'", .{ info.id, info.name });

        // Game can react to plugin events
        // e.g., update UI, trigger animations, unlock features, etc.
    }

    pub fn task_started(payload: TasksPlugin.Payload) void {
        const info = payload.task_started;
        std.log.info("[game] Received task_started event: #{d} '{s}'", .{ info.id, info.name });
    }
};

// ============================================
// Combine Everything
// ============================================

// Merge game hooks with plugin's engine hooks
// Order matters: handlers are called in order, so GameHooks runs first, then plugin
const AllEngineHooks = engine.MergeEngineHooks(.{
    GameHooks,
    TasksPlugin.EngineHooks,
});

// Create Game type with merged hooks
const Game = engine.GameWith(AllEngineHooks);

// ============================================
// Main
// ============================================

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("", .{});
    std.log.info("=== Two-Way Plugin Hook Binding Example ===", .{});
    std.log.info("", .{});
    std.log.info("This example shows:", .{});
    std.log.info("  1. Plugin receives engine hooks (game_init, frame_start, etc.)", .{});
    std.log.info("  2. Plugin uses hooks to manage its own state", .{});
    std.log.info("  3. Plugin emits events that game can react to", .{});
    std.log.info("", .{});

    // Initialize game
    // This triggers: GameHooks.game_init -> TasksPlugin.EngineHooks.game_init
    var game = try Game.init(allocator, .{
        .window = .{
            .width = 800,
            .height = 600,
            .title = "Two-Way Hook Binding Example",
            .hidden = ci_test,
        },
    });
    game.fixPointers();
    defer game.deinit(); // Triggers: GameHooks.game_deinit -> TasksPlugin.EngineHooks.game_deinit

    // Register and load scene
    try game.registerSceneSimple("main", loadMainScene);
    try game.setScene("main");

    std.log.info("", .{});
    std.log.info("--- Running game loop (tasks will complete over time) ---", .{});
    std.log.info("", .{});

    // Run the game - each frame triggers frame_start for both game and plugin
    // The plugin processes scheduled tasks and emits task_completed events
    try game.runWithCallback(if (ci_test) ciTestCallback else null);
}

var ci_frame_count: u32 = 0;
fn ciTestCallback(game_ptr: *Game, _: f32) void {
    ci_frame_count += 1;
    // Run for ~2 seconds worth of frames to see tasks complete
    if (ci_frame_count >= 120) {
        game_ptr.quit();
    }
}

fn loadMainScene(_: *Game) !void {
    std.log.info("[game] Loading main scene content...", .{});

    // Schedule demo tasks now that the plugin is initialized
    GameHooks.scheduleDemoTasks();
}
