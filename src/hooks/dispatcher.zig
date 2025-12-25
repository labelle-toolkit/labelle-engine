//! Hook Dispatcher
//!
//! Provides a comptime-based hook dispatcher for zero-overhead event handling.
//! Hooks are resolved entirely at compile time, with no runtime overhead.

const std = @import("std");

/// Creates a hook dispatcher from a comptime hook map.
///
/// The HookMap should be a struct type where each public declaration is either:
/// - A function matching the signature for that hook
/// - A function name matching a hook name (e.g., `game_init`, `scene_load`)
///
/// Example:
/// ```zig
/// const MyHooks = struct {
///     pub fn game_init(payload: HookPayload) void {
///         // Handle game init
///     }
///
///     pub fn scene_load(payload: HookPayload) void {
///         const info = payload.scene_load;
///         std.log.info("Scene loaded: {s}", .{info.name});
///     }
/// };
///
/// const Dispatcher = HookDispatcher(EngineHook, HookPayload, MyHooks);
/// Dispatcher.emit(.{ .scene_load = .{ .name = "main" } });
/// ```
pub fn HookDispatcher(
    comptime HookEnum: type,
    comptime PayloadUnion: type,
    comptime HookMap: type,
) type {
    // Validate that PayloadUnion is a union tagged by HookEnum
    const payload_info = @typeInfo(PayloadUnion);
    if (payload_info != .@"union") {
        @compileError("PayloadUnion must be a union type");
    }
    if (payload_info.@"union".tag_type != HookEnum) {
        @compileError("PayloadUnion must be tagged by HookEnum");
    }

    return struct {
        const Self = @This();

        /// The hook enum type this dispatcher handles.
        pub const Hook = HookEnum;

        /// The payload union type this dispatcher handles.
        pub const Payload = PayloadUnion;

        /// The hook handler map type.
        pub const Handlers = HookMap;

        /// Emit a hook event. Resolved entirely at comptime - no runtime overhead.
        ///
        /// If no handler is registered for the hook, this is a no-op.
        pub inline fn emit(payload: PayloadUnion) void {
            // Use inline switch to resolve hook name at comptime
            switch (payload) {
                inline else => |_, tag| {
                    const hook_name = @tagName(tag);
                    if (@hasDecl(HookMap, hook_name)) {
                        const handler = @field(HookMap, hook_name);
                        handler(payload);
                    }
                    // No handler registered - that's fine, just a no-op
                },
            }
        }

        /// Check at comptime if a hook has a handler registered.
        pub fn hasHandler(comptime hook: HookEnum) bool {
            return @hasDecl(HookMap, @tagName(hook));
        }

        /// Get the number of hooks that have handlers registered.
        pub fn handlerCount() comptime_int {
            var count: comptime_int = 0;
            for (std.enums.values(HookEnum)) |hook| {
                if (@hasDecl(HookMap, @tagName(hook))) {
                    count += 1;
                }
            }
            return count;
        }
    };
}

/// Creates an empty hook dispatcher with no handlers.
/// Useful as a default when no hooks are needed.
pub fn EmptyDispatcher(comptime HookEnum: type, comptime PayloadUnion: type) type {
    return HookDispatcher(HookEnum, PayloadUnion, struct {});
}

/// Merges multiple hook handler structs into one composite dispatcher.
/// When a hook is emitted, all matching handlers from all structs are called in order.
///
/// This enables two-way plugin binding:
/// - Plugins can provide engine hook handlers that get merged with game hooks
/// - Each handler struct can implement any subset of hooks
///
/// Example:
/// ```zig
/// const GameHooks = struct {
///     pub fn game_init(_: HookPayload) void {
///         std.log.info("Game started!", .{});
///     }
/// };
///
/// const PluginHooks = struct {
///     pub fn game_init(_: HookPayload) void {
///         std.log.info("Plugin initialized!", .{});
///     }
///     pub fn frame_start(payload: HookPayload) void {
///         // Plugin frame logic
///     }
/// };
///
/// // Merge game + plugin hooks - both game_init handlers will be called
/// const AllHooks = MergeHooks(EngineHook, HookPayload, .{ GameHooks, PluginHooks });
/// const Game = engine.GameWith(AllHooks);
/// ```
pub fn MergeHooks(
    comptime HookEnum: type,
    comptime PayloadUnion: type,
    comptime handler_structs: anytype,
) type {
    // Validate that PayloadUnion is a union tagged by HookEnum
    const payload_info = @typeInfo(PayloadUnion);
    if (payload_info != .@"union") {
        @compileError("PayloadUnion must be a union type");
    }
    if (payload_info.@"union".tag_type != HookEnum) {
        @compileError("PayloadUnion must be tagged by HookEnum");
    }

    return struct {
        const Self = @This();

        /// The hook enum type this dispatcher handles.
        pub const Hook = HookEnum;

        /// The payload union type this dispatcher handles.
        pub const Payload = PayloadUnion;

        /// Emit a hook event to all registered handlers.
        /// Handlers are called in the order the structs appear in handler_structs.
        /// If no handler is registered for the hook in any struct, this is a no-op.
        pub inline fn emit(payload: PayloadUnion) void {
            switch (payload) {
                inline else => |_, tag| {
                    const hook_name = @tagName(tag);
                    inline for (handler_structs) |H| {
                        if (@hasDecl(H, hook_name)) {
                            const handler = @field(H, hook_name);
                            handler(payload);
                        }
                    }
                },
            }
        }

        /// Check at comptime if any handler struct has a handler for this hook.
        pub fn hasHandler(comptime hook: HookEnum) bool {
            inline for (handler_structs) |H| {
                if (@hasDecl(H, @tagName(hook))) {
                    return true;
                }
            }
            return false;
        }

        /// Get the number of unique hooks that have at least one handler registered.
        pub fn handlerCount() comptime_int {
            var count: comptime_int = 0;
            for (std.enums.values(HookEnum)) |hook| {
                if (hasHandler(hook)) {
                    count += 1;
                }
            }
            return count;
        }

        /// Get the total number of handlers across all structs (including duplicates).
        pub fn totalHandlerCount() comptime_int {
            var count: comptime_int = 0;
            for (std.enums.values(HookEnum)) |hook| {
                const hook_name = @tagName(hook);
                inline for (handler_structs) |H| {
                    if (@hasDecl(H, hook_name)) {
                        count += 1;
                    }
                }
            }
            return count;
        }
    };
}
