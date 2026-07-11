/// Events mixin — hook + game-event dispatch: `emitHook` (typed hook
/// payload), `emit` (buffered game event), `emitEngineEvent` (tolerant
/// `engine__<event>` dual-emit, #578), `emitSync` (immediate), and
/// `dispatchEvents` (end-of-frame buffer drain).
///
/// Extracted verbatim from `game.zig`; behaviour is identical. The
/// comptime types/flags this needs (`Payload`, `has_hooks`, `has_events`,
/// `EventBuffer`) are defined in `GameConfig`'s function body and surfaced
/// onto `Game` as `pub const` re-exports so this mixin reads a single
/// comptime source of truth via `Game.*`. Intra-cluster calls
/// (`emit`, `emitHook`) use lexical sibling syntax.
const std = @import("std");

/// Returns the events-dispatch mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const GameEvents = Game.GameEvents;
    const Payload = Game.PayloadExport;
    const EventBuffer = Game.EventBufferExport;
    const has_events = Game.has_events_export;
    const has_hooks = Game.has_hooks_export;

    return struct {
        pub fn emitHook(self: *Game, payload: Payload) void {
            if (has_hooks) {
                if (self.hooks) |h| {
                    h.emit(payload);
                }
            }
        }

        /// Emit a game event. Buffered and delivered to scripts at end of frame.
        pub fn emit(self: *Game, event: GameEvents) void {
            if (has_events) {
                self.event_buffer.append(self.allocator, event) catch |err| {
                    self.log.err("Failed to emit game event: {s}", .{@errorName(err)});
                };
            }
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

        /// Deliver buffered game events to hooks. Called at end of frame.
        pub fn dispatchEvents(self: *Game) void {
            if (!has_events) return;
            var dispatch_buf: EventBuffer = .empty;
            std.mem.swap(EventBuffer, &self.event_buffer, &dispatch_buf);

            for (dispatch_buf.items) |event| {
                switch (event) {
                    inline else => |data, tag| {
                        emitHook(self, @unionInit(Payload, @tagName(tag), data));
                    },
                }
            }
            dispatch_buf.clearRetainingCapacity();

            if (self.event_buffer.items.len == 0) {
                std.mem.swap(EventBuffer, &self.event_buffer, &dispatch_buf);
            }
            dispatch_buf.deinit(self.allocator);
        }
    };
}
