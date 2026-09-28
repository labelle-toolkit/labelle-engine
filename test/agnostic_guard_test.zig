//! Guard for labelle-engine#902: the engine under `src/` must not name
//! platforms, stores, packages or backends. Platform behaviour belongs in the
//! platform packages (labelle-android, labelle-ios, labelle-web) and in the
//! backends; the engine only knows backend-agnostic seams and the host OS it
//! runs on. This is the same rule, and the same guard, as the CLI core's
//! (labelle-cli `src/agnostic_guard_test.zig`, RFC #406), copied so the two
//! cannot drift in what they consider a platform name.
//!
//! Walks every source file under `src/` at test time (`.zig`, plus the
//! compiled `.c`/`.h` vendored there), splits each into `[A-Za-z0-9]+` runs
//! and compares each run case-insensitively against `forbidden`, first as a
//! whole and then piece by piece at CamelCase boundaries, joining up to
//! `max_join` adjacent pieces so a name that itself spans a boundary
//! (`UI|Kit` in `UIKitView`) still flags. A token that ends
//! in digits is also compared by its letter root, so a version or bit-width
//! suffix does not hide a name. So `ios_cmd`, `storage/android/`, `IosConfig`,
//! `iOS`, `iOSConfig`, `getSDLPath`, `wasm32`, `android14`, `sdl3` and
//! `Wasm32Target` flag while `std.Io`, `biosphere`, `Iostream`, `iostream`,
//! `win32`, `x86_64`, `utf8`, `base64` and `sha256` do not. The file's
//! path relative to `src/` is scanned the same way: a file whose directory
//! or name carries a platform (`assets/steam/upload.zig`) is a finding even
//! when its contents are clean, so renaming and moving files stays part of
//! the migration. Comments count: the mandate is textual, so a doc comment
//! naming a platform is a finding too. Non-source files (JSON, Markdown)
//! stay out of scope: only `.zig`, `.c` and `.h` are read.
//!
//! Files that still carry legacy platform code sit on `allowed_files`, a
//! migration allowlist that can only SHRINK: the test also fails when an
//! allowlisted file no longer contains any forbidden word, so the entry has
//! to go. The run step sets the working directory to the repository root
//! (build.zig, `addAgnosticGuard`); the walk must reach `root_file`, or the
//! test fails instead of passing vacuously.
const std = @import("std");

/// Platform, store, package and backend names the core must not mention.
/// Canonical lowercase; a token is compared after lowercasing. `web` is the
/// platform the RFC moves into the `labelle-web` provider, alongside its
/// `wasm`/`emsdk` toolchain names. The Apple target platforms sit beside
/// `ios`: `macos` is a host the core runs on, `tvos`, `watchos`, `visionos`
/// and `maccatalyst` are only ever targets. The RFC's provider tools and
/// SDKs follow: `butler` (itch), `uikit` (iOS glue), `steamworks` and
/// `steamcmd` (Steam), `xcodebuild`, `adb`, `gradlew` and `emcc`.
const forbidden = [_][]const u8{
    "android",  "ios",         "web",     "wasm",  "emsdk",      "emscripten", "steam",
    "itch",     "xcode",       "gradle",  "apk",   "aab",        "ndk",        "raylib",
    "sokol",    "sdl",         "sdl2",    "bgfx",  "wgpu",       "tvos",       "watchos",
    "visionos", "maccatalyst", "butler",  "uikit", "steamworks", "steamcmd",   "xcodebuild",
    "adb",      "emcc",        "gradlew",
};

/// Package and compound affixes around a forbidden root: `libsdl2`
/// (`libsdl2-dev` tokenizes as `libsdl2`, `dev`), `Steamworks`, `steamcmd`,
/// `xcodebuild`, `androidsdk`. Only a whole run or CamelCase piece that is
/// exactly `[lib]<root>[suffix]` flags, so `library`, `worksheet`, `devices`,
/// `buildkit`, `rebuild` and `frameworks` stay clean: their remainder is not
/// a forbidden root.
const affix_prefix = "lib";
const affix_suffixes = [_][]const u8{ "works", "cmd", "build", "dev", "sdk" };

/// Host OS names: the core legitimately branches on the OS it runs on,
/// so these are permanently allowed and never flagged. Exact forms: `win32`
/// is allowed as spelled, and its root `win` is not forbidden, so the
/// numeric-suffix rule in `classify` cannot reach past it.
const allowed_words = [_][]const u8{ "macos", "windows", "linux", "darwin", "win32" };

/// Migration allowlist: the files under `src/` that named a platform, store,
/// package or backend when the guard landed (labelle-engine#902). One path per
/// entry, relative to `src/`, so a new file is never exempt. The list only
/// shrinks: an entry whose file is clean (or gone) fails the guard as stale,
/// so moving platform code out has to delete its line here.
const allowed_files = [_][]const u8{
    "android.zig",
    "assets/catalog/engine.zig",
    "assets/catalog/tests_main_thread.zig",
    "assets/catalog/tests_surface_loss.zig",
    "assets/loaders/audio.zig",
    "assets/mod.zig",
    "assets/worker.zig",
    "atlas.zig",
    "controller_manager.zig",
    "editor_api.zig",
    "game.zig",
    "game/atlas_mixin.zig",
    "game/editor_command_mixin.zig",
    "game/game_init.zig",
    "game/input_events_mixin.zig",
    "game/input_mixin.zig",
    "game/lifecycle_mixin.zig",
    "game/mesh_mixin.zig",
    "game/misc_mixin.zig",
    "game/render_target_mixin.zig",
    "game/save_load/render_gate.zig",
    "game/state_mixin.zig",
    "game/ui_kit_mixin.zig",
    "game/video_mixin.zig",
    "input_types.zig",
    "io_helper.zig",
    "jsonc/deserializer.zig",
    "jsonc/prefab_cache.zig",
    "jsonc/scene_loader/nested_spawn.zig",
    "jsonc/scene_loader/scene_process.zig",
    "jsonc/unified_format.zig",
    "particles_tick.zig",
    "preview/connection.zig",
    "preview/protocol.zig",
    "preview_capture.zig",
    "preview_shm.zig",
    "root.zig",
    "screenshot_request.zig",
    "storage.zig",
    "storage/data_root.zig",
    "storage/default.zig",
    "storage/files.zig",
    "storage/web.zig",
    "tilemap_runtime.zig",
    "ui_draw_list.zig",
};

const finding_note = "(platform/store/package/backend names belong in platform packages or backends; see labelle-engine#902)";

/// The engine's root source (build.zig's module `root_source_file`). The walk
/// must see it: a wrong working directory would otherwise scan nothing and
/// pass.
const root_file = "root.zig";

/// Extensions the guard reads: Zig, and the vendored C compiled into the
/// binary (`build.zig`, `wireStb`).
const source_exts = [_][]const u8{ ".zig", ".c", ".h" };

fn isSource(path: []const u8) bool {
    for (source_exts) |e| if (std.mem.endsWith(u8, path, e)) return true;
    return false;
}

/// Longest entry of `forbidden`; longer runs cannot match and are skipped
/// without lowercasing.
const max_word_len = blk: {
    var n: usize = 0;
    for (forbidden) |w| n = @max(n, w.len);
    break :blk n;
};

comptime {
    // A host OS name on the forbidden table would make `allowed_words`
    // silently win; keep the two tables disjoint.
    for (allowed_words) |a| for (forbidden) |f| if (std.mem.eql(u8, a, f))
        @compileError("'" ++ a ++ "' is both allowed and forbidden");
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// The canonical forbidden word `run` spells exactly (case-insensitively),
/// or null: a host OS name, or nothing on either table.
fn classifyExact(run: []const u8) ?[]const u8 {
    if (run.len > max_word_len) return null;
    var buf: [max_word_len]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..run.len], run);
    for (allowed_words) |a| if (std.mem.eql(u8, a, lower)) return null;
    for (forbidden) |f| if (std.mem.eql(u8, f, lower)) return f;
    return null;
}

/// The canonical forbidden word `run` spells, or null. Exact spelling
/// first (so `sdl2` and the allowed `win32` resolve as listed); then, when
/// the run is `<letters><digits>`, its letter root, so a version or
/// bit-width suffix does not hide a name: `wasm32`, `android14`, `sdl3` and
/// `bgfx2` flag. `win32`, `x86_64`, `utf8`, `base64` and `sha256` do not:
/// `win32` is allowed as spelled and `win`, `x`, `utf`, `base` and `sha` are
/// not forbidden. An all-digit run has no root and never matches.
fn classifyRoot(run: []const u8) ?[]const u8 {
    if (classifyExact(run)) |word| return word;
    var root = run.len;
    while (root > 0 and std.ascii.isDigit(run[root - 1])) root -= 1;
    if (root == 0 or root == run.len) return null;
    return classifyExact(run[0..root]);
}

/// `classifyRoot`, then the run with a `lib` prefix and/or one of
/// `affix_suffixes` removed (`libsdl2`, `itchworks`, `libwasmdev`). The
/// remainder must itself classify, so ordinary words that merely share an
/// affix (`library`, `rebuild`, `frameworks`) stay clean.
fn classify(run: []const u8) ?[]const u8 {
    if (classifyRoot(run)) |word| return word;
    const bodies = [_][]const u8{ run, stripPrefix(run) orelse "" };
    for (bodies, 0..) |body, i| {
        if (body.len == 0) continue;
        if (i > 0) if (classifyRoot(body)) |word| return word;
        for (affix_suffixes) |suf| {
            if (body.len <= suf.len or !std.ascii.endsWithIgnoreCase(body, suf)) continue;
            if (classifyRoot(body[0 .. body.len - suf.len])) |word| return word;
        }
    }
    return null;
}

fn stripPrefix(run: []const u8) ?[]const u8 {
    if (run.len <= affix_prefix.len or !std.ascii.startsWithIgnoreCase(run, affix_prefix)) return null;
    return run[affix_prefix.len..];
}

/// True when a CamelCase boundary falls between `text[i - 1]` and
/// `text[i]`, both word bytes of the piece starting at `start`: a lowercase
/// letter or digit followed by an uppercase one (`getSDL`, `Sdl2Provision`),
/// or the last letter of an uppercase run when a lowercase letter follows
/// it (`SDL|Path`). Digits never start a piece, so `sdl2` and `win32` stay
/// whole. A run that opens with one lowercase letter and then two or more
/// uppercase ones is a lowercase-leading acronym (`iOS`, `iOSConfig`): no
/// boundary after its first letter, so it splits as `iOS|Config`, not
/// `i|OS|Config`. The same acronym embedded after a lowercase prefix
/// (`getiOSConfig`, `getiOsConfig`) opens its own piece: a boundary falls
/// before an `i` that follows a lowercase letter and starts `iOS` or `iOs`,
/// so the run splits as `get|iOS|Config` (or `get|i|Os|Config`, which the
/// tokenizer's joins read back as `iOs`). Only that literal: an `i` ending a
/// word before another acronym (`apiSDLConfig`) is not split off, so the
/// acronym keeps its own piece (`api|SDL|Config`). That `i` is the only
/// lowercase letter that starts a piece; every other piece starts at an
/// uppercase one.
fn splitsBefore(text: []const u8, start: usize, i: usize) bool {
    const prev = text[i - 1];
    const cur = text[i];
    if (cur == 'i' and std.ascii.isLower(prev) and i + 2 < text.len and
        text[i + 1] == 'O' and (text[i + 2] == 'S' or text[i + 2] == 's')) return true;
    if (!std.ascii.isUpper(cur)) return false;
    if (std.ascii.isLower(prev)) {
        const leading_acronym = i == start + 1 and i + 1 < text.len and std.ascii.isUpper(text[i + 1]);
        return !leading_acronym;
    }
    if (std.ascii.isDigit(prev)) return true;
    return i + 1 < text.len and std.ascii.isLower(text[i + 1]);
}

/// Most adjacent CamelCase pieces of one run the tokenizer joins before
/// classifying: an acronym-split name (`UI|Kit`, `X|Code`) plus one affix
/// piece (`Lib|SDL|Dev`). Digits stay on their piece (`UI|Kit2`).
const max_join = 3;

/// Yields the forbidden words of `text` in order of occurrence. Each
/// `[A-Za-z0-9]+` run is classified whole first (`iOS`, `ANDROID`), then,
/// when the whole run is not a forbidden word, piece by piece: at each piece
/// the join of the next `max_join` pieces, then the next `max_join - 1`, is
/// tried before the piece alone, longest first, so a name that spans a
/// CamelCase boundary (`UI|Kit` in `UIKitView`, `UI|Kit2` in `UIKit2Glue`)
/// flags while a join that is not a whole name (`U|Int|Kind`, `Gui|Kit`,
/// `Ui|Kitchen`) stays clean. A matched join consumes its pieces.
const Tokenizer = struct {
    text: []const u8,
    pos: usize = 0,
    /// End of the run currently being split into pieces; `pos == run_end`
    /// between runs.
    run_end: usize = 0,

    fn next(self: *Tokenizer) ?[]const u8 {
        while (true) {
            if (self.pos >= self.run_end) {
                while (self.pos < self.text.len and !isWordByte(self.text[self.pos])) self.pos += 1;
                if (self.pos >= self.text.len) return null;
                const start = self.pos;
                var end = start;
                while (end < self.text.len and isWordByte(self.text[end])) end += 1;
                self.run_end = end;
                if (classify(self.text[start..end])) |word| {
                    self.pos = end;
                    return word;
                }
            }
            const start = self.pos;
            // Ends of the next (up to) `max_join` pieces; each piece's own
            // start feeds `splitsBefore`, as for a single piece.
            var ends: [max_join]usize = undefined;
            var n: usize = 0;
            var p = start;
            while (n < max_join and p < self.run_end) : (n += 1) {
                const piece = p;
                p += 1;
                while (p < self.run_end and !splitsBefore(self.text, piece, p)) p += 1;
                ends[n] = p;
            }
            var k = n;
            while (k > 1) : (k -= 1) {
                if (classify(self.text[start..ends[k - 1]])) |word| {
                    self.pos = ends[k - 1];
                    return word;
                }
            }
            self.pos = ends[0];
            if (classify(self.text[start..self.pos])) |word| return word;
        }
    }
};

/// `path` as the walker returns it: native separators, so `\\` on Windows.
/// Returns the index of the `allowed_files` entry naming it, if any.
fn allowedIndex(path: []const u8) ?usize {
    for (allowed_files, 0..) |a, i| {
        if (a.len != path.len) continue;
        const same = for (a, path) |x, y| {
            const yy: u8 = if (y == '\\') '/' else y;
            if (x != yy) break false;
        } else true;
        if (same) return i;
    }
    return null;
}

/// Accumulates one tree walk: findings in non-allowlisted files, and which
/// allowlist entries were actually exercised (so stale ones can be named).
const Scan = struct {
    gpa: std.mem.Allocator,
    offenders: std.ArrayList([]const u8) = .empty,
    dirty: [allowed_files.len]bool = @splat(false),
    saw_root_file: bool = false,

    fn deinit(self: *Scan) void {
        for (self.offenders.items) |o| self.gpa.free(o);
        self.offenders.deinit(self.gpa);
    }

    /// Note one file: its path (relative to `src/`, scanned first, every
    /// segment) and then its contents, line by line.
    fn file(self: *Scan, path: []const u8, bytes: []const u8) !void {
        if (std.mem.eql(u8, path, root_file)) self.saw_root_file = true;
        const allowed = allowedIndex(path);
        var path_tokens: Tokenizer = .{ .text = path };
        while (path_tokens.next()) |word| {
            if (allowed) |i| {
                self.dirty[i] = true;
                return; // a platform in the name keeps the entry on its own
            }
            const msg = try std.fmt.allocPrint(self.gpa, "src/{s}: '{s}' in path {s}", .{ path, word, finding_note });
            try self.offenders.append(self.gpa, msg);
        }
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            var tokens: Tokenizer = .{ .text = line };
            while (tokens.next()) |word| {
                if (allowed) |i| {
                    self.dirty[i] = true;
                    return; // one hit keeps the entry; no need to read on
                }
                const msg = try std.fmt.allocPrint(self.gpa, "src/{s}:{d}: '{s}' {s}", .{ path, line_no, word, finding_note });
                try self.offenders.append(self.gpa, msg);
            }
        }
    }

    /// A symlink the guard cannot scan: always a finding, allowlist or not.
    fn linkFinding(self: *Scan, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const what = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(what);
        const msg = try std.fmt.allocPrint(self.gpa, "src/{s}: {s} {s}", .{ path, what, finding_note });
        try self.offenders.append(self.gpa, msg);
    }

    /// Allowlist entries no scanned file needed: they must be removed.
    fn stale(self: *const Scan, out: *std.ArrayList([]const u8)) !void {
        for (allowed_files, 0..) |a, i| if (!self.dirty[i]) try out.append(self.gpa, a);
    }
};

fn expectWords(text: []const u8, expected: []const []const u8) !void {
    var t: Tokenizer = .{ .text = text };
    for (expected) |e| try std.testing.expectEqualStrings(e, t.next() orelse return error.TestExpectedWord);
    try std.testing.expectEqual(@as(?[]const u8, null), t.next());
}

test "the tokenizer flags whole alphanumeric runs, case-insensitively" {
    try expectWords("std.Io ios_cmd biosphere Android cli/android/run.zig SDL2_image", &.{ "ios", "android", "android", "sdl2" });
    // Substrings inside a longer lowercase run never match: `wasm` is not a word here.
    try expectWords("wasmtime bgfxdebug", &.{});
}

test "the tokenizer splits CamelCase at case transitions and acronym boundaries" {
    try expectWords("IosConfig", &.{"ios"});
    try expectWords("AndroidProvider", &.{"android"});
    try expectWords("WasmConfig", &.{"wasm"});
    try expectWords("SDL2Provision", &.{"sdl2"});
    try expectWords("getSDLPath", &.{"sdl"});
    try expectWords("pub const IosConfig2 = struct {};", &.{"ios"});
    // Digits stay attached to the preceding piece; host OS names still pass.
    try expectWords("Win32Handle win32 x86_64", &.{});
    // No boundary inside a capitalised word or an all-lowercase run.
    try expectWords("std.Io Iostream biosphere wasmtime IoReader", &.{});
}

test "the tokenizer keeps lowercase-leading acronyms whole" {
    // Whole run first: the conventional spelling is one word.
    try expectWords("iOS", &.{"ios"});
    try expectWords("runs on iOS and Android", &.{ "ios", "android" });
    // `iOS|Config`, not `i|OS|Config`; plain camelCase still splits.
    try expectWords("iOSConfig", &.{"ios"});
    try expectWords("iosConfig", &.{"ios"});
    try expectWords("const iOSConfig = struct {};", &.{"ios"});
    // Embedded after a lowercase prefix: `get|iOS|Config`, `is|iOS|App`.
    try expectWords("getiOSConfig isiOSApp hasiOS", &.{ "ios", "ios", "ios" });
    try expectWords("getiOsConfig hasiOs", &.{ "ios", "ios" });
    // Only `iOS`/`iOs` split off an `i`: other acronyms after a word ending
    // in `i` keep their own piece.
    try expectWords("apiSDLConfig taxiWASM", &.{ "sdl", "wasm" });
    // An `i` ending an ordinary word before an acronym stays clean.
    try expectWords("apiURL multiIO", &.{});
    // A one-letter lowercase prefix before a single capital is ordinary camelCase.
    try expectWords("getSDLPath aSdl", &.{ "sdl", "sdl" });
    // Neither an all-lowercase run nor a capitalised `Io` is the platform.
    try expectWords("iostream std.Io IoReader Io", &.{});
    // Host OS names keep passing under the whole-run rule too.
    try expectWords("macOS macos MacOS", &.{});
}

test "web is forbidden alongside its toolchain names" {
    try expectWords("web", &.{"web"});
    try expectWords("labelle-web WebProvider WebGL web/index.html", &.{ "web", "web", "web", "web" });
    try expectWords("wasm emsdk WasmConfig", &.{ "wasm", "emsdk", "wasm" });
    // Substrings inside a longer lowercase run never match.
    try expectWords("webhook website cobweb", &.{});
}

test "a numeric suffix does not hide a forbidden root" {
    // Whole runs: the letter root before an all-digit suffix is classified.
    try expectWords("wasm32", &.{"wasm"});
    try expectWords("android14", &.{"android"});
    try expectWords("sdl3", &.{"sdl"});
    try expectWords("bgfx2 SOKOL3 Emsdk4", &.{ "bgfx", "sokol", "emsdk" });
    try expectWords("target = .wasm32; api >= android14; libSDL3", &.{ "wasm", "android", "sdl" });
    // The exact table entry wins over the root: `sdl2` is listed as such.
    try expectWords("sdl2 SDL2_image", &.{ "sdl2", "sdl2" });
    // CamelCase pieces get the same treatment.
    try expectWords("Wasm32Target", &.{"wasm"});
    try expectWords("Sdl3Provision getAndroid14Sdk", &.{ "sdl", "android" });
    // Exact allowed forms and roots that are not forbidden stay clean.
    try expectWords("win32 Win32Handle x86_64 utf8 base64 sha256 macos14", &.{});
    try std.testing.expectEqual(@as(?[]const u8, null), classify("win32"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("x86"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("64"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("utf8"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("base64"));
    try std.testing.expectEqual(@as(?[]const u8, null), classify("sha256"));
    // Digits in the middle are not a suffix: no root is taken from them.
    try expectWords("web2py sdl2image", &.{});
}

test "the Apple target platforms are forbidden; macOS is a host" {
    try expectWords("tvos watchos visionos maccatalyst", &.{ "tvos", "watchos", "visionos", "maccatalyst" });
    try expectWords("tvOS watchOS visionOS MacCatalyst", &.{ "tvos", "watchos", "visionos", "maccatalyst" });
    try expectWords("TvosTarget WatchosBuild VisionosSim", &.{ "tvos", "watchos", "visionos" });
    try expectWords("macOS macos MacOS macos14", &.{});
    // Prose and longer runs around the names do not match.
    try expectWords("television watchdog vision catalyst", &.{});
}

test "CamelCase pieces" {
    const Piece = struct {
        fn all(text: []const u8, out: *std.ArrayList([]const u8)) !void {
            var start: usize = 0;
            for (1..text.len) |i| if (splitsBefore(text, 0, i)) {
                try out.append(std.testing.allocator, text[start..i]);
                start = i;
            };
            try out.append(std.testing.allocator, text[start..]);
        }
    };
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try Piece.all("SDL2Provision", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{ "SDL2", "Provision" }, out.items);
    out.clearRetainingCapacity();
    try Piece.all("getSDLPath", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{ "get", "SDL", "Path" }, out.items);
    out.clearRetainingCapacity();
    try Piece.all("Iostream", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{"Iostream"}, out.items);
    out.clearRetainingCapacity();
    try Piece.all("iOSConfig", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{ "iOS", "Config" }, out.items);
    out.clearRetainingCapacity();
    try Piece.all("iosConfig", &out);
    try std.testing.expectEqualDeep(&[_][]const u8{ "ios", "Config" }, out.items);
}

test "host OS names never flag" {
    for (allowed_words) |w| {
        try std.testing.expectEqual(@as(?[]const u8, null), classify(w));
        var upper: [8]u8 = undefined;
        try std.testing.expectEqual(@as(?[]const u8, null), classify(std.ascii.upperString(upper[0..w.len], w)));
    }
    var t: Tokenizer = .{ .text = "builtin.os.tag == .macos or .windows or .linux; darwin; win32" };
    try std.testing.expectEqual(@as(?[]const u8, null), t.next());
}

test "the allowlist matches Windows-style walker paths, one file per entry" {
    try std.testing.expect(allowedIndex("storage/default.zig") != null);
    try std.testing.expect(allowedIndex("storage\\default.zig") != null);
    try std.testing.expect(allowedIndex("jsonc\\scene_loader\\nested_spawn.zig") != null);
    try std.testing.expect(allowedIndex("android.zig") != null);
    // A new file under a legacy directory is NOT exempt.
    try std.testing.expect(allowedIndex("storage/not_yet_written.zig") == null);
    try std.testing.expect(allowedIndex("storage/") == null);
    try std.testing.expect(allowedIndex("storagex/default.zig") == null);
    // Clean files were never listed, and a platform directory is not either.
    try std.testing.expect(allowedIndex("ecs.zig") == null);
    try std.testing.expect(allowedIndex("android/run.zig") == null);
    try std.testing.expect(allowedIndex("android\\run.zig") == null);
}

test "the walk reads Zig and vendored C, not JSON fixtures" {
    try std.testing.expect(isSource("root.zig"));
    try std.testing.expect(isSource("assets/stb_image_impl.c"));
    try std.testing.expect(isSource("assets/stb_image.h"));
    try std.testing.expect(!isSource("assets/provider_contract/projectless.json"));
    try std.testing.expect(!isSource("assets/notes.md"));
}

test "a finding is reported per line and a clean allowlisted file goes stale" {
    const gpa = std.testing.allocator;
    var scan: Scan = .{ .gpa = gpa };
    defer scan.deinit();
    // Non-allowlisted: every hit is a finding with the documented shape.
    try scan.file("backend_seam.zig", "// runs on Android\nconst x = 1;\nconst y = sokol_dep;\n");
    try std.testing.expectEqual(@as(usize, 2), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/backend_seam.zig:1: 'android' " ++ finding_note, scan.offenders.items[0]);
    try std.testing.expectEqualStrings("src/backend_seam.zig:3: 'sokol' " ++ finding_note, scan.offenders.items[1]);
    // The conventional `iOS` spelling and `web` count in a clean-looking file.
    try scan.file("backend_seam.zig", "const iOSConfig = struct {};\nconst w = labelle_web;\n");
    try std.testing.expectEqual(@as(usize, 4), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/backend_seam.zig:1: 'ios' " ++ finding_note, scan.offenders.items[2]);
    try std.testing.expectEqualStrings("src/backend_seam.zig:2: 'web' " ++ finding_note, scan.offenders.items[3]);
    // Allowlisted and dirty: no finding, entry kept. Clean name and body: stale.
    try scan.file("storage/default.zig", "// wasm\n");
    try scan.file("particles_tick.zig", "const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 4), scan.offenders.items.len);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    try scan.stale(&stale);
    try std.testing.expect(!containsString(stale.items, "storage/default.zig"));
    try std.testing.expect(containsString(stale.items, "particles_tick.zig"));
    // An entry the walk never reached (file removed) is stale too.
    try std.testing.expect(containsString(stale.items, "atlas.zig"));
    // The sentinel is only set by the engine root itself.
    try std.testing.expect(!scan.saw_root_file);
    try scan.file(root_file, "// android\n");
    try std.testing.expect(scan.saw_root_file);
}

test "a platform in the path is a finding, and keeps an allowlist entry dirty" {
    const gpa = std.testing.allocator;
    var scan: Scan = .{ .gpa = gpa };
    defer scan.deinit();
    // Clean contents, dirty name: the directory segment is the finding.
    try scan.file("assets/steam/upload.zig", "const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 1), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/assets/steam/upload.zig: 'steam' in path " ++ finding_note, scan.offenders.items[0]);
    // Every segment counts, on either separator, and `_`/`-`/`.` are boundaries.
    try scan.file("assets\\itch_upload.zig", "");
    try scan.file("assets/build-apk.zig", "");
    try scan.file("assets/xcode.h", "");
    try std.testing.expectEqual(@as(usize, 4), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/assets\\itch_upload.zig: 'itch' in path " ++ finding_note, scan.offenders.items[1]);
    try std.testing.expectEqualStrings("src/assets/build-apk.zig: 'apk' in path " ++ finding_note, scan.offenders.items[2]);
    try std.testing.expectEqualStrings("src/assets/xcode.h: 'xcode' in path " ++ finding_note, scan.offenders.items[3]);
    // Path hits come before content hits, once per segment hit.
    try scan.file("assets/android/gradle.zig", "// ndk\n");
    try std.testing.expectEqual(@as(usize, 7), scan.offenders.items.len);
    try std.testing.expectEqualStrings("src/assets/android/gradle.zig: 'android' in path " ++ finding_note, scan.offenders.items[4]);
    try std.testing.expectEqualStrings("src/assets/android/gradle.zig: 'gradle' in path " ++ finding_note, scan.offenders.items[5]);
    try std.testing.expectEqualStrings("src/assets/android/gradle.zig:1: 'ndk' " ++ finding_note, scan.offenders.items[6]);
    // Provider-neutral names produce nothing.
    try scan.file("assets/provider_settings.zig", "");
    try scan.file("assets/webhook_biosphere.zig", "");
    try std.testing.expectEqual(@as(usize, 7), scan.offenders.items.len);
    // An allowlisted file whose path names a platform stays dirty with
    // clean contents: the entry is only stale once the file is moved or
    // renamed.
    try scan.file("android.zig", "const x = 1;\n");
    try scan.file("storage\\web.zig", "");
    try std.testing.expectEqual(@as(usize, 7), scan.offenders.items.len);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    try scan.stale(&stale);
    try std.testing.expect(!containsString(stale.items, "android.zig"));
    try std.testing.expect(!containsString(stale.items, "storage/web.zig"));
    try std.testing.expect(containsString(stale.items, "atlas.zig"));
}

test "package and compound affixes do not hide a forbidden root" {
    // The explicit RFC forms resolve to their own table entry.
    try expectWords("Steamworks steamcmd xcodebuild", &.{ "steamworks", "steamcmd", "xcodebuild" });
    // `libsdl2-dev` tokenizes as `libsdl2` and `dev`; the `lib` prefix is stripped.
    try expectWords("apt install libsdl2-dev", &.{"sdl2"});
    try expectWords("libsdl LibSDL3 libwasm", &.{ "sdl", "sdl", "wasm" });
    try expectWords("itchworks androidsdk ioscmd webbuild wasmdev libwebdev", &.{ "itch", "android", "ios", "web", "wasm", "web" });
    // The mechanism: none of these is a table entry, nor a numeric-suffix
    // root, so only the affix rule can reach them.
    for ([_][]const u8{ "libsdl2", "itchworks", "androidsdk", "ioscmd", "libwasmdev" }) |w| {
        try std.testing.expectEqual(@as(?[]const u8, null), classifyRoot(w));
        try std.testing.expect(classify(w) != null);
    }
    // Ordinary words that share an affix stay clean in both directions.
    try expectWords("library worksheet devices buildkit rebuild prebuild frameworks subcmd libc libwebp", &.{});
    try expectWords("Library Worksheet Devices BuildKit LibraryPath", &.{});
    // The affix and host OS rules compose: an allowed root stays allowed.
    try expectWords("libwin32 linuxdev macossdk", &.{});
}

test "the RFC's provider tools and SDKs are forbidden" {
    try expectWords("butler push uikit adb shell emcc gradlew", &.{ "butler", "uikit", "adb", "emcc", "gradlew" });
    try expectWords("UIKit uikit_view ButlerPush AdbDevice", &.{ "uikit", "uikit", "butler", "adb" });
    // Longer runs around the names do not match.
    try expectWords("butlers uikitten adbc emccx gradlewrapper", &.{});
}

/// Splits `text` (one `[A-Za-z0-9]+` run) into CamelCase pieces the way the
/// tokenizer does, each piece's boundary judged from its own start.
fn camelPieces(text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    while (start < text.len) {
        var end = start + 1;
        while (end < text.len and !splitsBefore(text, start, end)) end += 1;
        try out.append(std.testing.allocator, text[start..end]);
        start = end;
    }
}

test "a name that spans CamelCase pieces flags (UIKitView), benign joins do not" {
    // The gap #425 documented: `UIKit` splits as `UI|Kit`, so neither piece
    // alone is the name.
    try expectWords("UIKitView UIKitGlue UIKit2Glue", &.{ "uikit", "uikit", "uikit" });
    try expectWords("getUIKitView let v: UIKitView = x;", &.{ "uikit", "uikit" });
    try expectWords("XCodeProject LibSDLDev", &.{ "xcode", "sdl" });
    // A matched join consumes its pieces; a later piece still flags.
    try expectWords("UIKitSteamBridge", &.{ "uikit", "steam" });
    // The mechanism: whole-run classification misses, and so does every
    // single piece; only a join of adjacent pieces reaches the name.
    const gpa = std.testing.allocator;
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(gpa);
    const spanning = [_]struct { run: []const u8, join: []const u8 }{
        .{ .run = "UIKitView", .join = "UIKit" },
        .{ .run = "UIKitGlue", .join = "UIKit" },
        .{ .run = "UIKit2Glue", .join = "UIKit2" },
        .{ .run = "XCodeProject", .join = "XCode" },
    };
    for (spanning) |c| {
        try std.testing.expectEqual(@as(?[]const u8, null), classify(c.run));
        pieces.clearRetainingCapacity();
        try camelPieces(c.run, &pieces);
        try std.testing.expect(pieces.items.len >= 3);
        for (pieces.items) |piece| try std.testing.expectEqual(@as(?[]const u8, null), classify(piece));
        try std.testing.expect(std.mem.startsWith(u8, c.run, c.join));
        try std.testing.expect(classify(c.join) != null);
    }
    // Benign controls: realistic identifiers whose joins are not a whole name.
    // `UIntKind` is `U|Int|Kind` (`uint`, `uintkind`), `GuiKit` is
    // `guikit`, `UiKitchen` is `uikitchen`, `UIKeyboard` is `UI|Keyboard`.
    try expectWords("UIntKind GuiKit UiKitchen UIKeyboard UIKitten UIKithelper Toolkit", &.{});
    try expectWords("IOStream IOSurface IoSlice AdBlock WebGLContext", &.{"web"});
    // Joins stay inside one run: `UI` and `Kit` across a separator never join.
    try expectWords("UI_Kit UI.Kit UI Kit", &.{});
}

test "source symlinks are path-checked and followed inside the repository" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // symlinks need privileges there
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/src/assets");
    try tmp.dir.createDirPath(io, "repo/shared/dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/src/root.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/shared/dirty.zig", .data = "const x = 1;\nconst y = sokol;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/shared/clean.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.zig", .data = "const x = 1;\n" });
    // Contents behind a clean link name are scanned under the link's path.
    try tmp.dir.symLink(io, "../shared/dirty.zig", "repo/src/linked.zig", .{});
    // A forbidden link name is a path finding even when the target is clean.
    try tmp.dir.symLink(io, "../../shared/clean.zig", "repo/src/assets/steam.zig", .{});
    // Escaping the repository, dangling, or linking a directory: findings.
    try tmp.dir.symLink(io, "../../outside.zig", "repo/src/escape.zig", .{});
    try tmp.dir.symLink(io, "missing.zig", "repo/src/dangling.zig", .{});
    try tmp.dir.symLink(io, "../shared/dir", "repo/src/linked_dir", .{ .is_directory = true });
    // A link that is not source-shaped is ignored, like a plain `.md` file.
    try tmp.dir.symLink(io, "../../outside.zig", "repo/src/notes.md", .{});

    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    var scan: Scan = .{ .gpa = gpa };
    defer scan.deinit();
    try scanTree(io, gpa, repo, &scan);
    try std.testing.expect(scan.saw_root_file);

    const expected = [_][]const u8{
        "src/linked.zig:2: 'sokol' ",
        "src/assets/steam.zig: 'steam' in path ",
        "src/escape.zig: is a symlink to ",
        "src/dangling.zig: is a symlink that does not resolve",
        "src/linked_dir: is a symlink to a directory",
    };
    try std.testing.expectEqual(expected.len, scan.offenders.items.len);
    for (expected) |e| {
        const hit = for (scan.offenders.items) |o| {
            if (std.mem.startsWith(u8, o, e)) break true;
        } else false;
        if (!hit) {
            for (scan.offenders.items) |o| std.debug.print("got: {s}\n", .{o});
            std.debug.print("missing: {s}\n", .{e});
            return error.TestExpectedFinding;
        }
    }
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// Walks `repo/src` into `scan`. Regular source files are scanned as they
/// are. A symlink is never skipped silently: a source-shaped link
/// (`src/assets/steam.zig -> ../shared/upload.zig`) is path-checked under its
/// own name and its target's contents are scanned, provided the target
/// resolves to a file inside `repo`; a link that dangles, leaves the
/// repository or points at something other than a file is a finding. A
/// link to a directory is a finding whatever its name, since the walk does
/// not descend into it and the files behind it would go unscanned. Other
/// links (a `notes.md` link) are ignored like the files they stand for.
fn scanTree(io: std.Io, gpa: std.mem.Allocator, repo: std.Io.Dir, scan: *Scan) !void {
    var src = try repo.openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_real = repo_buf[0..try repo.realPathFile(io, ".", &repo_buf)];
    var walker = try src.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => if (isSource(entry.path)) {
                const bytes = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 << 20));
                defer gpa.free(bytes);
                try scan.file(entry.path, bytes);
            },
            .sym_link => try scanLink(io, gpa, repo_real, entry.dir, entry.basename, entry.path, scan),
            else => {},
        }
    }
}

fn scanLink(io: std.Io, gpa: std.mem.Allocator, repo_real: []const u8, dir: std.Io.Dir, basename: []const u8, path: []const u8, scan: *Scan) !void {
    const st = dir.statFile(io, basename, .{}) catch |err| {
        if (!isSource(path)) return;
        return scan.linkFinding(path, "is a symlink that does not resolve ({t})", .{err});
    };
    if (st.kind == .directory)
        return scan.linkFinding(path, "is a symlink to a directory the guard does not walk; commit the files instead", .{});
    if (!isSource(path)) return;
    if (st.kind != .file)
        return scan.linkFinding(path, "is a symlink to something other than a regular file", .{});
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = target_buf[0..try dir.realPathFile(io, basename, &target_buf)];
    const inside = target.len > repo_real.len and std.mem.startsWith(u8, target, repo_real) and
        std.fs.path.isSep(target[repo_real.len]);
    if (!inside)
        return scan.linkFinding(path, "is a symlink to {s}, outside the repository; the guard cannot scan it", .{target});
    const bytes = try dir.readFileAlloc(io, basename, gpa, .limited(4 << 20));
    defer gpa.free(bytes);
    try scan.file(path, bytes);
}

test "no core file names a platform, store, package or backend" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var scan: Scan = .{ .gpa = gpa };
    defer scan.deinit();
    try scanTree(io, gpa, std.Io.Dir.cwd(), &scan);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    try scan.stale(&stale);

    for (scan.offenders.items) |o| std.debug.print("{s}\n", .{o});
    for (stale.items) |s| std.debug.print("src/{s} is on the migration allowlist but is clean; remove it\n", .{s});
    if (!scan.saw_root_file) {
        std.debug.print("agnostic guard: the walk never reached src/{s}; run from the repository root (build.zig sets the cwd)\n", .{root_file});
        return error.RootFileNotScanned;
    }
    try std.testing.expectEqual(@as(usize, 0), scan.offenders.items.len);
    try std.testing.expectEqual(@as(usize, 0), stale.items.len);
}
