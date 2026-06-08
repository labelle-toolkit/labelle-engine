//! Runtime `Scheduler` — the foundation for flow `Delay` nodes
//! (flow-codegen#48 / #25 Stage 2).
//!
//! ## What it is
//!
//! A tiny absolute-time timer wheel that fires type-erased callbacks once
//! their due time is reached. It deliberately does **not** keep its own
//! clock: it reuses the game's pause-aware gameplay clock
//! (`Game.elapsedSeconds()`, #25). A timer scheduled with `after(seconds, …)`
//! fires when `elapsedSeconds() >= fire_at`, where `fire_at` is captured at
//! schedule time as `elapsedSeconds() + seconds`.
//!
//! ### Why reuse the clock (pause-freeze falls out for free)
//!
//! `elapsedSeconds()` accumulates the *time-scaled* dt each `tick()` and
//! freezes whenever `Game.isPaused()` is true (either the `paused` flag or a
//! zero `time_scale`). Because the scheduler compares `fire_at` against that
//! same monotonic value — and never against wall time or its own
//! accumulator — a paused game makes both `elapsedSeconds()` and every
//! pending `fire_at` comparison stand still. Delays therefore inherit pause
//! and slow-mo with zero extra bookkeeping.
//!
//! ## Type erasure / no circular dependency
//!
//! The scheduler must not reference the `Game` type (a `Scheduler` field on
//! `Game` referencing `*Game` would be a circular comptime dependency). So:
//!
//!   - the game is held type-erased as `game_ctx: *anyopaque`,
//!   - it reads the clock through `now_fn(game_ctx) -> f64`,
//!   - it checks entity liveness through `is_alive_fn(game_ctx, entity) -> bool`.
//!
//! `Game.init` wires those two trampolines (each just `@ptrCast`s `game_ctx`
//! back to `*Self` and calls `elapsedSeconds()` / `ecs_backend.entityExists`).
//! When a callback fires, the engine passes the same `game_ctx` to `func` as
//! its first argument; the codegen-generated trampoline casts both pointers
//! back to their concrete types.
//!
//! ## `ctx` ownership contract
//!
//! The scheduler OWNS each entry's `ctx` from the moment `after()` returns:
//! it frees `ctx` via the game allocator exactly once — right after the
//! callback fires, when the callback is skipped (dead entity), or when the
//! entry is dropped during `deinit`. The caller (codegen) `allocator.create`s
//! the capture struct and hands the typed pointer over; it must NOT free or
//! reuse `ctx` after calling `after`.
//!
//! `after` takes the **typed** `*T` capture pointer (not a pre-erased
//! `*anyopaque`). It captures `T` at comptime to synthesize a correctly
//! typed/aligned destroy thunk, then stores the pointer erased. This is what
//! lets the scheduler free a heterogeneous set of capture structs through a
//! single `*anyopaque` slot without alignment-mismatch "Invalid free"s — a
//! plain `allocator.destroy(@as(*u8, …))` would panic because the original
//! allocation's alignment is lost.

const std = @import("std");

/// Timer scheduler keyed on the engine `Entity` type.
///
/// `Entity` is the ECS backend's entity type (e.g. `u32` in tests, the
/// real backend's handle in shipped games). Only an *optional* `Entity` is
/// stored per entry; entity binding is used purely to skip a callback whose
/// target was destroyed before it fired.
pub fn Scheduler(comptime Entity: type) type {
    return struct {
        const Self = @This();

        /// Type-erased callback. First arg is the game (`game_ctx`), second
        /// is the entry's owned `ctx`. The codegen trampoline casts both.
        pub const Callback = *const fn (game_ctx: *anyopaque, ctx: *anyopaque) void;

        /// Reads the gameplay clock (`Game.elapsedSeconds()`), type-erased.
        pub const NowFn = *const fn (game_ctx: *anyopaque) f64;

        /// Reports whether an entity is still alive
        /// (`Game.ecs_backend.entityExists`), type-erased.
        pub const IsAliveFn = *const fn (game_ctx: *anyopaque, entity: Entity) bool;

        /// Type-erased destroy thunk for an entry's `ctx`, synthesized per
        /// capture type `T` inside `after`. Frees with the original
        /// type/alignment so the debug allocator doesn't reject the free.
        pub const FreeFn = *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void;

        const Entry = struct {
            /// Absolute gameplay time (seconds) at which to fire.
            fire_at: f64,
            /// Optional entity binding. When set and the entity is no longer
            /// alive at fire time, the callback is skipped and `ctx` freed.
            entity: ?Entity,
            ctx: *anyopaque,
            func: Callback,
            free_ctx: FreeFn,
        };

        allocator: std.mem.Allocator,
        pending: std.ArrayListUnmanaged(Entry) = .empty,

        /// Type-erased game handle + trampolines, supplied by `Game.init`.
        game_ctx: *anyopaque,
        now_fn: NowFn,
        is_alive_fn: IsAliveFn,

        pub fn init(
            allocator: std.mem.Allocator,
            game_ctx: *anyopaque,
            now_fn: NowFn,
            is_alive_fn: IsAliveFn,
        ) Self {
            return .{
                .allocator = allocator,
                .game_ctx = game_ctx,
                .now_fn = now_fn,
                .is_alive_fn = is_alive_fn,
            };
        }

        /// Free the pending list AND any still-owned `ctx` allocations. A
        /// game can exit with timers in flight; this drops them without
        /// firing and without leaking.
        pub fn deinit(self: *Self) void {
            for (self.pending.items) |entry| {
                entry.free_ctx(self.allocator, entry.ctx);
            }
            self.pending.deinit(self.allocator);
        }

        /// Schedule `func` to fire once after `seconds` of *gameplay* time
        /// (pause-aware). `fire_at` is captured now as `elapsedSeconds() +
        /// seconds`. `entity` optionally binds the timer: if that entity is
        /// destroyed before the timer fires, the callback is skipped.
        ///
        /// `ctx` is the **typed** `*T` capture pointer (caller `create`d it
        /// on the game allocator). The scheduler takes ownership and frees it
        /// (once) after firing / skipping / on deinit, using a `T`-correct
        /// destroy thunk synthesized here. See the module doc.
        pub fn after(
            self: *Self,
            seconds: f64,
            entity: ?Entity,
            ctx: anytype,
            func: Callback,
        ) void {
            const Ctx = @TypeOf(ctx);
            const ctx_info = @typeInfo(Ctx);
            comptime std.debug.assert(ctx_info == .pointer); // expects *T
            const thunk = struct {
                fn free(allocator: std.mem.Allocator, erased: *anyopaque) void {
                    const typed: Ctx = @ptrCast(@alignCast(erased));
                    allocator.destroy(typed);
                }
            }.free;

            const fire_at = self.now_fn(self.game_ctx) + seconds;
            self.pending.append(self.allocator, .{
                .fire_at = fire_at,
                .entity = entity,
                .ctx = @ptrCast(ctx),
                .func = func,
                .free_ctx = thunk,
            }) catch @panic("Scheduler.after: OOM appending timer");
        }

        /// Fire every pending entry whose `fire_at <= now`, where `now` is
        /// the game's current `elapsedSeconds()`. Called once per `tick()`
        /// from the game (only while not paused — but it is also safe to
        /// call while paused since `now` simply doesn't advance).
        ///
        /// Iteration safety: a firing callback may re-entrantly call
        /// `after()`, which appends to `self.pending` and can reallocate its
        /// backing buffer. We therefore copy each due entry *out* (by value)
        /// and remove it from `pending` BEFORE invoking the callback, using
        /// a swap-remove index walk. Newly appended entries land past the
        /// current scan position and are simply considered on the next tick
        /// (or this one, if their `fire_at` is already due and the swap
        /// brings them into range — both are correct). No held pointer into
        /// `pending` survives across a callback, so reallocation is benign.
        pub fn tick(self: *Self) void {
            const now = self.now_fn(self.game_ctx);
            var i: usize = 0;
            while (i < self.pending.items.len) {
                if (self.pending.items[i].fire_at <= now) {
                    // Remove by value first, so the callback sees a stable
                    // `pending` it may freely append to.
                    const entry = self.pending.swapRemove(i);
                    self.fire(entry);
                    // Do not advance `i`: swapRemove moved the last element
                    // into slot `i`, which we still need to test.
                } else {
                    i += 1;
                }
            }
        }

        /// Run (or skip) a single due entry, then free its `ctx` exactly
        /// once. Skips the callback when the bound entity is dead.
        fn fire(self: *Self, entry: Entry) void {
            defer entry.free_ctx(self.allocator, entry.ctx);
            if (entry.entity) |e| {
                if (!self.is_alive_fn(self.game_ctx, e)) return; // skip dead target
            }
            entry.func(self.game_ctx, entry.ctx);
        }

        /// Number of timers currently pending (test/introspection helper).
        pub fn pendingCount(self: *const Self) usize {
            return self.pending.items.len;
        }
    };
}
