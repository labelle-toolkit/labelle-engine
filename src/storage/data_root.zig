//! Stable root selection. Environment/Android context are supplied by the
//! host's runtime service, keeping this module independent of that wiring.
const std = @import("std");
const storage = @import("../storage.zig");
pub const Platform = enum { windows, macos, linux, android };
pub const Inputs = struct {
    platform: Platform,
    app_id: []const u8,
    override: ?[]const u8 = null, // LABELLE_DATA_DIR
    android_internal: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null, // LOCALAPPDATA
    xdg_data_home: ?[]const u8 = null, // XDG_DATA_HOME
    home: ?[]const u8 = null, // HOME
};

pub fn isAbsolute(platform: Platform, path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (platform == .windows) {
        // A single leading slash is rooted on the CURRENT DRIVE, so it is
        // not a stable user directory even though std calls it absolute.
        const sep = struct {
            fn is(c: u8) bool {
                return c == '/' or c == '\\';
            }
        }.is;
        if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and sep(path[2])) return true;
        if (path.len < 5 or !sep(path[0]) or !sep(path[1]) or sep(path[2])) return false;
        var end_server: usize = 2;
        while (end_server < path.len and !sep(path[end_server])) : (end_server += 1) {}
        return end_server + 1 < path.len and !sep(path[end_server + 1]);
    }
    return std.fs.path.isAbsolutePosix(path);
}

/// Owned result. Never falls back to cwd; unresolved Android startup can be
/// retried once its runtime service provides internalDataPath.
pub fn resolve(allocator: std.mem.Allocator, inputs: Inputs) storage.Error![]u8 {
    try storage.validateName(inputs.app_id);
    if (inputs.override) |path| {
        if (!isAbsolute(inputs.platform, path)) return error.Unavailable;
        return allocator.dupe(u8, path);
    }
    if (inputs.platform == .android) {
        const path = inputs.android_internal orelse return error.Unavailable;
        if (!isAbsolute(.android, path)) return error.Unavailable;
        return allocator.dupe(u8, path);
    }
    const base = switch (inputs.platform) {
        .windows => inputs.local_app_data,
        .macos => inputs.home,
        .linux => inputs.xdg_data_home orelse inputs.home,
        .android => unreachable,
    } orelse return error.Unavailable;
    if (!isAbsolute(inputs.platform, base)) return error.Unavailable;
    const middle = switch (inputs.platform) {
        .macos => "/Library/Application Support",
        .linux => if (inputs.xdg_data_home == null) "/.local/share" else "",
        else => "",
    };
    return std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ base, middle, inputs.app_id });
}
