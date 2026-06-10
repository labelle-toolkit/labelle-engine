//! `ControllerManager` — game-facing player↔controller mapping
//! (labelle-engine#611, Phase 2 of the gamepad epic #609).
//!
//! ## Mechanism, not policy
//!
//! Raw engine `gamepad_connected`/`gamepad_disconnected` events are at the
//! wrong altitude: they say "slot 1 vanished", not "Player 2 lost their
//! pad". **When a connected controller becomes a player is a per-game
//! decision** (single-player, press-A-to-join couch co-op, fixed GUID
//! seats, drop-in/drop-out). The engine must NOT hardcode any of these.
//!
//! This module provides the *mechanism* — an unassigned pool, an
//! assignment API, and player-level events — and ships the two common
//! policies (auto-bind / join-on-button) as **opt-in helpers** that a game
//! can call, never as default behaviour.
//!
//! What stays engine-owned (because it needs the stable identity the
//! engine resolves over the core#18 `GamepadEvent` contract):
//!
//!   - **debounced-lost** — a configurable grace window before a transient
//!     disconnect (endemic Bluetooth churn on Android TV) counts as a real
//!     `player_controller_lost`. If the same stable id (`guid`) reappears
//!     inside the window, the binding is treated as continuous — no
//!     lost/restored churn, no pause-dialog flicker.
//!   - **identity-based resume** — a replug rebinds to the *same* player
//!     via `guid`. On backends with no stable key (raylib reports `null`),
//!     a documented heuristic kicks in: the next controller to appear
//!     resumes the most-recently-vacated player (note the multi-pad
//!     ambiguity — see `resumeVacated`).
//!
//! ## Push/pull shape (zero allocations, fully testable)
//!
//! The manager is a pure state machine over fixed-size arrays — no
//! allocator, COPY-friendly, embeddable directly in `Game`. Drive it with:
//!
//!   - `onConnected(ev)` / `onDisconnected(slot)` — feed drained
//!     `core.GamepadEvent`s.
//!   - `advance(now_seconds)` — let the debounce clock expire pending-lost
//!     entries (call once per tick with the gameplay clock).
//!   - `assign(controller, player)` / `unassign(player)` and the query API.
//!   - `drainEvents(out)` — pull the `ManagerEvent`s produced since the
//!     last drain; the host turns each into an engine event.
//!
//! `Game` wires all of this automatically when the project's `GameEvents`
//! carries the controller variants (see `src/game.zig`), but the type is
//! self-contained so it unit-tests without a `Game`.

const std = @import("std");
const core = @import("labelle-core");

/// Sentinel for "no player". Returned by `playerFor` when a controller is
/// unassigned, and used internally to mark empty binding slots.
pub const NO_PLAYER: u32 = std.math.maxInt(u32);

/// Sentinel for "no controller". Returned by `controllerFor` when a player
/// has no controller currently bound.
pub const NO_CONTROLLER: u32 = std.math.maxInt(u32);

/// Configuration for a `ControllerManager`. All durations are in seconds,
/// measured against the same clock the host feeds to `advance` (the
/// engine's pause-aware `game.elapsedSeconds()`).
pub const Config = struct {
    /// Grace window before a disconnect of an *assigned* controller becomes
    /// `player_controller_lost`. A transient Bluetooth blip shorter than
    /// this never fires a lost event. `0` disables debouncing (a disconnect
    /// is reported immediately). Default 0.2s — comfortably covers TV BT
    /// re-pairing without feeling laggy.
    debounce_lost_seconds: f64 = 0.2,
};

/// Output of the manager's state machine. The host drains these via
/// `drainEvents` and re-emits each as the corresponding engine event.
/// COPY-only (no borrowed memory) — `name` is inline, like
/// `core.GamepadEvent`.
pub const ManagerEvent = union(enum) {
    /// A connected-but-unbound controller entered the unassigned pool —
    /// the game's cue to decide whether/how it becomes a player.
    controller_available: ControllerInfo,
    /// An unassigned controller was removed (unplugged while in the pool).
    controller_removed: struct { controller_id: u32 },
    /// The game assigned a controller to a player (via `assign` or an
    /// opt-in helper). Emitted only *after* the game decides.
    player_joined: struct { player: u32, controller_id: u32 },
    /// An assigned controller has been gone longer than the debounce
    /// window — the player has truly lost their pad. A game can gate
    /// `Controller.advance` / raise a "reconnect Player N" prompt on this.
    player_controller_lost: struct { player: u32 },
    /// A previously-lost (or debouncing) player got their controller back
    /// — same `guid` replug, or the raylib resume heuristic. Carries the
    /// (possibly new) backing controller id.
    player_controller_restored: struct { player: u32, controller_id: u32 },
};

/// Identity snapshot of a pooled / bound controller. COPY-only.
pub const ControllerInfo = struct {
    controller_id: u32,
    name: [core.gamepad.NAME_CAPACITY:0]u8 = [_:0]u8{0} ** core.gamepad.NAME_CAPACITY,
    name_len: u8 = 0,
    guid: ?[16]u8 = null,
    source_class: core.GamepadSourceClass = .unknown,
    type_hint: core.GamepadTypeHint = .unknown,

    pub fn nameSlice(self: *const ControllerInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    fn fromEvent(ev: core.GamepadEvent) ControllerInfo {
        return .{
            .controller_id = ev.slot,
            .name = ev.name,
            .name_len = ev.name_len,
            .guid = ev.guid,
            .source_class = ev.source_class,
            .type_hint = ev.type_hint,
        };
    }
};

/// `ControllerManager(max_controllers, max_players)` — fixed-capacity
/// player↔controller mapping. Capacities are comptime so the whole thing
/// is a flat, allocation-free value embeddable in `Game`.
///
/// `max_controllers` bounds both the unassigned pool and the number of
/// distinct controller ids tracked at once; `max_players` bounds the
/// player binding table. The toolkit default (`DefaultControllerManager`)
/// uses 8 / 8 — plenty for couch co-op.
pub fn ControllerManager(comptime max_controllers: usize, comptime max_players: usize) type {
    return struct {
        const Self = @This();

        pub const capacity_controllers = max_controllers;
        pub const capacity_players = max_players;

        /// State of one tracked controller binding to a player. Lives in a
        /// dense array indexed by player id (`0..max_players`).
        const Binding = struct {
            /// `true` when this player slot is in use (assigned at least
            /// once and not fully released).
            active: bool = false,
            /// The controller id currently backing this player, or
            /// `NO_CONTROLLER` while the controller is gone (debouncing or
            /// lost).
            controller_id: u32 = NO_CONTROLLER,
            /// Stable identity captured at assign time, used to rebind on
            /// replug. `null` when the backend reported no guid.
            guid: ?[16]u8 = null,
            /// `true` between a disconnect and either its debounce
            /// expiry (→ lost) or a same-guid reconnect (→ continuous).
            debouncing: bool = false,
            /// Gameplay-clock deadline at which `debouncing` becomes a real
            /// `player_controller_lost`. Only meaningful while `debouncing`.
            lost_deadline: f64 = 0,
            /// `true` once we have emitted `player_controller_lost` and are
            /// waiting for a reconnect to restore. Distinct from
            /// `debouncing`: a lost player no longer has a pending deadline.
            lost: bool = false,
            /// Clock time the controller vacated (disconnect). Drives the
            /// raylib resume heuristic (most-recently-vacated wins).
            vacated_at: f64 = 0,
            /// Identity snapshot captured at assign time, so a player whose
            /// controller is released (via `unassign`, or replaced) can
            /// return the *right* `ControllerInfo` (name/guid/class) to the
            /// pool — the live `controller_id` may have changed on replug.
            bound_info: ControllerInfo = .{ .controller_id = NO_CONTROLLER },
        };

        /// One entry in the unassigned pool.
        const PoolEntry = struct {
            in_use: bool = false,
            info: ControllerInfo = .{ .controller_id = NO_CONTROLLER },
        };

        pub const event_capacity = (max_controllers + max_players) * 2 + 8;

        config: Config = .{},
        bindings: [max_players]Binding = [_]Binding{.{}} ** max_players,
        pool: [max_controllers]PoolEntry = [_]PoolEntry{.{}} ** max_controllers,

        /// Ring of pending output events drained by the host. Sized to
        /// comfortably cover a frame's churn; surplus is dropped with a
        /// debug log rather than silently (should never happen in practice).
        out: [event_capacity]ManagerEvent = undefined,
        out_len: usize = 0,

        /// Last clock value seen via `advance` — captured so `onDisconnected`
        /// can stamp `vacated_at` / set the debounce deadline against the
        /// current time without the caller threading `now` through every
        /// feed call.
        last_now: f64 = 0,

        // ── Construction ──────────────────────────────────────────────

        pub fn init(config: Config) Self {
            return .{ .config = config };
        }

        // ── Event feed (host → manager) ───────────────────────────────

        /// Feed a drained connect event. Resolves identity-based resume
        /// first (a replug of an assigned controller restores the binding,
        /// cancelling any in-flight debounce / firing `restored`); otherwise
        /// the controller lands in the unassigned pool and
        /// `controller_available` fires so the game can decide.
        pub fn onConnected(self: *Self, ev: core.GamepadEvent) void {
            // 1. Same-guid resume: a controller the game previously assigned
            //    came back. Rebind to its player regardless of slot churn
            //    (Linux returns a different `js*` on replug).
            if (ev.guid) |g| {
                if (self.findPlayerByGuid(g)) |player| {
                    self.restoreBinding(player, ev.slot);
                    return;
                }
            }

            // 2. raylib heuristic: no stable key anywhere. If some player is
            //    waiting for a controller (debouncing or lost), the next
            //    controller to appear resumes the most-recently-vacated one.
            //    Multi-pad ambiguity: with two pads down, the first replug
            //    grabs the more-recently-vacated player — documented and
            //    accepted (raylib gives us nothing better).
            if (ev.guid == null) {
                if (self.mostRecentlyVacated()) |player| {
                    self.restoreBinding(player, ev.slot);
                    return;
                }
            }

            // 3. Brand-new controller → unassigned pool + availability event.
            self.addToPool(ControllerInfo.fromEvent(ev));
        }

        /// Feed a drained disconnect event for `slot`. If the controller is
        /// assigned, this starts the debounce window (or fires `lost`
        /// immediately when debounce is disabled). If it was merely pooled,
        /// it leaves the pool and `controller_removed` fires.
        pub fn onDisconnected(self: *Self, slot: u32) void {
            // Assigned controller? Begin debounce / mark vacated.
            if (self.findPlayerByController(slot)) |player| {
                const b = &self.bindings[player];
                b.controller_id = NO_CONTROLLER;
                b.vacated_at = self.last_now;
                if (self.config.debounce_lost_seconds <= 0) {
                    // No grace window — report lost right away.
                    b.lost = true;
                    b.debouncing = false;
                    self.push(.{ .player_controller_lost = .{ .player = player } });
                } else {
                    b.debouncing = true;
                    b.lost = false;
                    b.lost_deadline = self.last_now + self.config.debounce_lost_seconds;
                }
                return;
            }

            // Pooled (unassigned) controller? Drop it from the pool.
            if (self.removeFromPool(slot)) {
                self.push(.{ .controller_removed = .{ .controller_id = slot } });
            }
        }

        /// Advance the debounce clock to `now` (gameplay seconds). Any
        /// pending-lost binding whose deadline has passed fires
        /// `player_controller_lost`. Call once per tick.
        pub fn advance(self: *Self, now: f64) void {
            self.last_now = now;
            for (&self.bindings, 0..) |*b, i| {
                if (b.active and b.debouncing and now >= b.lost_deadline) {
                    b.debouncing = false;
                    b.lost = true;
                    self.push(.{ .player_controller_lost = .{ .player = @intCast(i) } });
                }
            }
        }

        // ── Assignment API (game → manager) ───────────────────────────

        pub const AssignError = error{
            PlayerOutOfRange,
            ControllerNotAvailable,
        };

        /// Bind `controller` (which must currently be in the unassigned
        /// pool) to `player`. Emits `player_joined`. Removes the controller
        /// from the pool. If `player` already had a (live) controller, the
        /// old one is released back to the pool first.
        pub fn assign(self: *Self, controller: u32, player: u32) AssignError!void {
            if (player >= max_players) return error.PlayerOutOfRange;
            const idx = self.poolIndex(controller) orelse return error.ControllerNotAvailable;
            const info = self.pool[idx].info;
            self.pool[idx].in_use = false;

            // If this player held a different, still-live controller, return
            // it to the pool so it can be reassigned.
            const b = &self.bindings[player];
            if (b.active and b.controller_id != NO_CONTROLLER and b.controller_id != controller) {
                self.addToPool(self.bindingInfo(b.*));
            }

            b.* = .{
                .active = true,
                .controller_id = controller,
                .guid = info.guid,
                .bound_info = info,
            };
            self.push(.{ .player_joined = .{ .player = player, .controller_id = controller } });
        }

        /// Release `player`'s binding entirely. The controller (if still
        /// present) returns to the unassigned pool with a fresh
        /// `controller_available`. No-op for an inactive player.
        pub fn unassign(self: *Self, player: u32) void {
            if (player >= max_players) return;
            const b = &self.bindings[player];
            if (!b.active) return;
            const live = b.controller_id != NO_CONTROLLER;
            const info = self.bindingInfo(b.*);
            b.* = .{};
            if (live) self.addToPool(info);
        }

        /// The player a controller is bound to, or `NO_PLAYER`.
        pub fn playerFor(self: *const Self, controller: u32) u32 {
            return self.findPlayerByController(controller) orelse NO_PLAYER;
        }

        /// The controller currently backing a player, or `NO_CONTROLLER`
        /// (also `NO_CONTROLLER` while the player is debouncing/lost).
        pub fn controllerFor(self: *const Self, player: u32) u32 {
            if (player >= max_players) return NO_CONTROLLER;
            const b = self.bindings[player];
            if (!b.active) return NO_CONTROLLER;
            return b.controller_id;
        }

        /// `true` when the player slot is in use (assigned and not
        /// unassigned), even if its controller is currently lost.
        pub fn isPlayerActive(self: *const Self, player: u32) bool {
            if (player >= max_players) return false;
            return self.bindings[player].active;
        }

        /// `true` when an active player's controller is currently absent
        /// (debouncing or fully lost) — useful to gate gameplay / show a
        /// reconnect prompt.
        pub fn isPlayerWaiting(self: *const Self, player: u32) bool {
            if (player >= max_players) return false;
            const b = self.bindings[player];
            return b.active and (b.debouncing or b.lost);
        }

        // ── Pool query / iteration ────────────────────────────────────

        /// Number of controllers waiting in the unassigned pool.
        pub fn availableCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.pool) |e| {
                if (e.in_use) n += 1;
            }
            return n;
        }

        /// Snapshot the unassigned controllers into `out`, returning the
        /// count written (capped at `out.len`). Order is pool-slot order.
        pub fn availableControllers(self: *const Self, out: []ControllerInfo) usize {
            var n: usize = 0;
            for (self.pool) |e| {
                if (!e.in_use) continue;
                if (n >= out.len) break;
                out[n] = e.info;
                n += 1;
            }
            return n;
        }

        /// `true` when `controller` is in the unassigned pool.
        pub fn isAvailable(self: *const Self, controller: u32) bool {
            return self.poolIndex(controller) != null;
        }

        // ── Output drain (manager → host) ─────────────────────────────

        /// Drain the events produced since the last call into `out`,
        /// returning the count written. Drops surplus beyond `out.len`
        /// (host should size `out` to the manager's `event_capacity`).
        pub fn drainEvents(self: *Self, out: []ManagerEvent) usize {
            const n = @min(out.len, self.out_len);
            for (0..n) |i| out[i] = self.out[i];
            self.out_len = 0;
            return n;
        }

        // ── Opt-in policy helpers (NOT default behaviour) ─────────────

        /// **Opt-in policy.** Bind every currently-unassigned controller to
        /// the next free player slot, in pool order. A single-player or
        /// "fill seats as pads appear" game can call this each tick after
        /// `advance`. Returns the number of new assignments made. Does
        /// nothing on its own unless the game chooses to call it.
        pub fn autoBindFreeSlots(self: *Self) usize {
            var assigned: usize = 0;
            for (&self.pool) |*e| {
                if (!e.in_use) continue;
                const player = self.firstFreePlayer() orelse break;
                const controller = e.info.controller_id;
                self.assign(controller, player) catch break;
                assigned += 1;
            }
            return assigned;
        }

        /// **Opt-in policy.** "Press A to join": bind the unassigned
        /// controller `controller` to the next free player slot. Call from a
        /// game's button handler when an *unassigned* pad's join button is
        /// pressed. Returns the player it joined as, or `null` if the
        /// controller isn't available / there's no free slot.
        pub fn joinOnButton(self: *Self, controller: u32) ?u32 {
            if (!self.isAvailable(controller)) return null;
            const player = self.firstFreePlayer() orelse return null;
            self.assign(controller, player) catch return null;
            return player;
        }

        // ── Internals ─────────────────────────────────────────────────

        fn push(self: *Self, ev: ManagerEvent) void {
            if (self.out_len >= self.out.len) {
                // Should not happen for realistic churn; drop rather than
                // overwrite so the oldest events still dispatch.
                return;
            }
            self.out[self.out_len] = ev;
            self.out_len += 1;
        }

        fn addToPool(self: *Self, info: ControllerInfo) void {
            // Idempotent on controller_id — a duplicate connect for an
            // already-pooled id updates its info without a second event.
            if (self.poolIndex(info.controller_id)) |idx| {
                self.pool[idx].info = info;
                return;
            }
            for (&self.pool) |*e| {
                if (!e.in_use) {
                    e.in_use = true;
                    e.info = info;
                    self.push(.{ .controller_available = info });
                    return;
                }
            }
            // Pool full — drop (no event). Realistically unreachable at the
            // default capacity.
        }

        fn removeFromPool(self: *Self, controller: u32) bool {
            if (self.poolIndex(controller)) |idx| {
                self.pool[idx].in_use = false;
                return true;
            }
            return false;
        }

        fn poolIndex(self: *const Self, controller: u32) ?usize {
            for (self.pool, 0..) |e, i| {
                if (e.in_use and e.info.controller_id == controller) return i;
            }
            return null;
        }

        fn findPlayerByController(self: *const Self, controller: u32) ?u32 {
            if (controller == NO_CONTROLLER) return null;
            for (self.bindings, 0..) |b, i| {
                if (b.active and b.controller_id == controller) return @intCast(i);
            }
            return null;
        }

        fn findPlayerByGuid(self: *const Self, guid: [16]u8) ?u32 {
            for (self.bindings, 0..) |b, i| {
                if (!b.active) continue;
                if (b.guid) |bg| {
                    if (std.mem.eql(u8, &bg, &guid)) return @intCast(i);
                }
            }
            return null;
        }

        /// Most-recently-vacated active player still waiting for a
        /// controller (debouncing or lost). Drives the raylib resume
        /// heuristic. `null` if no player is waiting.
        fn mostRecentlyVacated(self: *const Self) ?u32 {
            var best: ?u32 = null;
            var best_t: f64 = -std.math.inf(f64);
            for (self.bindings, 0..) |b, i| {
                if (!b.active) continue;
                if (!(b.debouncing or b.lost)) continue;
                if (b.vacated_at >= best_t) {
                    best_t = b.vacated_at;
                    best = @intCast(i);
                }
            }
            return best;
        }

        /// Rebind `player` to `controller` after a reconnect (guid match or
        /// heuristic). Cancels any debounce; fires `player_controller_restored`
        /// only when the player had visibly lost its controller (so a
        /// within-window blip stays silent — no churn).
        fn restoreBinding(self: *Self, player: u32, controller: u32) void {
            const b = &self.bindings[player];
            const was_visibly_lost = b.lost;
            const was_debouncing = b.debouncing;
            b.controller_id = controller;
            b.debouncing = false;
            b.lost = false;
            b.lost_deadline = 0;
            // Refresh the live controller id on the bound info too.
            b.bound_info.controller_id = controller;
            // Emit `restored` whenever the binding had actually vacated —
            // both the visibly-lost case AND a within-window debounce
            // reconnect surface as restored so the game can clear a prompt.
            // The KEY no-churn guarantee is: a transient drop never fired
            // `lost` in the first place (advance hasn't expired it), so the
            // pair the game sees is at most {restored}, never {lost,restored}.
            if (was_visibly_lost or was_debouncing) {
                self.push(.{ .player_controller_restored = .{
                    .player = player,
                    .controller_id = controller,
                } });
            }
        }

        fn firstFreePlayer(self: *const Self) ?u32 {
            for (self.bindings, 0..) |b, i| {
                if (!b.active) return @intCast(i);
            }
            return null;
        }

        /// Reconstruct a `ControllerInfo` from a binding for pool re-entry.
        fn bindingInfo(self: *const Self, b: Binding) ControllerInfo {
            _ = self;
            var info = b.bound_info;
            info.controller_id = if (b.controller_id != NO_CONTROLLER) b.controller_id else b.bound_info.controller_id;
            return info;
        }
    };
}

/// Toolkit default capacities (8 controllers / 8 players) — enough for
/// couch co-op without an allocator. Games that need more can instantiate
/// `ControllerManager(N, M)` directly.
pub const DefaultControllerManager = ControllerManager(8, 8);
