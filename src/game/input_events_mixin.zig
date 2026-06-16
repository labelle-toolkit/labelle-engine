/// Input-events mixin — the per-tick input edge scanning that turns
/// keyboard / mouse / gamepad state into buffered engine events
/// (labelle-gui#208, core#18), the `ControllerManager` drain + auto-pause
/// policy (#611), and the game-facing controller assignment/query API.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. The comptime
/// gate consts (`keyboard_events_wanted`, … `backend_polls_gamepads`) and
/// `ControllerManagerType` stay defined on `Game` — they're shared with the
/// struct's field declarations and `init`/`deinit` — and are read here via
/// `Game.<gate>` so there is a single comptime source of truth (no risk of
/// the mixin computing a divergent value).
const std = @import("std");
const core = @import("labelle-core");
const input_types = @import("../input_types.zig");
const controller_manager_mod = @import("../controller_manager.zig");

/// Fixed scratch capacity for draining gamepad hotplug events per tick
/// (core#18). Mirrors `game.zig`'s `gamepad_drain_capacity`.
const gamepad_drain_capacity = 16;

/// Returns the input-events mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const keyboard_events_wanted = Game.keyboard_events_wanted;
    const mouse_events_wanted = Game.mouse_events_wanted;
    const gamepad_events_wanted = Game.gamepad_events_wanted;
    const controller_events_wanted = Game.controller_events_wanted;
    const backend_polls_gamepads = Game.backend_polls_gamepads;
    const engineEventWanted = Game.engineEventWanted;
    const ControllerManagerType = Game.ControllerManagerType;

    return struct {
        // ── ControllerManager game-facing API (#611) ─────────────────
        //
        // Thin forwarders over the embedded `controller_manager` so game
        // scripts and plugins reach the assignment/query API without poking
        // the field directly. Available only when the project's
        // `GameEvents` carries a player-level controller variant — calling
        // any of these in a game that doesn't is a compile error (the
        // manager field is `void`), which is the intended guard rail.

        /// Mutable handle to the embedded `ControllerManager`. Use for the
        /// full API (iteration, `availableControllers`, opt-in helpers like
        /// `autoBindFreeSlots` / `joinOnButton`). Requires a controller
        /// event in `GameEvents`.
        pub fn controllerManager(self: *Game) *ControllerManagerType {
            comptime if (!controller_events_wanted)
                @compileError("controllerManager() requires a player-level controller event " ++
                    "(engine.player_joined / controller_available / ...) in GameEvents");
            return &self.controller_manager;
        }

        /// Assign an unassigned `controller` to `player`. Emits
        /// `player_joined` on the next `dispatchEvents`. Errors if the
        /// player id is out of range or the controller isn't in the pool.
        pub fn assignController(self: *Game, controller: u32, player: u32) !void {
            comptime if (!controller_events_wanted)
                @compileError("assignController() requires a player-level controller event in GameEvents");
            try self.controller_manager.assign(controller, player);
            drainControllerManagerEvents(self);
        }

        /// Release a player's controller binding, returning the controller
        /// (if still present) to the unassigned pool.
        pub fn unassignPlayer(self: *Game, player: u32) void {
            comptime if (!controller_events_wanted)
                @compileError("unassignPlayer() requires a player-level controller event in GameEvents");
            self.controller_manager.unassign(player);
            drainControllerManagerEvents(self);
        }

        /// The player a controller is bound to, or `NO_PLAYER`.
        pub fn playerForController(self: *Game, controller: u32) u32 {
            comptime if (!controller_events_wanted)
                @compileError("playerForController() requires a player-level controller event in GameEvents");
            return self.controller_manager.playerFor(controller);
        }

        /// The controller currently backing a player, or `NO_CONTROLLER`.
        pub fn controllerForPlayer(self: *Game, player: u32) u32 {
            comptime if (!controller_events_wanted)
                @compileError("controllerForPlayer() requires a player-level controller event in GameEvents");
            return self.controller_manager.controllerFor(player);
        }

        /// Toggle the opt-in auto-pause policy (#465 precedent): when on, a
        /// real `player_controller_lost` drives `setPaused(true)`, and the
        /// game resumes once every player is whole again. OFF by default —
        /// the engine never forces a pause.
        pub fn setAutoPauseOnControllerLost(self: *Game, enabled: bool) void {
            self.auto_pause_on_controller_lost = enabled;
        }

        // ── Input events (labelle-gui#208) ───────────────────────

        /// Scan the unified `InputInterface` for input edges and emit
        /// the matching engine events into the buffer. Every query goes
        /// through `Game.Input` (the backend-agnostic wrapper) — never a
        /// backend's native API — which is what keeps this portable
        /// across raylib / sokol / SDL. Called from `tick` while input
        /// state is still current; buffered events drain via
        /// `dispatchEvents` the same frame.
        pub fn scanInputEvents(self: *Game) void {
            // Each category's emit calls are gated at comptime (so an
            // unused one folds away), but the per-element scans are plain
            // RUNTIME `for`s over the comptime enum-value slices — NOT
            // `inline for`. Unrolling ~114 keys would inline
            // `emitEngineEvent` (itself an `inline for` over payload
            // fields) once per key, bloating the binary and needing a big
            // `@setEvalBranchQuota`; a runtime loop has one call site per
            // category (gemini #606).

            // ── Keyboard ──
            if (comptime keyboard_events_wanted) {
                const pressed_wanted = comptime engineEventWanted("engine__key_pressed");
                const released_wanted = comptime engineEventWanted("engine__key_released");
                for (std.enums.values(input_types.KeyboardKey)) |k| {
                    if (k == .key_null) continue; // sentinel, not a real key
                    const code: u32 = @intCast(@intFromEnum(k));
                    if (pressed_wanted and Game.Input.isKeyPressed(code))
                        self.emitEngineEvent("engine__key_pressed", .{ .key = code });
                    if (released_wanted and Game.Input.isKeyReleased(code))
                        self.emitEngineEvent("engine__key_released", .{ .key = code });
                }
            }

            // ── Mouse buttons ──
            if (comptime mouse_events_wanted) {
                const pressed_wanted = comptime engineEventWanted("engine__mouse_button_pressed");
                const released_wanted = comptime engineEventWanted("engine__mouse_button_released");
                for (std.enums.values(input_types.MouseButton)) |b| {
                    const code: u32 = @intCast(@intFromEnum(b));
                    if (pressed_wanted and Game.Input.isMouseButtonPressed(code))
                        self.emitEngineEvent("engine__mouse_button_pressed", .{
                            .button = code,
                            .x = Game.Input.getMouseX(),
                            .y = Game.Input.getMouseY(),
                        });
                    if (released_wanted and Game.Input.isMouseButtonReleased(code))
                        self.emitEngineEvent("engine__mouse_button_released", .{
                            .button = code,
                            .x = Game.Input.getMouseX(),
                            .y = Game.Input.getMouseY(),
                        });
                }
            }
        }

        /// Drain gamepad hotplug events (core#18) and the
        /// `ControllerManager` (#611). Split OUT of `scanInputEvents`
        /// because it MUST run every frame, INCLUDING while paused: when
        /// the opt-in auto-pause gates the game on a lost controller, the
        /// reconnect that lifts the pause arrives as a gamepad event — if we
        /// only scanned in the active-frame body (past the pause gate) the
        /// game would deadlock paused forever. Keyboard/mouse scanning stays
        /// gameplay-only in `scanInputEvents`.
        pub fn scanGamepadEvents(self: *Game) void {
            // ── Gamepad connect / disconnect (drained queue, core#18) ──
            //
            // Drain hotplug events from a single source — picked at
            // comptime by `backend_polls_gamepads` so the backend and the
            // per-OS `gamepad_source` never both run — and emit one engine
            // event per drained `GamepadEvent`. No fixed 4-slot cap and no
            // engine-side prev-state diff: edge detection now belongs to
            // the source. The whole block folds away when no flow listens
            // (the `comptime gamepad_events_wanted` gate), so it stays
            // zero-cost — and on the fallback path that also means
            // `gamepad_source.pollEvents` is never called.
            if (comptime gamepad_events_wanted) {
                const conn_wanted = comptime engineEventWanted("engine__gamepad_connected");
                const disc_wanted = comptime engineEventWanted("engine__gamepad_disconnected");

                var buf: [gamepad_drain_capacity]core.gamepad.GamepadEvent = undefined;
                const n = if (comptime backend_polls_gamepads)
                    Game.Input.pollGamepadEvents(&buf)
                else
                    core.gamepad_source.pollEvents(&buf);

                for (buf[0..n]) |ev| {
                    switch (ev.kind) {
                        .connected => if (conn_wanted) self.emitEngineEvent(
                            "engine__gamepad_connected",
                            .{
                                .id = ev.slot,
                                .name = ev.name,
                                .name_len = ev.name_len,
                                .guid = ev.guid,
                                .source_class = ev.source_class,
                                .type_hint = ev.type_hint,
                            },
                        ),
                        .disconnected => if (disc_wanted) self.emitEngineEvent(
                            "engine__gamepad_disconnected",
                            .{ .id = ev.slot },
                        ),
                    }
                    // The ControllerManager consumes the SAME drained
                    // events (#611). Feed it here so a project listening to
                    // a player-level event but NOT the raw `gamepad_*` pair
                    // still drives the mapping layer.
                    if (comptime controller_events_wanted) {
                        switch (ev.kind) {
                            .connected => self.controller_manager.onConnected(ev),
                            .disconnected => self.controller_manager.onDisconnected(ev.slot),
                        }
                    }
                }
            }

            // Advance the manager's debounce clock and drain its
            // player-level output into engine events (#611). The clock is
            // the pause-aware gameplay clock, so a debounce window measured
            // in seconds holds correctly behind a pause menu. Runs after the
            // feed above so a connect+expire within one tick is consistent.
            if (comptime controller_events_wanted) {
                self.controller_manager.advance(self.elapsedSeconds());
                drainControllerManagerEvents(self);
            }
        }

        /// Pull the `ControllerManager`'s pending player-level events and
        /// re-emit each as the matching engine event, applying the opt-in
        /// auto-pause policy (#611). Folds away unless a controller event is
        /// wanted.
        pub fn drainControllerManagerEvents(self: *Game) void {
            if (comptime !controller_events_wanted) return;
            var evbuf: [ControllerManagerType.event_capacity]controller_manager_mod.ManagerEvent = undefined;
            const m = self.controller_manager.drainEvents(&evbuf);
            for (evbuf[0..m]) |mev| {
                switch (mev) {
                    .controller_available => |c| self.emitEngineEvent("engine__controller_available", .{
                        .controller_id = c.controller_id,
                        .name = c.name,
                        .name_len = c.name_len,
                        .guid = c.guid,
                        .source_class = c.source_class,
                        .type_hint = c.type_hint,
                    }),
                    .controller_removed => |c| self.emitEngineEvent("engine__controller_removed", .{
                        .controller_id = c.controller_id,
                    }),
                    .player_joined => |p| self.emitEngineEvent("engine__player_joined", .{
                        .player = p.player,
                        .controller_id = p.controller_id,
                    }),
                    .player_controller_lost => |p| {
                        self.emitEngineEvent("engine__player_controller_lost", .{ .player = p.player });
                        // Opt-in auto-pause (#465 precedent): a real loss
                        // gates the game until the controller is back.
                        if (self.auto_pause_on_controller_lost) self.setPaused(true);
                    },
                    .player_controller_restored => |p| {
                        self.emitEngineEvent("engine__player_controller_restored", .{
                            .player = p.player,
                            .controller_id = p.controller_id,
                        });
                        // Resume only once NO player is still waiting — with
                        // multiple lost pads we stay paused until the last
                        // one reconnects.
                        if (self.auto_pause_on_controller_lost and !anyPlayerWaiting(self)) {
                            self.setPaused(false);
                        }
                    },
                }
            }
        }

        /// `true` when any active player's controller is currently absent
        /// (debouncing or lost). Drives the auto-pause resume gate.
        pub fn anyPlayerWaiting(self: *const Game) bool {
            if (comptime !controller_events_wanted) return false;
            var p: u32 = 0;
            while (p < ControllerManagerType.capacity_players) : (p += 1) {
                if (self.controller_manager.isPlayerWaiting(p)) return true;
            }
            return false;
        }
    };
}
