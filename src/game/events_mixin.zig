/// Events mixin — hook + game-event dispatch: `emitHook` (typed hook
/// payload), `emit` (buffered game event), `tryEmit` (the same enqueue,
/// fallible — #856), `emitEngineEvent` (tolerant `engine__<event>`
/// dual-emit, #578), `emitSync` (immediate), and `dispatchEvents`
/// (the once-per-frame buffer drain).
///
/// The authoritative delivery contract — drain points, ordering,
/// handler-emitted timing, payload lifetime, scene-reset and shutdown
/// behaviour — is `HOOK-DELIVERY-CONTRACT.md` at the repo root (#857),
/// pinned by `test/hook_delivery_contract_test.zig`. Read it before
/// changing anything in this file: several of the guarantees below are
/// load-bearing for flows, scripts and plugins.
///
/// Extracted verbatim from `game.zig`; behaviour is identical. The
/// comptime types/flags this needs (`Payload`, `has_hooks`, `has_events`,
/// `EventBuffer`) are defined in `GameConfig`'s function body and surfaced
/// onto `Game` as `pub const` re-exports so this mixin reads a single
/// comptime source of truth via `Game.*`. Intra-cluster calls
/// (`emit`, `emitHook`) use lexical sibling syntax.
const std = @import("std");
const game_types = @import("retain_node.zig");

/// Error set of the fallible enqueue path (`Game.tryEmit`, #856).
///
/// Enqueue's only failure mode is growing the frame's event buffer, so
/// this is exactly `std.mem.Allocator.Error` (`error{OutOfMemory}`).
/// Named rather than inferred so call sites can spell the type out
/// (`fn onPickup(...) engine.EmitError!void`) and so a future failure
/// mode can be added here in one place instead of at every `try`.
pub const EmitError = std.mem.Allocator.Error;

/// Returns the events-dispatch mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const GameEvents = Game.GameEvents;
    const Payload = Game.PayloadExport;
    const EventBuffer = Game.EventBufferExport;
    const has_events = Game.has_events_export;
    const has_hooks = Game.has_hooks_export;
    // Aliased under a different name so the `pub const EmitError` inside
    // the returned struct can reference the file-scope one without a
    // self-referential dependency loop.
    const EmitErrorAlias = EmitError;

    return struct {
        pub fn emitHook(self: *Game, payload: Payload) void {
            if (has_hooks) {
                if (self.hooks) |h| {
                    h.emit(payload);
                }
            }
        }

        /// Error set of `tryEmit` (#856). Re-exported on the mixin so
        /// `Game.EmitError` resolves without importing this file.
        pub const EmitError = EmitErrorAlias;

        /// Enqueue a game event, reporting enqueue failure to the caller.
        ///
        /// This is the fallible sibling of `emit` (#856). Both push onto
        /// the same frame buffer and both are delivered by the same
        /// end-of-frame `dispatchEvents` drain — the ONLY difference is
        /// what happens when the buffer cannot grow: `emit` logs and
        /// returns, `tryEmit` returns `error.OutOfMemory`.
        ///
        /// ## Success guarantee
        ///
        /// A successful return means the event ENTERED THE QUEUE, and
        /// nothing more. It does NOT mean any listener has run, that the
        /// event was persisted, or that anyone acknowledged it. Delivery
        /// still happens later, at the frame's `dispatchEvents` drain
        /// (or at the next drain, for an event emitted from inside a
        /// handler — see `dispatchEvents`).
        ///
        /// ## Failure guarantee
        ///
        /// On error the buffer is left exactly as it was: every
        /// previously queued event is intact and in order, and the
        /// failed event is queued neither partially nor twice. A retry
        /// once memory is available enqueues it exactly once. Ordering
        /// of the events that DID make it is untouched.
        ///
        /// The error does NOT roll back whatever model mutation the
        /// producer made before emitting. Enqueue reporting is not a
        /// transaction: the engine cannot un-spend the gold you just
        /// deducted. The recovery pattern is a dirty flag the producer
        /// reconciles on a later frame:
        ///
        /// ```zig
        /// // Producer keeps a derived view (an inventory panel) in sync
        /// // with the model by emitting on every change.
        /// fn addItem(self: *Inventory, game: *Game, slot: u32) void {
        ///     self.slots[slot] += 1;                 // model mutation — already done
        ///     game.tryEmit(.{ .inventory_changed = .{ .slot = slot } }) catch {
        ///         // The notification is lost, but the model moved. Do
        ///         // NOT undo the mutation — record that the derived
        ///         // view is stale and reconcile later.
        ///         self.view_dirty = true;
        ///     };
        /// }
        ///
        /// // Cheap per-frame reconciliation: retry the notification, and
        /// // if it still cannot be queued stay dirty and try next frame.
        /// fn update(self: *Inventory, game: *Game) void {
        ///     if (!self.view_dirty) return;
        ///     game.tryEmit(.{ .inventory_resync = .{} }) catch return;
        ///     self.view_dirty = false;
        /// }
        /// ```
        ///
        /// A producer that cannot degrade — one whose whole correctness
        /// rests on the notification — should rebuild from the model on
        /// the dirty flag rather than assume the event will land.
        ///
        /// ## Games with no declared events
        ///
        /// When the project declares no game events (`GameEvents ==
        /// void`, the `GameWith(Hooks)` unit-test shape), there is no
        /// queue to append to and no listener to lose: the whole body
        /// folds away at comptime and the call RETURNS SUCCESS. Success
        /// there means "nothing was dropped", not "an event is pending".
        /// It is never an error, so a producer written against a game
        /// with events keeps compiling and keeps passing when linked
        /// into an event-less build.
        pub fn tryEmit(self: *Game, event: GameEvents) EmitErrorAlias!void {
            if (has_events) {
                try self.event_buffer.append(self.allocator, event);
            }
        }

        /// Emit a game event. Buffered and delivered to scripts at end of frame.
        ///
        /// Infallible: an enqueue failure is logged and swallowed, so the
        /// producer cannot observe the lost notification. This is the
        /// historical behaviour and stays the default — reach for
        /// `tryEmit` when losing the event would corrupt a derived view,
        /// a cache or a counter the producer maintains (#856).
        pub fn emit(self: *Game, event: GameEvents) void {
            tryEmit(self, event) catch |err| {
                self.log.err("Failed to emit game event: {s}", .{@errorName(err)});
            };
        }

        /// Engine-side tolerant emit for the `engine__<event>` variants
        /// declared on `engine.Events` (RFC-FLOW-VOCABULARY phase 6,
        /// #578). The assembler folds the engine's `Events` block into
        /// `PluginEvents`, which is itself merged into `GameEvents`. So
        /// in any project where the assembler ran, `GameEvents` has the
        /// `engine__<event>` variants. But unit tests build `Game`
        /// directly with `GameEvents = void` (the `GameWith(Hooks)`
        /// path), so the engine's own lifecycle code can't blindly call
        /// `self.emit(.{ .engine__game_init = .{} })` — there would be
        /// no such field in the union.
        ///
        /// This helper does the comptime gate: when `GameEvents` is a
        /// union *and* declares the variant tag, the dispatch goes
        /// through `emit`; otherwise the call folds away to a no-op.
        ///
        /// The variant must be passed as `comptime`-known struct
        /// literal — e.g. `self.emitEngineEvent("engine__game_init", .{})`
        /// — so the field-presence check resolves at compile time. The
        /// payload type is inferred against
        /// `@FieldType(GameEvents, tag)`, mirroring how
        /// `dispatchEvents` reconstructs the union variant.
        pub inline fn emitEngineEvent(
            self: *Game,
            comptime tag: []const u8,
            payload: anytype,
        ) void {
            emitEngineEventImpl(self, tag, payload, false);
        }

        /// Like `emitEngineEvent`, but dispatches the constructed variant
        /// SYNCHRONOUSLY (via `emitSync`) instead of buffering it for the
        /// end-of-frame `dispatchEvents` drain.
        ///
        /// Needed by the fixed-timestep phase (#751): the fixed steps run
        /// inside `tick` BEFORE the variable update, but the buffered
        /// `emit` path only delivers to flow/Event-node consumers when the
        /// generated loop drains the buffer AFTER `tick`. A buffered
        /// `engine__fixed_tick` would therefore reach flow-driven fixed
        /// systems a phase late (after the variable update + `frame_end`),
        /// defeating the "fixed before Update, in-phase" contract that
        /// physics/lockstep needs. Emitting synchronously runs those
        /// handlers in the same fixed slice, matching the `fixed_update`
        /// HookPayload path. See `emitSync`'s caveats for the re-entrancy
        /// / ordering trade-offs a synchronous dispatch carries.
        pub inline fn emitEngineEventSync(
            self: *Game,
            comptime tag: []const u8,
            payload: anytype,
        ) void {
            emitEngineEventImpl(self, tag, payload, true);
        }

        /// Shared body of `emitEngineEvent` / `emitEngineEventSync`. The
        /// `sync` flag selects the dispatch: buffered `emit` (end-of-frame)
        /// or immediate `emitSync`.
        inline fn emitEngineEventImpl(
            self: *Game,
            comptime tag: []const u8,
            payload: anytype,
            comptime sync: bool,
        ) void {
            // Comptime gate: when the project's `GameEvents` doesn't
            // carry the requested variant — e.g. unit-test games using
            // `GameWith(Hooks)` with `GameEvents = void`, or any
            // project the assembler hasn't yet been re-run against —
            // the entire body folds to a no-op. Returning the early
            // empty body via comptime branching avoids semantic
            // analysis on a `@unionInit` against `void`/missing field.
            const should_emit = comptime blk: {
                if (!has_events) break :blk false;
                const ev_info = @typeInfo(GameEvents);
                if (ev_info != .@"union") break :blk false;
                break :blk @hasField(GameEvents, tag);
            };
            if (comptime !should_emit) return;
            // From here on `GameEvents` is known to be a union with
            // the variant. Build the payload by copying fields from
            // the caller's anonymous struct literal into a value of
            // the merged union's declared payload type — Zig 0.16
            // does not auto-coerce anonymous struct literals to a
            // *different* named struct even when fields match, so we
            // do it field-by-field. This also lets the caller pass
            // the engine's `Entity` type for entity-typed fields:
            // the @intCast widens to `u32` here without forcing the
            // call site to spell it out.
            const Payload_t = @FieldType(GameEvents, tag);
            var typed: Payload_t = undefined;
            const fields = comptime std.meta.fields(Payload_t);
            inline for (fields) |f| {
                if (comptime @hasField(@TypeOf(payload), f.name)) {
                    const src_val = @field(payload, f.name);
                    const SrcT = @TypeOf(src_val);
                    if (comptime @typeInfo(f.type) == .int and @typeInfo(SrcT) == .int) {
                        @field(typed, f.name) = @intCast(src_val);
                    } else {
                        @field(typed, f.name) = src_val;
                    }
                } else if (comptime f.default_value_ptr != null) {
                    @field(typed, f.name) = @as(*const f.type, @ptrCast(@alignCast(f.default_value_ptr.?))).*;
                } else {
                    @compileError("emitEngineEvent: missing field '" ++ f.name ++ "' for variant '" ++ tag ++ "'");
                }
            }
            const event = @unionInit(GameEvents, tag, typed);
            if (comptime sync) emitSync(self, event) else emit(self, event);
        }

        /// Emit a game event synchronously — dispatch to registered hooks
        /// immediately, bypassing the end-of-frame buffer. Use when the
        /// caller needs the handler to have run before the next
        /// statement (cross-plugin state machines that can't tolerate
        /// the buffered-dispatch window).
        ///
        /// ## Caveats
        ///
        /// The event-buffer design in the custom-game-events RFC exists
        /// precisely to avoid these, so reach for `emitSync` only when
        /// the buffered path is provably wrong for the call site:
        ///
        /// - **Re-entrancy.** Handlers run mid-tick, inside whatever
        ///   script or plugin called `emitSync`. A handler that itself
        ///   mutates entity state, emits more events, or calls back
        ///   into the caller's own code can interleave with partially-
        ///   completed work on the stack above. Favour buffered `emit`
        ///   unless the caller is a leaf operation.
        ///
        /// - **Ordering vs buffered events.** `emitSync` does NOT drain
        ///   the end-of-frame buffer first. A hook fired synchronously
        ///   mid-tick runs *before* all the events `emit` queued
        ///   earlier in the same frame, even though those were queued
        ///   first. Mixing the two on a single event kind produces
        ///   out-of-order handler calls — usually not what you want.
        pub fn emitSync(self: *Game, event: GameEvents) void {
            // Skip the switch + @unionInit payload construction when
            // the game has no hooks to dispatch to — same comptime
            // shortcut `emitHook` relies on. Folds the entire call
            // away in zero-hook builds.
            if (!has_events or !has_hooks) return;
            switch (event) {
                inline else => |data, tag| {
                    emitHook(self, @unionInit(Payload, @tagName(tag), data));
                },
            }
        }

        /// Deliver buffered game events to hooks.
        ///
        /// Called once per frame by the generated main loop — BEFORE
        /// `g.tick(dt)`, not after it (every backend template emits the
        /// assembler's `tick_code`, whose tail is this call, immediately
        /// ahead of the engine tick). Also called once by `Game.deinit`
        /// as the final flush.
        ///
        /// The buffer is SWAPPED OUT before iterating, so an event a
        /// handler emits lands in the fresh buffer and is delivered by
        /// the NEXT drain — never by this one. That is what keeps an
        /// `A -> B -> A` handler chain from hanging the drain, and what
        /// keeps the iterated slice stable. See
        /// `HOOK-DELIVERY-CONTRACT.md` §2 and §4.
        /// Reserve one retention node, BEFORE emitting the event whose
        /// payload will borrow the slice (#862/#863).
        ///
        /// Ordering is the whole point. If the retention could fail AFTER
        /// the event was buffered, the caller would hold an allocation a
        /// queued payload borrows with no safe way to dispose of it:
        /// freeing it is a use-after-free, and dropping it leaks. An
        /// earlier revision caught the failure and freed the slice —
        /// logging it did not make it safe (#867 review).
        ///
        /// Allocating here means the only failure happens while nothing is
        /// queued yet, so the caller can abort cleanly and leave the game
        /// exactly as it was.
        ///
        /// One node per call, so nested reservations compose: the loop can
        /// reserve around a `setScene` that reserves for itself.
        pub fn reserveRetention(self: *Game) error{OutOfMemory}!void {
            if (comptime !has_events) return;
            const node = try self.allocator.create(game_types.RetainNode);
            node.* = .{ .next = self.retention_spares };
            self.retention_spares = node;
        }

        /// Park `slice` until the drain that delivers the currently
        /// buffered events has finished, then free it on the game
        /// allocator (#862/#863).
        ///
        /// For a caller that has just BUFFERED an event borrowing `slice`
        /// and would otherwise free it straight away. Freeing immediately
        /// leaves the payload pointing at freed memory until the next
        /// drain — a full frame, since the generated loop drains before it
        /// ticks.
        ///
        /// MUST be preceded by a successful `reserveRetention` in the same
        /// operation. Infallible by construction rather than by swallowing
        /// a failure: the node already exists, so this only relinks
        /// pointers.
        pub fn retainUntilDrained(self: *Game, slice: []const u8) void {
            if (comptime !has_events) {
                // No buffer, so nothing can outlive a drain: the borrow
                // hazard does not exist and the slice is freed at once.
                self.allocator.free(slice);
                return;
            }
            const node = self.retention_spares orelse {
                // Only reachable from a caller that skipped its
                // reservation — a programming error here, not a runtime
                // condition. Freeing would reinstate the use-after-free
                // and dropping would leak, so refuse loudly instead of
                // picking one silently.
                @panic("retainUntilDrained without a matching reserveRetention (#862/#863)");
            };
            self.retention_spares = node.next;
            node.* = .{ .slice = slice, .next = self.pending_payload_frees };
            self.pending_payload_frees = node;
        }

        /// Free a detached retention chain and its nodes.
        fn freeRetainChain(self: *Game, head: ?*game_types.RetainNode) void {
            var it = head;
            while (it) |node| {
                const next = node.next;
                self.allocator.free(node.slice);
                self.allocator.destroy(node);
                it = next;
            }
        }

        /// Release every node still held — retained AND reserved-unused.
        /// Called from `deinit`, after the final flush.
        pub fn releaseRetentions(self: *Game) void {
            if (comptime !has_events) return;
            freeRetainChain(self, self.pending_payload_frees);
            self.pending_payload_frees = null;
            var it = self.retention_spares;
            while (it) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                it = next;
            }
            self.retention_spares = null;
        }

        pub fn dispatchEvents(self: *Game) void {
            if (!has_events) return;
            var dispatch_buf: EventBuffer = .empty;
            std.mem.swap(EventBuffer, &self.event_buffer, &dispatch_buf);

            // Detach the retention chain ALONGSIDE the event buffer, so
            // the two stay in step: these are exactly the slices retained
            // while those events were being buffered. Anything a handler
            // retains during the drain lands on the fresh chain and is
            // freed after the NEXT drain — which is what a nested
            // `dispatchEvents` relies on (#862/#863).
            const to_free = self.pending_payload_frees;
            self.pending_payload_frees = null;

            for (dispatch_buf.items) |event| {
                switch (event) {
                    inline else => |data, tag| {
                        emitHook(self, @unionInit(Payload, @tagName(tag), data));
                    },
                }
            }
            dispatch_buf.clearRetainingCapacity();

            // AFTER the loop: every listener that could borrow these
            // slices has now run and returned.
            freeRetainChain(self, to_free);

            if (self.event_buffer.items.len == 0) {
                std.mem.swap(EventBuffer, &self.event_buffer, &dispatch_buf);
            }
            dispatch_buf.deinit(self.allocator);
        }
    };
}
