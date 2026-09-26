const std = @import("std");
const s = @import("storage");
const a = std.testing.allocator;

test "default native store preserves explicit save directory and injected store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const Default = s.Default(struct {});
    var selected = try Default.init(a, .{ .app_id = "test-game", .native_directory = buffer[0..length] });
    defer selected.deinit();
    _ = try finish(selected.store(), .{ .write = .{ .name = "old-slot.json", .bytes = "world" } });
    var reopened = try Default.init(a, .{ .app_id = "test-game", .native_directory = buffer[0..length] });
    defer reopened.deinit();
    const read = try finish(reopened.store(), .{ .read = .{ .name = "old-slot.json", .max_bytes = 10 } });
    defer read.deinit(a);
    try std.testing.expectEqualStrings("world", read.read);
    var injected = try Default.init(a, .{ .app_id = "test-game", .native_directory = "ignored", .store = selected.store() });
    defer injected.deinit();
    try std.testing.expect(injected.directory == null);
    _ = try finish(injected.store(), .{ .delete = "old-slot.json" });
    try std.testing.expectError(error.NotFound, finish(reopened.store(), .{ .read = .{ .name = "old-slot.json", .max_bytes = 10 } }));
}

fn failSync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
    return error.NoSpaceLeft;
}

test "failed durable overwrite preserves previous save and does not list temporary files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    var files = try s.Files.init(std.testing.io, buffer[0..length]);
    _ = try finish(files.store(), .{ .write = .{ .name = "a.json", .bytes = "good" } });
    var vtable = std.testing.io.vtable.*;
    vtable.fileSync = failSync;
    var failing_io = std.testing.io;
    failing_io.vtable = &vtable;
    var failed = try s.Files.init(failing_io, buffer[0..length]);
    try std.testing.expectError(error.QuotaExceeded, finish(failed.store(), .{ .write = .{ .name = "a.json", .bytes = "bad" } }));
    const read = try finish(files.store(), .{ .read = .{ .name = "a.json", .max_bytes = 100 } });
    defer read.deinit(a);
    try std.testing.expectEqualStrings("good", read.read);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".pending/orphan", .data = "crash-left bytes" });
    const list = try finish(files.store(), .list);
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), list.list.len);
}

test "missing namespace lists empty, reads missing and is created on first write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const directory = try std.fmt.allocPrint(a, "{s}/new-saves", .{buffer[0..length]});
    defer a.free(directory);
    var files = try s.Files.init(std.testing.io, directory);
    const empty = try finish(files.store(), .list);
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.list.len);
    _ = try finish(files.store(), .{ .delete = "missing" });
    try std.testing.expectError(error.NotFound, finish(files.store(), .{ .read = .{ .name = "missing", .max_bytes = 100 } }));
    _ = try finish(files.store(), .{ .write = .{ .name = "empty", .bytes = "" } });
    const read = try finish(files.store(), .{ .read = .{ .name = "empty", .max_bytes = 0 } });
    defer read.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), read.read.len);
}

fn finish(store: s.Store, request: s.Request) !s.Result {
    var operation = try store.begin(a, request);
    defer operation.deinit();
    return (try operation.poll()) orelse error.UnexpectedPending;
}

test "file blobs survive reopen, overwrite, list metadata and independent sidecars" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    var first = try s.Files.init(std.testing.io, buffer[0..length]);
    _ = try finish(first.store(), .{ .write = .{ .name = "colony.json", .bytes = "first" } });
    _ = try finish(first.store(), .{ .write = .{ .name = "colony.meta", .bytes = "{\"day\":3}" } });
    _ = try finish(first.store(), .{ .write = .{ .name = "second.json", .bytes = "second" } });
    _ = try finish(first.store(), .{ .write = .{ .name = "colony.json", .bytes = "replacement" } });
    var reopened = try s.Files.init(std.testing.io, buffer[0..length]);
    const read = try finish(reopened.store(), .{ .read = .{ .name = "colony.json", .max_bytes = 1024 } });
    defer read.deinit(a);
    try std.testing.expectEqualStrings("replacement", read.read);
    const list = try finish(reopened.store(), .list);
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), list.list.len);
    var found = false;
    for (list.list) |entry| if (std.mem.eql(u8, entry.name, "colony.json")) {
        found = true;
        try std.testing.expectEqual(@as(u64, 11), entry.size);
        try std.testing.expect(entry.modified_ns > 0);
    };
    try std.testing.expect(found);
    _ = try finish(reopened.store(), .{ .delete = "colony.json" });
    _ = try finish(reopened.store(), .{ .delete = "colony.json" });
    try std.testing.expectError(error.NotFound, finish(reopened.store(), .{ .read = .{ .name = "colony.json", .max_bytes = 1024 } }));
    const meta = try finish(reopened.store(), .{ .read = .{ .name = "colony.meta", .max_bytes = 1024 } });
    defer meta.deinit(a);
    try std.testing.expectEqualStrings("{\"day\":3}", meta.read);
    try std.testing.expectError(error.TooLarge, finish(reopened.store(), .{ .read = .{ .name = "second.json", .max_bytes = 2 } }));
}

test "keys cannot escape namespace or select Windows special files" {
    for ([_][]const u8{ "", ".", "..", "../x", "a/b", "a\\b", "C:x", "x:stream", "x\x00", "x.", "x ", "CON", "nul.json", "com1.meta", "LPT9", "\xff" }) |name| {
        try std.testing.expectError(error.InvalidName, s.validateName(name));
    }
    try s.validateName("Colony 2.meta");
    try s.validateName("colônia.json");
    for ([_][]const u8{ "CON .json", "CONIN$", "conout$.meta", "COM¹.json" }) |name| {
        try std.testing.expectError(error.InvalidName, s.validateName(name));
    }
    try std.testing.expectError(error.Unavailable, s.Files.init(std.testing.io, "relative"));
    try std.testing.expect(!s.dataRoot.isAbsolute(.windows, "\\data"));
    try std.testing.expect(!s.dataRoot.isAbsolute(.windows, "C:relative"));
    try std.testing.expect(!s.dataRoot.isAbsolute(.windows, "//server"));
    try std.testing.expect(s.dataRoot.isAbsolute(.windows, "//server/share/data"));
    try std.testing.expect(!s.dataRoot.isAbsolute(.linux, "/data\x00suffix"));
}

test "stable roots use override, OS user data and Android internal path, never cwd" {
    const cases = .{
        .{ s.dataRoot.Inputs{ .platform = .windows, .app_id = "fp", .local_app_data = "C:/Users/u/AppData/Local" }, "C:/Users/u/AppData/Local/fp" },
        .{ s.dataRoot.Inputs{ .platform = .macos, .app_id = "fp", .home = "/Users/u" }, "/Users/u/Library/Application Support/fp" },
        .{ s.dataRoot.Inputs{ .platform = .linux, .app_id = "fp", .home = "/home/u" }, "/home/u/.local/share/fp" },
        .{ s.dataRoot.Inputs{ .platform = .linux, .app_id = "fp", .xdg_data_home = "/data", .home = "/home/u" }, "/data/fp" },
        .{ s.dataRoot.Inputs{ .platform = .android, .app_id = "fp", .android_internal = "/data/user/0/fp/files" }, "/data/user/0/fp/files" },
        .{ s.dataRoot.Inputs{ .platform = .linux, .app_id = "fp", .override = "/chosen" }, "/chosen" },
    };
    inline for (cases) |case| {
        const result = try s.dataRoot.resolve(a, case[0]);
        defer a.free(result);
        try std.testing.expectEqualStrings(case[1], result);
    }
    try std.testing.expectError(error.Unavailable, s.dataRoot.resolve(a, .{ .platform = .android, .app_id = "fp" }));
    try std.testing.expectError(error.Unavailable, s.dataRoot.resolve(a, .{ .platform = .linux, .app_id = "fp", .override = "relative", .home = "/home/u" }));
}

test "linux XDG_DATA_HOME: empty and relative are ignored, absolute wins, unset uses HOME" {
    const cases = .{
        .{ @as(?[]const u8, null), "/home/u/.local/share/fp" },
        .{ @as(?[]const u8, ""), "/home/u/.local/share/fp" },
        .{ @as(?[]const u8, "relative/data"), "/home/u/.local/share/fp" },
        .{ @as(?[]const u8, "/xdg/data"), "/xdg/data/fp" },
    };
    inline for (cases) |case| {
        const result = try s.dataRoot.resolve(a, .{ .platform = .linux, .app_id = "fp", .xdg_data_home = case[0], .home = "/home/u" });
        defer a.free(result);
        try std.testing.expectEqualStrings(case[1], result);
    }
    // An ignored XDG value with no HOME to fall back on is still unavailable.
    try std.testing.expectError(error.Unavailable, s.dataRoot.resolve(a, .{ .platform = .linux, .app_id = "fp", .xdg_data_home = "" }));
}

test "only aged crash-left staging files are purged; live and foreign entries are kept" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    // Simulate an interrupted write: a full blob staged but never renamed.
    try tmp.dir.createDirPath(io, ".pending");
    try tmp.dir.writeFile(io, .{ .sub_path = ".pending/0123456789abcdef", .data = "crash-left blob" });
    const aged = std.Io.Timestamp.now(io, .real).subDuration(.fromSeconds(60 * 60));
    try tmp.dir.setTimestamps(io, ".pending/0123456789abcdef", .{ .access_timestamp = .{ .new = aged }, .modify_timestamp = .{ .new = aged } });
    // Another writer's in-flight staging file: fresh, so it must survive.
    try tmp.dir.writeFile(io, .{ .sub_path = ".pending/1111111111111111", .data = "in-flight blob" });
    // Not ours: wrong name pattern, a directory, and (where supported) a
    // symlink whose target must survive.
    try tmp.dir.writeFile(io, .{ .sub_path = ".pending/notes.txt", .data = "keep" });
    try tmp.dir.createDirPath(io, ".pending/fedcba9876543210");
    try tmp.dir.writeFile(io, .{ .sub_path = "target.json", .data = "keep" });
    const linked = if (tmp.dir.symLink(io, "../target.json", ".pending/aaaaaaaaaaaaaaaa", .{})) true else |_| false;

    var files = try s.Files.init(io, buffer[0..length]);
    _ = try finish(files.store(), .{ .write = .{ .name = "slot.json", .bytes = "live" } });

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".pending/0123456789abcdef", .{}));
    _ = try tmp.dir.statFile(io, ".pending/notes.txt", .{});
    _ = try tmp.dir.statFile(io, ".pending/1111111111111111", .{});
    var kept_dir = try tmp.dir.openDir(io, ".pending/fedcba9876543210", .{});
    kept_dir.close(io);
    if (linked) _ = try tmp.dir.statFile(io, ".pending/aaaaaaaaaaaaaaaa", .{ .follow_symlinks = false });
    const target = try finish(files.store(), .{ .read = .{ .name = "target.json", .max_bytes = 16 } });
    defer target.deinit(a);
    try std.testing.expectEqualStrings("keep", target.read);

    // The live write landed, and no staging file of its own is left behind
    // (the other writer's fresh file is the only staging-named file).
    const read = try finish(files.store(), .{ .read = .{ .name = "slot.json", .max_bytes = 16 } });
    defer read.deinit(a);
    try std.testing.expectEqualStrings("live", read.read);
    var staging = try tmp.dir.openDir(io, ".pending", .{ .iterate = true });
    defer staging.close(io);
    var iterator = staging.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and !std.mem.eql(u8, entry.name, "1111111111111111"))
            try std.testing.expect(!s.Files.isStagingName(entry.name));
    }
    const list = try finish(files.store(), .list);
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), list.list.len); // slot.json + target.json
}

test "staging staleness uses a safety age" {
    const now: std.Io.Timestamp = .fromNanoseconds(100 * std.time.ns_per_hour);
    try std.testing.expect(!s.Files.isStaleStaging(now, now));
    try std.testing.expect(!s.Files.isStaleStaging(now.subDuration(.fromSeconds(9 * 60)), now));
    try std.testing.expect(s.Files.isStaleStaging(now.subDuration(.fromSeconds(11 * 60)), now));
    // A file stamped in the future (clock skew) is never stale.
    try std.testing.expect(!s.Files.isStaleStaging(now.addDuration(.fromSeconds(60 * 60)), now));
}

test "list stats unknown directory-entry kinds; only regular files are candidates" {
    try std.testing.expect(s.Files.isEntryCandidate(.file));
    try std.testing.expect(s.Files.isEntryCandidate(.unknown));
    for ([_]std.Io.File.Kind{ .directory, .sym_link, .named_pipe, .block_device, .character_device, .unix_domain_socket }) |kind| {
        try std.testing.expect(!s.Files.isEntryCandidate(kind));
    }
}

test "reads refuse a symlinked key; regular keys still read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    try tmp.dir.createDirPath(io, "saves");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "secret" });
    try tmp.dir.writeFile(io, .{ .sub_path = "saves/slot.json", .data = "save" });
    const directory = try std.fmt.allocPrint(a, "{s}/saves", .{buffer[0..length]});
    defer a.free(directory);
    var files = try s.Files.init(io, directory);
    const read = try finish(files.store(), .{ .read = .{ .name = "slot.json", .max_bytes = 16 } });
    defer read.deinit(a);
    try std.testing.expectEqualStrings("save", read.read);
    // Symlink creation may be unprivileged-forbidden (Windows); skip then.
    tmp.dir.symLink(io, "../outside.txt", "saves/linked.json", .{}) catch return error.SkipZigTest;
    try std.testing.expectError(error.AccessDenied, finish(files.store(), .{ .read = .{ .name = "linked.json", .max_bytes = 16 } }));
    // A directory under a valid key is refused too, not read.
    try tmp.dir.createDirPath(io, "saves/dir.json");
    try std.testing.expectError(error.AccessDenied, finish(files.store(), .{ .read = .{ .name = "dir.json", .max_bytes = 16 } }));
    // Neither the link nor the directory is listed.
    const list = try finish(files.store(), .list);
    defer list.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), list.list.len);
}

test "native directory resolves once with the Files.init stable-path rule" {
    const cases = .{
        // Windows current-drive-rooted and relative paths use cwd's drive.
        .{ s.dataRoot.Platform.windows, "C:\\game", "\\saves", "C:\\saves" },
        .{ s.dataRoot.Platform.windows, "D:\\game", "/saves", "D:\\saves" },
        .{ s.dataRoot.Platform.windows, "C:\\game", "saves", "C:\\game\\saves" },
        .{ s.dataRoot.Platform.windows, "C:\\game", "C:saves", "C:\\game\\saves" },
        .{ s.dataRoot.Platform.windows, "C:\\game", "E:\\keep", "E:\\keep" },
        .{ s.dataRoot.Platform.windows, "C:\\game", "//server/share/saves", "//server/share/saves" },
        .{ s.dataRoot.Platform.linux, "/home/u/game", "saves", "/home/u/game/saves" },
        .{ s.dataRoot.Platform.linux, "/home/u/game", "/saves", "/saves" },
    };
    inline for (cases) |case| {
        const result = try s.dataRoot.resolveDirectory(a, case[0], case[1], case[2]);
        defer a.free(result);
        try std.testing.expectEqualStrings(case[3], result);
        try std.testing.expect(s.dataRoot.isAbsolute(case[0], result));
    }
    // A drive-relative path on ANOTHER drive cannot be resolved stably.
    try std.testing.expectError(error.Unavailable, s.dataRoot.resolveDirectory(a, .windows, "C:\\game", "D:saves"));
    try std.testing.expectError(error.Unavailable, s.dataRoot.resolveDirectory(a, .windows, "\\game", "saves"));
}

const Bridge = struct {
    var status_code: i32 = 0;
    var released: usize = 0;
    var payload: []const u8 = "bytes";
    pub fn begin(_: []const u8, _: u32, _: []const u8, _: []const u8, _: usize) u32 {
        return 1;
    }
    pub fn status(_: u32) i32 {
        return status_code;
    }
    pub fn length(_: u32) usize {
        return payload.len;
    }
    pub fn copy(_: u32, bytes: []u8) bool {
        @memcpy(bytes, payload);
        return true;
    }
    pub fn release(_: u32) void {
        released += 1;
    }
};

test "web pending is not success; commit and typed failure consume operation once" {
    Bridge.status_code = 0;
    Bridge.released = 0;
    var web: s.Web(Bridge) = .{ .namespace = "fp" };
    var op = try web.store().begin(a, .{ .write = .{ .name = "q.json", .bytes = "bytes" } });
    defer op.deinit();
    try std.testing.expectEqual(null, try op.poll());
    try std.testing.expectEqual(@as(usize, 0), Bridge.released);
    Bridge.status_code = 1;
    try std.testing.expectEqual(s.Result.written, (try op.poll()).?);
    try std.testing.expectError(error.InvalidOperation, op.poll());
    try std.testing.expectEqual(@as(usize, 1), Bridge.released);
    var failed = try web.store().begin(a, .{ .delete = "q.json" });
    defer failed.deinit();
    Bridge.status_code = -2;
    try std.testing.expectError(error.QuotaExceeded, failed.poll());
    try std.testing.expectEqual(@as(usize, 2), Bridge.released);
}

test "web read and list ownership, malformed list and dropped pending operation" {
    var web: s.Web(Bridge) = .{ .namespace = "fp" };
    Bridge.status_code = 1;
    Bridge.payload = "save";
    const read = try finish(web.store(), .{ .read = .{ .name = "a.json", .max_bytes = 8 } });
    defer read.deinit(a);
    try std.testing.expectEqualStrings("save", read.read);
    Bridge.payload = "[{\"name\":\"a.meta\",\"size\":7,\"modified_ms\":42}]";
    const entries = try finish(web.store(), .list);
    defer entries.deinit(a);
    try std.testing.expectEqualStrings("a.meta", entries.list[0].name);
    try std.testing.expectEqual(@as(i128, 42_000_000), entries.list[0].modified_ns);
    Bridge.payload = "invalid";
    try std.testing.expectError(error.IoFailure, finish(web.store(), .list));
    Bridge.status_code = 0;
    Bridge.released = 0;
    var dropped = try web.store().begin(a, .list);
    dropped.deinit();
    try std.testing.expectEqual(@as(usize, 1), Bridge.released);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var web: s.Web(Bridge) = .{ .namespace = "fp" };
    var operation = try web.store().begin(allocator, .list);
    defer operation.deinit();
    const result = (try operation.poll()).?;
    defer result.deinit(allocator);
}

test "web result allocation failures release handles and partially built lists" {
    Bridge.status_code = 1;
    Bridge.payload = "[{\"name\":\"a.json\",\"size\":1,\"modified_ms\":1},{\"name\":\"b.json\",\"size\":2,\"modified_ms\":2}]";
    try std.testing.checkAllAllocationFailures(a, allocationExercise, .{});
}
