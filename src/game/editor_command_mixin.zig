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

const std = @import("std");

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
        pub fn editorPluginCommand(
            self: *Game,
            plugin: []const u8,
            command: []const u8,
            params_json: []const u8,
        ) i32 {
            if (plugin.len == 0 or command.len == 0) return -1;
            if (comptime !has_channel) return -1;
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
            return 0;
        }
    };
}
