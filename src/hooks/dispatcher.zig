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

// ============================================
// Tests
// ============================================

const testing = std.testing;

const TestHook = enum {
    on_start,
    on_update,
    on_end,
};

const TestPayload = union(TestHook) {
    on_start: void,
    on_update: f32,
    on_end: void,
};

var test_start_called: bool = false;
var test_update_value: f32 = 0;

const TestHandlers = struct {
    pub fn on_start(_: TestPayload) void {
        test_start_called = true;
    }

    pub fn on_update(payload: TestPayload) void {
        test_update_value = payload.on_update;
    }
    // Note: on_end has no handler
};

test "HookDispatcher emits to registered handlers" {
    const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);

    test_start_called = false;
    Dispatcher.emit(.{ .on_start = {} });
    try testing.expect(test_start_called);
}

test "HookDispatcher passes payload to handler" {
    const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);

    test_update_value = 0;
    Dispatcher.emit(.{ .on_update = 0.016 });
    try testing.expectApproxEqAbs(@as(f32, 0.016), test_update_value, 0.0001);
}

test "HookDispatcher is no-op for unregistered hooks" {
    const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);

    // on_end has no handler, should not crash
    Dispatcher.emit(.{ .on_end = {} });
}

test "hasHandler returns correct values" {
    const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);

    try testing.expect(Dispatcher.hasHandler(.on_start));
    try testing.expect(Dispatcher.hasHandler(.on_update));
    try testing.expect(!Dispatcher.hasHandler(.on_end));
}

test "handlerCount returns correct count" {
    const Dispatcher = HookDispatcher(TestHook, TestPayload, TestHandlers);
    try testing.expectEqual(2, Dispatcher.handlerCount());
}

test "EmptyDispatcher has no handlers" {
    const Dispatcher = EmptyDispatcher(TestHook, TestPayload);

    try testing.expect(!Dispatcher.hasHandler(.on_start));
    try testing.expect(!Dispatcher.hasHandler(.on_update));
    try testing.expect(!Dispatcher.hasHandler(.on_end));
    try testing.expectEqual(0, Dispatcher.handlerCount());

    // Should not crash
    Dispatcher.emit(.{ .on_start = {} });
    Dispatcher.emit(.{ .on_update = 0.016 });
    Dispatcher.emit(.{ .on_end = {} });
}
