//! Hook Dispatcher — receiver-based, comptime-validated.
//!
//! Adapted from labelle-core's dispatcher pattern. Provides zero-overhead
//! event handling with comptime typo detection and optional exhaustive mode.

const std = @import("std");

/// Unwrap pointer types to get the underlying struct for comptime inspection.
/// *T -> T, **T -> T, T -> T
pub fn UnwrapReceiver(comptime T: type) type {
    var Current = T;
    while (@typeInfo(Current) == .pointer) {
        Current = @typeInfo(Current).pointer.child;
    }
    return Current;
}

/// Core hook dispatcher — receiver-based, comptime-validated.
///
/// PayloadUnion: tagged union of event payloads (field names = event names)
/// Receiver: struct (or pointer to struct) with handler methods matching union field names
/// Options: .exhaustive = true to require handlers for all events
///
/// Example:
/// ```zig
/// const MyHooks = struct {
///     pub fn game_init(_: @This(), info: GameInitInfo) void {
///         // Handle game init
///     }
/// };
///
/// const D = HookDispatcher(HookPayload, MyHooks, .{});
/// const d = D{ .receiver = .{} };
/// d.emit(.{ .game_init = .{ .allocator = allocator } });
/// ```
pub fn HookDispatcher(
    comptime PayloadUnion: type,
    comptime Receiver: type,
    comptime options: struct { exhaustive: bool = false },
) type {
    const Base = UnwrapReceiver(Receiver);

    comptime {
        for (std.meta.declarations(Base)) |decl| {
            if (fieldIndex(PayloadUnion, decl.name) == null) {
                if (@hasDecl(Base, decl.name)) {
                    const DeclType = @TypeOf(@field(Base, decl.name));
                    const info = @typeInfo(DeclType);
                    if (info == .@"fn" and (info.@"fn".params.len == 1 or info.@"fn".params.len == 2)) {
                        @compileError(
                            "Handler '" ++ decl.name ++ "' in " ++ @typeName(Base) ++
                                " doesn't match any event in " ++ @typeName(PayloadUnion) ++
                                ". Did you mean one of: " ++ fieldNames(PayloadUnion) ++ "?",
                        );
                    }
                }
            }
        }

        if (options.exhaustive) {
            for (std.meta.fields(PayloadUnion)) |field| {
                if (!@hasDecl(Base, field.name)) {
                    @compileError(
                        "Exhaustive mode: event '" ++ field.name ++ "' in " ++
                            @typeName(PayloadUnion) ++ " has no handler in " ++
                            @typeName(Base),
                    );
                }
            }
        }
    }

    return struct {
        receiver: Receiver,

        const Self = @This();

        pub fn emit(self: Self, payload: PayloadUnion) void {
            switch (payload) {
                inline else => |data, tag| {
                    const name = @tagName(tag);
                    if (@hasDecl(Base, name)) {
                        const handler = @field(Base, name);
                        const params = @typeInfo(@TypeOf(handler)).@"fn".params;
                        if (params.len == 1) {
                            // 1-arg handler: check if it expects the full union or inner data
                            const param_type = params[0].type.?;
                            if (param_type == PayloadUnion) {
                                handler(payload);
                            } else {
                                handler(data);
                            }
                        } else {
                            handler(self.receiver, data);
                        }
                    }
                },
            }
        }

        pub fn hasHandler(comptime event_name: []const u8) bool {
            return @hasDecl(Base, event_name);
        }
    };
}

/// Compose N receiver types into one merged dispatcher.
/// When a hook is emitted, all matching handlers from all receiver types
/// are called in order.
///
/// Example:
/// ```zig
/// const AllHooks = MergeHooks(HookPayload, .{ GameHooks, PluginHooks });
/// const hooks = AllHooks{ .receivers = .{ GameHooks{}, PluginHooks{} } };
/// hooks.emit(.{ .game_init = .{ .allocator = allocator } });
/// ```
pub fn MergeHooks(
    comptime PayloadUnion: type,
    comptime ReceiverTypes: anytype,
) type {
    comptime {
        for (ReceiverTypes) |RT| {
            const Base = UnwrapReceiver(RT);
            for (std.meta.declarations(Base)) |decl| {
                if (@hasDecl(Base, decl.name)) {
                    const DeclType = @TypeOf(@field(Base, decl.name));
                    const info = @typeInfo(DeclType);
                    if (info == .@"fn" and (info.@"fn".params.len == 1 or info.@"fn".params.len == 2)) {
                        if (fieldIndex(PayloadUnion, decl.name) == null) {
                            @compileError(
                                "Handler '" ++ decl.name ++ "' in " ++ @typeName(Base) ++
                                    " doesn't match any event in " ++ @typeName(PayloadUnion),
                            );
                        }
                    }
                }
            }
        }
    }

    return struct {
        receivers: ReceiverInstances(ReceiverTypes),

        const Self = @This();

        pub fn emit(self: Self, payload: PayloadUnion) void {
            switch (payload) {
                inline else => |data, tag| {
                    const name = @tagName(tag);
                    inline for (0..ReceiverTypes.len) |i| {
                        const Base = UnwrapReceiver(ReceiverTypes[i]);
                        if (@hasDecl(Base, name)) {
                            const handler = @field(Base, name);
                            const params = @typeInfo(@TypeOf(handler)).@"fn".params;
                            if (params.len == 1) {
                                const param_type = params[0].type.?;
                                if (param_type == PayloadUnion) {
                                    handler(payload);
                                } else {
                                    handler(data);
                                }
                            } else {
                                handler(self.receivers[i], data);
                            }
                        }
                    }
                },
            }
        }
    };
}

fn ReceiverInstances(comptime Types: anytype) type {
    var fields: [Types.len]std.builtin.Type.StructField = undefined;
    for (0..Types.len) |i| {
        const name = std.fmt.comptimePrint("{d}", .{i});
        fields[i] = .{
            .name = name,
            .type = Types[i],
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Types[i]),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

fn fieldIndex(comptime T: type, comptime name: []const u8) ?usize {
    for (std.meta.fields(T), 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return i;
    }
    return null;
}

fn fieldNames(comptime T: type) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (std.meta.fields(T), 0..) |field, i| {
            if (i > 0) result = result ++ ", ";
            result = result ++ field.name;
        }
        return result;
    }
}
