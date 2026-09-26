//! Target default storage with optional explicit injection. The backend only
//! supplies web bindings; native persistence stays engine-owned.
const std = @import("std");
const builtin = @import("builtin");
const storage = @import("../storage.zig");
const io_helper = @import("../io_helper.zig");

pub fn Default(comptime Backend: type) type {
    const web = builtin.os.tag == .emscripten;
    const HasWeb = @hasDecl(Backend, "PersistentStorage");
    return struct {
        allocator: std.mem.Allocator,
        directory: ?[]u8 = null,
        files: storage.Files = undefined,
        browser: if (web and HasWeb) storage.Web(Backend.PersistentStorage) else void = if (web and HasWeb) undefined else {},
        injected: ?storage.Store = null,
        const Self = @This();

        pub const Options = struct {
            app_id: []const u8,
            /// Preserve an existing game's save directory when adopting the
            /// seam. Relative values resolve ONCE to an absolute directory.
            native_directory: ?[]const u8 = null,
            store: ?storage.Store = null,
        };

        pub fn init(allocator: std.mem.Allocator, options: Options) storage.Error!Self {
            try storage.validateName(options.app_id);
            var self: Self = .{ .allocator = allocator, .injected = options.store };
            if (options.store != null) return self;
            if (comptime web) {
                if (comptime !HasWeb) return error.Unavailable;
                self.directory = try allocator.dupe(u8, options.app_id);
                self.browser = .{ .namespace = self.directory.? };
                return self;
            }
            const io = io_helper.io();
            if (options.native_directory) |path| {
                if (std.fs.path.isAbsolute(path)) {
                    self.directory = try allocator.dupe(u8, path);
                } else {
                    var cwd: [std.fs.max_path_bytes]u8 = undefined;
                    const length = std.Io.Dir.cwd().realPath(io, &cwd) catch return error.Unavailable;
                    self.directory = try std.fs.path.resolve(allocator, &.{ cwd[0..length], path });
                }
            } else {
                const android = builtin.abi == .android or builtin.abi == .androideabi;
                const platform: storage.dataRoot.Platform = if (android) .android else switch (builtin.os.tag) {
                    .windows => .windows,
                    .macos => .macos,
                    .linux => .linux,
                    else => return error.Unavailable,
                };
                const root = try storage.dataRoot.resolve(allocator, .{
                    .platform = platform,
                    .app_id = options.app_id,
                    .override = env("LABELLE_DATA_DIR"),
                    .home = env("HOME"),
                    .local_app_data = env("LOCALAPPDATA"),
                    .xdg_data_home = env("XDG_DATA_HOME"),
                    .android_internal = if (android) androidPath() else null,
                });
                defer allocator.free(root);
                self.directory = try std.fs.path.join(allocator, &.{ root, "saves" });
            }
            errdefer allocator.free(self.directory.?);
            self.files = try storage.Files.init(io, self.directory.?);
            return self;
        }

        pub fn store(self: *Self) storage.Store {
            if (self.injected) |selected| return selected;
            if (comptime web) {
                if (comptime HasWeb) return self.browser.store();
                unreachable;
            }
            return self.files.store();
        }

        pub fn deinit(self: *Self) void {
            if (self.directory) |path| self.allocator.free(path);
            self.directory = null;
        }
    };
}

fn env(comptime name: [:0]const u8) ?[]const u8 {
    if (comptime !builtin.link_libc) return null;
    return if (std.c.getenv(name)) |value| std.mem.span(value) else null;
}

fn androidPath() ?[]const u8 {
    const core = @import("labelle-core");
    const context = core.android_backend.get() orelse return null;
    const raw = context.get_native_activity() orelse return null;
    const Prefix = extern struct {
        callbacks: ?*anyopaque,
        vm: ?*anyopaque,
        env: ?*anyopaque,
        clazz: ?*anyopaque,
        internal_data_path: ?[*:0]const u8,
    };
    const activity: *const Prefix = @ptrCast(@alignCast(raw));
    return if (activity.internal_data_path) |path| std.mem.span(path) else null;
}
