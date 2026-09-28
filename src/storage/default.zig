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
            /// The app-private root the platform package supplies (a mobile
            /// app's internal storage). Saves go to `<platform_root>/saves`;
            /// without it the OS user-data default is used.
            platform_root: ?[]const u8 = null,
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
                // Same stable-path rule as Files.init: on Windows `\saves`
                // is rooted on the CURRENT drive, so it is resolved here.
                const platform: storage.dataRoot.Platform = if (builtin.os.tag == .windows) .windows else .linux;
                if (storage.dataRoot.isAbsolute(platform, path)) {
                    self.directory = try allocator.dupe(u8, path);
                } else {
                    // `std.process.currentPath`, NOT `Dir.cwd().realPath`:
                    // on Zig 0.16 the cwd handle is AT_FDCWD (not a real fd)
                    // and realPath on it fails with FileNotFound (#895). The
                    // target need not exist; Files creates it on first write.
                    var cwd: [std.fs.max_path_bytes]u8 = undefined;
                    const length = std.process.currentPath(io, &cwd) catch return error.Unavailable;
                    self.directory = try storage.dataRoot.resolveDirectory(allocator, platform, cwd[0..length], path);
                }
            } else {
                const platform: storage.dataRoot.Platform = switch (builtin.os.tag) {
                    .windows => .windows,
                    .macos => .macos,
                    .linux => .linux,
                    // Any other OS has no user-data default here, but a
                    // supplied `platform_root` still works; it is checked
                    // with POSIX path rules.
                    else => if (options.platform_root != null) .linux else return error.Unavailable,
                };
                const root = try storage.dataRoot.resolve(allocator, .{
                    .platform = platform,
                    .app_id = options.app_id,
                    .override = env("LABELLE_DATA_DIR"),
                    .home = env("HOME"),
                    .local_app_data = env("LOCALAPPDATA"),
                    .xdg_data_home = env("XDG_DATA_HOME"),
                    .platform_root = options.platform_root,
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
