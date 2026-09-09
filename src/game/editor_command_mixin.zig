//! Editor-command mixin — the play-time action channel for labelle-studio's
//! plugin panels (Asset Plugins Phase 3, RFC-ASSET-PLUGINS rev 4,
//! labelle-engine#729 / labelle-assembler#577).
//!
//! A plugin ships a declarative `studio/*.panel.jsonc` describing a small
//! form; the studio renders it with its own kit and, on an action whose
//! `"target"` is `"preview"`, dispatches the command into the running wasm
//! preview through the `editor_plugin_command` bridge export (editor-contract
//! **v1.7**). This mixin is where that command lands on the engine side: it
//! routes `{plugin, command, params}` to the plugin's declared handler.
//!
//! ## Handler declaration (the RFC's open question, resolved)
//!
//! rev 4 left "comptime hook registration vs a manifest list" open. This
//! picks **comptime hook registration via the existing engine-event channel**:
//! a plugin declares its editor handler by subscribing to the
//! `engine__editor_plugin_command` event (`engine.Events.editor_plugin_command`,
//! surfaced in `root.zig`), exactly like input plugins subscribe to
//! `engine__key_pressed` (#606). Consuming the event flips the variant onto
//! the project's merged `GameEvents`, which is the zero-cost gate here: when
//! NO plugin subscribes the variant is absent, this whole path folds to a
//! `-1`, and an older/handler-less build "degrades gracefully" (the studio
//! disables preview-target actions on the missing export or the -1 result).
//!
//! ## Why synchronous
//!
//! Dispatch is SYNCHRONOUS (`emitSync`, not the buffered `emit`): the handler
//! runs before `editorPluginCommand` returns, so the studio's wasm-owned
//! `command`/`params` buffers — freed right after the bridge call — stay valid
//! for the handler with no copy, and the bridge can hand the studio a real
//! result code. The trade-off (re-entrancy / buffered-event ordering) is
//! irrelevant for this leaf, host-initiated action channel.
//!
//! ## The response channel (#758)
//!
//! v1.7 / contract v1.1 were deliberately fire-and-forward. Two consumers
//! now want results back — the studio Script Console (labelle-studio#78,
//! eval output) and script-language typed wrappers (RFC-LANGUAGE-PLUGINS
//! rev 10 stretch) — so the dispatch grew a digest-style out-buffer: a
//! handler may WRITE one response during the synchronous dispatch window
//! and the caller receives it (`editorPluginCommandOut`; surfaced to C as
//! `editor_plugin_command_out` (bridge v1.8) and the activated `out`/
//! `out_cap` of `labelle_plugin_call` + `labelle_plugin_response_fetch`
//! (script contract v1.2)).
//!
//! ### Why handlers respond through `respond()`, not a writer parameter
//!
//! Handlers are invoked by labelle-core's dispatchers (`HookDispatcher.emit`
//! / `MergeHooks.emit`), whose call sites are fixed at exactly
//! `handler(receiver, payload)` — a third response-writer parameter cannot
//! reach a handler without a labelle-core change (a cross-repo release this
//! additive engine feature must not gate on), and having the engine walk
//! `hooks.receivers` itself to arity-dispatch would fork core's dispatch
//! semantics (consumable ordering, receiver unwrapping) into a second
//! implementation. Embedding a responder pointer in the event payload was
//! also rejected: the assembler AST-folds `engine.Events` payload structs
//! into each project's generated `PluginEvents`, so a new field only exists
//! after an assembler release + project re-generation — every already-
//! generated project would silently stay response-less. The module-scope
//! `respond()` capability works with every existing project the day the
//! engine ships, keeps handler signatures literally unchanged (the strongest
//! form of "old handlers still compile"), and follows the module-state idiom
//! of this C-ABI-adjacent layer (`script_contract`'s subs/inbox,
//! `editor_api`'s pause/step). Single-threaded by design, like everything
//! here: the window is set and torn down around one synchronous `emitSync`
//! on the main thread.
//!
//! ### First-writer-wins (one response per broadcast)
//!
//! The channel is a BROADCAST that handlers name-filter themselves, so
//! MULTIPLE handlers may receive one command — but only ONE response can
//! return. The dispatch cannot attribute buffer writes to individual
//! receivers (core's fan-out is opaque to it), so a per-handler appendable
//! writer cannot be policed; instead `respond()` is SINGLE-SHOT: the first
//! call claims the response (empty payload included), and every later call
//! in the same window is refused with `false` + a `std.log.warn` — loud in
//! dev, harmless in prod. A registry-of-responders (addressed, per-plugin
//! response slots) is a deliberate non-goal for v1; commands are already
//! conventionally addressed `<plugin>__<command>`, so collisions mean two
//! plugins claimed the same name — a project bug worth a warning, not a
//! protocol.
//!
//! ### Bounded, truncate-at-cap
//!
//! Responses are capped at `max_response_len` so they can cross the sized
//! C surfaces with digest-style semantics and callers can PRE-SIZE buffers
//! (the studio allocates `editor_plugin_response_cap()` bytes once and can
//! then never overflow). A `respond`/`respondFmt` payload longer than the
//! dispatch buffer is truncated at the cap and flagged
//! (`Result.responded.truncated`) — all-or-nothing at the WRITE side would
//! silently drop eval output entirely, while a flagged prefix is still
//! useful console text.

const std = @import("std");

/// Response size cap, in bytes. The one number the whole channel is sized
/// by: the mixin's dispatch buffer on the editor-bridge path, the script
/// contract's response store, and the studio's `editor_plugin_response_cap()`
/// pre-sizing export all quote it, so bumping it here re-sizes every
/// consumer coherently. 4 KiB: generous for console/eval digests, trivial
/// as a stack temporary (the wasm main thread's default stack is 64 KiB+).
pub const max_response_len: usize = 4096;

/// Outcome of a response-aware dispatch (`Game.editorPluginCommandOut`).
pub const Result = union(enum) {
    /// Not dispatched: empty plugin/command (most likely a host-side
    /// length bug), or no plugin subscribed to
    /// `engine__editor_plugin_command` in this build (the graceful-degrade
    /// path). Maps to the v1.7 rc's -1 / the C sentinels.
    unroutable,
    /// Dispatched into the handler channel, no handler responded — the
    /// fire-and-forward outcome (v1.7's only success shape). Also the
    /// outcome when a handler responded EMPTY: an empty response is
    /// indistinguishable from no response in the sized C returns (0 is
    /// already "dispatched, no response"), so it is folded here once,
    /// keeping every consumer consistent. Handlers wanting a bare ack
    /// should respond `"{}"` (documented in `contract/labelle_script.h`).
    dispatched,
    /// A handler responded. `bytes` is the response, a slice of the
    /// CALLER's `out` buffer (valid exactly as long as that buffer);
    /// `truncated` is set when the handler wrote more than `out` could
    /// hold (the response was cut at `out.len`).
    responded: Response,

    pub const Response = struct {
        bytes: []u8,
        truncated: bool,
    };
};

/// The active dispatch window's response accumulator. `buf` is the
/// dispatching caller's storage; `claimed` is the first-writer-wins latch.
const Slot = struct {
    buf: []u8,
    len: usize = 0,
    claimed: bool = false,
    truncated: bool = false,
};

/// The dispatch window: non-null exactly while `editorPluginCommandOut` is
/// inside its `emitSync`. Module-scope (not per-Game) because `respond` is
/// a free function handlers can call without a game pointer; single-
/// threaded by design (main-thread dispatch, same justification as
/// `script_contract`'s module state). Saved/restored around the dispatch,
/// so a handler that itself issues a nested `editorPluginCommand*` gives
/// the inner dispatch its own window and the outer one resumes intact.
var active_slot: ?*Slot = null;

/// Respond to the plugin command currently being dispatched — callable
/// from inside an `engine__editor_plugin_command` handler only (the
/// synchronous dispatch window). SINGLE-SHOT, first-writer-wins: the first
/// respond in a window claims the response (see the module doc for why a
/// per-handler appendable writer is not policeable on a broadcast); later
/// calls — same handler or another receiver — are refused.
///
/// `bytes` is copied immediately (the handler may pass a stack buffer);
/// payloads longer than the window's buffer are truncated at its length
/// (at most `max_response_len`, less when the caller is fire-and-forward —
/// the v1.7 `editor_plugin_command` export dispatches with a zero-length
/// buffer, so responses to it are silently discarded, by design).
///
/// Returns `true` when this call claimed the response; `false` when
/// refused (already claimed, or no dispatch window is active). Handlers
/// may ignore the return — the refusal legs also `std.log.warn`, which is
/// the debug-visible signal for the two-responders project bug.
pub fn respond(bytes: []const u8) bool {
    const slot = claimSlot() orelse return false;
    const n = @min(bytes.len, slot.buf.len);
    @memcpy(slot.buf[0..n], bytes[0..n]);
    slot.len = n;
    slot.truncated = n < bytes.len;
    return true;
}

/// `respond` with `std.fmt` formatting straight into the response buffer —
/// the print-flavored convenience so handlers don't hand-roll a bufPrint.
/// Same single-shot claim semantics; output longer than the window's
/// buffer is truncated at its length and flagged.
pub fn respondFmt(comptime fmt: []const u8, args: anytype) bool {
    const slot = claimSlot() orelse return false;
    var w = std.Io.Writer.fixed(slot.buf);
    w.print(fmt, args) catch {
        // Fixed writer: the buffer prefix up to `end` is written, the
        // rest didn't fit — the documented truncate-at-cap outcome.
        slot.len = w.end;
        slot.truncated = true;
        return true;
    };
    slot.len = w.end;
    slot.truncated = false;
    return true;
}

/// The shared claim gate for `respond`/`respondFmt`: latches
/// first-writer-wins and warns on the two refusal legs.
fn claimSlot() ?*Slot {
    const slot = active_slot orelse {
        std.log.warn(
            "plugin_command.respond called outside a command dispatch window; ignored",
            .{},
        );
        return null;
    };
    if (slot.claimed) {
        std.log.warn(
            "plugin_command.respond: a handler already responded to this command; " ++
                "second response ignored (first-writer-wins)",
            .{},
        );
        return null;
    }
    slot.claimed = true;
    return slot;
}

/// Returns the editor-command mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const GameEvents = Game.GameEvents;
    const has_events = Game.has_events_export;

    // The project carries a plugin-editor-command handler channel iff a
    // plugin/flow subscribed to `engine__editor_plugin_command` (which folds
    // the variant onto the merged `GameEvents`). Absent → `editorPluginCommand`
    // returns -1 and never references the union variant, so an event-less game
    // (`GameEvents = void`) compiles fine and the path folds away entirely —
    // mirrors the input-events scan's `@hasField` gate.
    const has_channel = has_events and blk: {
        const info = @typeInfo(GameEvents);
        if (info != .@"union") break :blk false;
        break :blk @hasField(GameEvents, "engine__editor_plugin_command");
    };

    return struct {
        /// Route a studio-issued play-time plugin command to its declared
        /// handler (the `editor_plugin_command` bridge export's engine end).
        ///
        /// `plugin` is the panel id (the dispatch payload's `plugin_panel`),
        /// `command` the action's `command`, and `params_json` the field
        /// values as a JSON object. All three borrow the caller's buffers for
        /// the duration of the call only.
        ///
        /// Returns 0 when the command was dispatched to a subscriber, or -1
        /// when unroutable: an empty `plugin`/`command` (most likely a
        /// host-side length bug, mirrors `setStateImpl`), or no plugin
        /// subscribed to `engine__editor_plugin_command` (the graceful-degrade
        /// path). The handler's own success/failure is out of band — a
        /// play-time action is fire-and-forward, like an input event.
        ///
        /// This is the v1.7-shaped rc entry, now sugar over
        /// `editorPluginCommandOut` with a zero-length response buffer: the
        /// dispatch WINDOW still exists (so a responding handler driven
        /// through this legacy path never trips the outside-window warn —
        /// its response is just truncated to nothing and discarded), and the
        /// rc semantics are bit-identical to v1.7.
        pub fn editorPluginCommand(
            self: *Game,
            plugin: []const u8,
            command: []const u8,
            params_json: []const u8,
        ) i32 {
            var none: [0]u8 = .{};
            return switch (editorPluginCommandOut(self, plugin, command, params_json, &none)) {
                .unroutable => -1,
                .dispatched, .responded => 0,
            };
        }

        /// Response-aware dispatch (#758): route the command exactly like
        /// `editorPluginCommand` AND collect the (at most one) response a
        /// handler wrote via `plugin_command.respond`/`respondFmt` during
        /// the synchronous dispatch. `out` is the caller's response
        /// storage; `Result.responded.bytes` is a slice of it, so it stays
        /// valid as long as `out` does. Handlers see the response cap as
        /// `out.len` — bridge/contract callers pass `max_response_len`-
        /// sized storage so the whole channel agrees on one cap.
        ///
        /// An empty response (a handler `respond("")`) folds to
        /// `.dispatched`: the sized C returns can't distinguish it from
        /// no-response (0 already means dispatched-no-response), so the
        /// fold happens here, once, for every consumer.
        ///
        /// Zero-cost rule: for a game with no handler channel this returns
        /// `.unroutable` before any window/slot state is touched — the
        /// whole response machinery is reached only from the comptime-live
        /// branch, exactly like the v1.7 path folded away.
        pub fn editorPluginCommandOut(
            self: *Game,
            plugin: []const u8,
            command: []const u8,
            params_json: []const u8,
            out: []u8,
        ) Result {
            // Same leg order as v1.7 pinned: empties are refused even in
            // handler-less builds.
            if (plugin.len == 0 or command.len == 0) return .unroutable;
            if (comptime !has_channel) return .unroutable;
            var slot: Slot = .{ .buf = out };
            // Save/restore rather than set/clear: a handler that itself
            // dispatches a nested plugin command must not tear down THIS
            // window when the inner dispatch returns.
            const prev = active_slot;
            active_slot = &slot;
            defer active_slot = prev;
            // Synchronous dispatch so studio-owned buffers stay valid and the
            // handler runs before we return. The payload type is the merged
            // union's declared shape (`engine.Events.editor_plugin_command`);
            // its `[]const u8` fields borrow the caller's slices for the call.
            const Payload = @FieldType(GameEvents, "engine__editor_plugin_command");
            self.emitSync(@unionInit(GameEvents, "engine__editor_plugin_command", Payload{
                .plugin = plugin,
                .command = command,
                .params = params_json,
            }));
            if (!slot.claimed or slot.len == 0) return .dispatched;
            return .{ .responded = .{
                .bytes = out[0..slot.len],
                .truncated = slot.truncated,
            } };
        }
    };
}
