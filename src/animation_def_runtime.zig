/// RuntimeAnimationDef — heap-allocated mirror of `AnimationDef` (#672).
///
/// The comptime `AnimationDef` (src/animation_def.zig) bakes every clip
/// enum, `ClipMeta`, and sprite-name string into the binary — changing a
/// frame count or speed needs a full recompile. This module parses the
/// same `.zon` schema at RUNTIME into heap tables so a preview/editor
/// build can reload clip data live. Release builds keep the comptime
/// path (zero cost); this is only reached behind the preview build flag.
///
/// **Index-compatibility invariant (critical).** Clip and variant indices
/// are assigned in the SAME order as the comptime path — clip = struct-
/// field declaration order, variant = list order — so a `u8` held in a
/// live `AnimationState.clip`/`.variant` means the same thing before and
/// after switching between the comptime and runtime sources. The
/// `animation_def_runtime_test.zig` byte-equal parity test locks this in.
///
/// Parsing uses `std.zig.Zoir` (the ZON object IR that `std.zon.parse`
/// itself lowers through). `std.zon.parse` is type-directed and can't take
/// a `.clips` struct with arbitrary field names, so we walk the dynamic
/// Zoir node tree directly.
///
/// I/O is injected, not owned. This module does the parse, the
/// generation bookkeeping (`ReloadWatcher`), and the live-entity refresh
/// (`refreshState`) — all pure and unit-testable. The actual file read +
/// mtime stat + per-frame poll cadence live in the host game loop, which
/// owns the `std.Io` instance and the ECS iteration (see `ReloadWatcher`
/// doc for the host loop shape). This keeps the engine module free of the
/// 0.16 `std.Io` plumbing and its tests free of the filesystem.

const std = @import("std");
const animation_def = @import("animation_def.zig");

pub const Mode = animation_def.Mode;
pub const ClipMeta = animation_def.ClipMeta;
pub const FrameEntry = animation_def.FrameEntry;

const Zoir = std.zig.Zoir;

pub const RuntimeAnimationDef = struct {
    allocator: std.mem.Allocator,
    /// Clip names in declaration order; index == the `u8` in AnimationState.clip.
    clip_names: [][]const u8,
    /// Variant names in list order; index == the `u8` in AnimationState.variant.
    variant_names: [][]const u8,
    /// Per-clip metadata (same `ClipMeta` as the comptime path). `folder`
    /// is heap-owned here (freed in `deinit`).
    clip_meta: []ClipMeta,
    /// Per-clip normalized slot lists (#664 × #672): the same `FrameEntry`
    /// rows the comptime `normalizeFrames` produces — count form expands
    /// to slots 1..N with run 1. Heap-owned (marker strings included).
    clip_entries: [][]FrameEntry,
    /// Precomputed sprite-name strings, `[clip][variant][slot]`. Jagged:
    /// row length is that clip's `frame_count`. Byte-equal to the comptime
    /// table's `"{folder}/{variant}_{f:04}.png"` (slot i names file
    /// `entries[i].f`, so reorders/reuse resolve identically).
    sprite_names: [][][][]const u8,

    /// Parse a `.zon` animation definition. On any malformed input (parse
    /// error, missing `.variants`/`.clips`, bad field type, frame count
    /// out of 1..255) returns an error and frees everything — the caller's
    /// existing def is left untouched, so a half-saved file never corrupts
    /// a running preview.
    pub fn load(allocator: std.mem.Allocator, zon_source: []const u8) !RuntimeAnimationDef {
        const src_z = try allocator.dupeZ(u8, zon_source);
        defer allocator.free(src_z);

        var ast = try std.zig.Ast.parse(allocator, src_z, .zon);
        defer ast.deinit(allocator);
        if (ast.errors.len != 0) return error.ParseFailed;

        var zoir = try std.zig.ZonGen.generate(allocator, ast, .{});
        defer zoir.deinit(allocator);
        if (zoir.hasCompileErrors()) return error.ParseFailed;

        const root = Zoir.Node.Index.root;
        const variants_node = findField(zoir, root, "variants") orelse return error.MissingVariants;
        const clips_node = findField(zoir, root, "clips") orelse return error.MissingClips;

        // ── variants ──────────────────────────────────────────
        const vrange = switch (variants_node.get(zoir)) {
            .array_literal => |r| r,
            else => return error.BadVariants,
        };
        const vcount = vrange.len;
        if (vcount == 0) return error.EmptyVariants;
        if (vcount > 255) return error.TooManyVariants;

        const variant_names = try allocator.alloc([]const u8, vcount);
        var vfilled: usize = 0;
        errdefer {
            for (variant_names[0..vfilled]) |s| allocator.free(s);
            allocator.free(variant_names);
        }
        {
            var i: u32 = 0;
            while (i < vcount) : (i += 1) {
                const s = try getString(zoir, vrange.at(i));
                variant_names[i] = try allocator.dupe(u8, s);
                vfilled += 1;
            }
        }

        // ── clips (names + meta) ──────────────────────────────
        const cstruct = switch (clips_node.get(zoir)) {
            .struct_literal => |s| s,
            else => return error.BadClips,
        };
        // Guard BEFORE the u32 cast (a pathological >4G-entry file must
        // error, not trap); u32 itself is required by Zoir's Range.at.
        if (cstruct.names.len == 0) return error.EmptyClips;
        if (cstruct.names.len > 255) return error.TooManyClips;
        const ccount: u32 = @intCast(cstruct.names.len);

        const clip_names = try allocator.alloc([]const u8, ccount);
        var cn_filled: usize = 0;
        errdefer {
            for (clip_names[0..cn_filled]) |s| allocator.free(s);
            allocator.free(clip_names);
        }

        const clip_meta = try allocator.alloc(ClipMeta, ccount);
        var cm_filled: usize = 0;
        errdefer {
            for (clip_meta[0..cm_filled]) |m| allocator.free(m.folder);
            allocator.free(clip_meta);
        }

        const clip_entries = try allocator.alloc([]FrameEntry, ccount);
        var ce_filled: usize = 0;
        errdefer {
            for (clip_entries[0..ce_filled]) |es| freeEntries(allocator, es);
            allocator.free(clip_entries);
        }

        {
            var i: u32 = 0;
            while (i < ccount) : (i += 1) {
                const cname = cstruct.names[i].get(zoir);
                clip_names[i] = try allocator.dupe(u8, cname);
                cn_filled += 1;

                const cnode = cstruct.vals.at(i);
                // frames — required. A bare int N (fast path) expands to
                // slots 1..N with run 1; an entry list parses each element
                // (#664 × #672). Stored before any further `try` so the
                // errdefer above owns it on failure.
                const frames_node = findField(zoir, cnode, "frames") orelse return error.MissingFrames;
                clip_entries[i] = try parseFrames(allocator, zoir, frames_node);
                ce_filled += 1;
                const entries = clip_entries[i];
                var beats: u16 = 0;
                for (entries) |e| beats += e.run;
                // Defaults replicate animation_def.zig exactly: folder = clip
                // name, speed = 1.0, mode = .static.
                const mode: Mode = if (findField(zoir, cnode, "mode")) |mn|
                    try modeFromName(try getEnumName(zoir, mn))
                else
                    .static;
                const speed: f32 = if (findField(zoir, cnode, "speed")) |sn|
                    try getFloat(zoir, sn)
                else
                    1.0;
                // Comptime parity: a .static clip only ever shows slot 0,
                // so per-slot holds are meaningless — reject them.
                if (mode == .static) {
                    for (entries) |e| {
                        if (e.run != 1) return error.HoldOnStaticClip;
                    }
                }
                const folder_src: []const u8 = if (findField(zoir, cnode, "folder")) |fnode|
                    try getString(zoir, fnode)
                else
                    cname;
                const folder_dup = try allocator.dupe(u8, folder_src);
                clip_meta[i] = .{
                    .frame_count = @intCast(entries.len),
                    .entry_count = @intCast(entries.len),
                    .beat_count = beats,
                    .speed = speed,
                    .mode = mode,
                    .folder = folder_dup,
                };
                cm_filled += 1;
            }
        }

        // ── sprite-name table [clip][variant][slot] ───────────
        const sprite_names = try allocator.alloc([][][]const u8, ccount);
        var sn_clips: usize = 0;
        errdefer {
            for (sprite_names[0..sn_clips]) |blk| {
                for (blk) |row| {
                    for (row) |nm| allocator.free(nm);
                    allocator.free(row);
                }
                allocator.free(blk);
            }
            allocator.free(sprite_names);
        }
        {
            var ci: usize = 0;
            while (ci < ccount) : (ci += 1) {
                const fc = clip_meta[ci].frame_count;
                const folder = clip_meta[ci].folder;
                const block = try allocator.alloc([][]const u8, vcount);
                var blk_rows: usize = 0;
                errdefer {
                    for (block[0..blk_rows]) |row| {
                        for (row) |nm| allocator.free(nm);
                        allocator.free(row);
                    }
                    allocator.free(block);
                }
                var vi: usize = 0;
                while (vi < vcount) : (vi += 1) {
                    const row = try allocator.alloc([]const u8, fc);
                    var row_f: usize = 0;
                    errdefer {
                        for (row[0..row_f]) |nm| allocator.free(nm);
                        allocator.free(row);
                    }
                    var fi: usize = 0;
                    while (fi < fc) : (fi += 1) {
                        // Slot fi names file `entries[fi].f` (not fi+1),
                        // matching the comptime table for reorders/reuse.
                        row[fi] = try std.fmt.allocPrint(allocator, "{s}/{s}_{d:0>4}.png", .{ folder, variant_names[vi], clip_entries[ci][fi].f });
                        row_f += 1;
                    }
                    block[vi] = row;
                    blk_rows += 1;
                }
                sprite_names[ci] = block;
                sn_clips += 1;
            }
        }

        return RuntimeAnimationDef{
            .allocator = allocator,
            .clip_names = clip_names,
            .variant_names = variant_names,
            .clip_meta = clip_meta,
            .clip_entries = clip_entries,
            .sprite_names = sprite_names,
        };
    }

    pub fn deinit(self: *RuntimeAnimationDef) void {
        const a = self.allocator;
        for (self.sprite_names) |blk| {
            for (blk) |row| {
                for (row) |nm| a.free(nm);
                a.free(row);
            }
            a.free(blk);
        }
        a.free(self.sprite_names);
        for (self.clip_entries) |es| freeEntries(a, es);
        a.free(self.clip_entries);
        for (self.clip_meta) |m| a.free(m.folder);
        a.free(self.clip_meta);
        for (self.clip_names) |n| a.free(n);
        a.free(self.clip_names);
        for (self.variant_names) |n| a.free(n);
        a.free(self.variant_names);
        self.* = undefined;
    }

    /// Resolve a clip name to its index, or null if absent.
    pub fn clipIndex(self: *const RuntimeAnimationDef, name: []const u8) ?u8 {
        for (self.clip_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        return null;
    }

    /// Resolve a variant name to its index, or null if absent.
    pub fn variantIndex(self: *const RuntimeAnimationDef, name: []const u8) ?u8 {
        for (self.variant_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        return null;
    }

    /// Metadata for a clip index, clamped to the last clip if out of range
    /// (a reload may have shrunk the clip count under a live index).
    pub fn clipMeta(self: *const RuntimeAnimationDef, clip: u8) ClipMeta {
        if (self.clip_meta.len == 0) return .{ .frame_count = 1, .entry_count = 1, .beat_count = 1, .speed = 1.0, .mode = .static, .folder = "" };
        const idx = if (clip >= self.clip_meta.len) self.clip_meta.len - 1 else clip;
        return self.clip_meta[idx];
    }

    /// Look up a precomputed sprite name; returns "" for any out-of-range
    /// clip/variant/frame (never indexes OOB).
    pub fn spriteName(self: *const RuntimeAnimationDef, clip: u8, variant: u8, frame: u8) []const u8 {
        if (clip >= self.clip_meta.len) return "";
        if (frame >= self.clip_meta[clip].frame_count) return "";
        if (variant >= self.variant_names.len) return "";
        return self.sprite_names[clip][variant][frame];
    }

    /// The slot shown at a given beat of a clip — the runtime mirror of
    /// the comptime `slotForBeat`, computed on the fly by walking the
    /// entry runs (no baked beat table; the runtime path is preview-only,
    /// so O(entries) per lookup is inside budget). Returns 0 for any
    /// out-of-range clip; wraps `beat` past the clip's beat_count.
    pub fn slotForBeat(self: *const RuntimeAnimationDef, clip: u8, beat: u16) u8 {
        if (clip >= self.clip_entries.len) return 0;
        const bc = self.clip_meta[clip].beat_count;
        if (bc == 0) return 0;
        var b = beat % bc;
        for (self.clip_entries[clip], 0..) |e, si| {
            if (b < e.run) return @intCast(si);
            b -= e.run;
        }
        return 0;
    }
};

/// Free one clip's owned entry list, marker strings included.
fn freeEntries(allocator: std.mem.Allocator, entries: []FrameEntry) void {
    for (entries) |e| {
        if (e.marker) |mk| allocator.free(mk);
    }
    allocator.free(entries);
}

// ── ZON node helpers (walk the dynamic Zoir tree) ─────────────

/// Parse a clip's `frames` node into an owned entry list. Mirrors the
/// comptime `normalizeFrames` (#664) forms and validation:
///   .frames = 4                               // count: slots 1..4, run 1
///   .frames = .{ 1, 2, 3, 2 }                 // explicit indices, run 1
///   .frames = .{ .{ .f = 1, .run = 2 }, 2 }   // per-slot holds/markers
/// The returned slice and any `marker` strings are owned by the caller
/// (free via `freeEntries`); on error nothing is leaked.
fn parseFrames(allocator: std.mem.Allocator, zoir: Zoir, node: Zoir.Node.Index) ![]FrameEntry {
    switch (node.get(zoir)) {
        // Count fast-path — a bare int N.
        .int_literal => {
            const n = try getSmallInt(zoir, node);
            if (n < 1 or n > 255) return error.FramesOutOfRange;
            const entries = try allocator.alloc(FrameEntry, @intCast(n));
            for (entries, 0..) |*e, i| e.* = .{ .f = @intCast(i + 1), .run = 1 };
            return entries;
        },
        // Entry list — ints and/or `.{ .f, .run, .marker }` structs.
        .array_literal => |range| {
            if (range.len == 0) return error.EmptyFrames; // defensive; `.{}` is empty_literal
            if (range.len > 255) return error.FramesOutOfRange;
            const entries = try allocator.alloc(FrameEntry, range.len);
            var filled: usize = 0;
            errdefer {
                // Free the FULL allocation; only `filled` markers exist yet.
                for (entries[0..filled]) |e| {
                    if (e.marker) |mk| allocator.free(mk);
                }
                allocator.free(entries);
            }
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                entries[filled] = try parseFrameEntry(allocator, zoir, range.at(i));
                filled += 1;
            }
            return entries;
        },
        // `.{}` lowers to empty_literal, not a zero-length array.
        .empty_literal => return error.EmptyFrames,
        else => return error.ExpectedInt,
    }
}

/// One element of an entry-list `frames`: a bare int index (run 1) or a
/// struct literal with `f` (required), `run` (default 1), and an
/// optional `marker` string (duped onto the heap).
fn parseFrameEntry(allocator: std.mem.Allocator, zoir: Zoir, node: Zoir.Node.Index) !FrameEntry {
    switch (node.get(zoir)) {
        .int_literal => {
            const f = try getSmallInt(zoir, node);
            if (f < 1 or f > 9999) return error.FrameIndexOutOfRange;
            return .{ .f = @intCast(f), .run = 1 };
        },
        .struct_literal => {
            const f_node = findField(zoir, node, "f") orelse return error.MissingFrameIndex;
            const f = try getSmallInt(zoir, f_node);
            if (f < 1 or f > 9999) return error.FrameIndexOutOfRange;
            var run: i32 = 1;
            if (findField(zoir, node, "run")) |rn| run = try getSmallInt(zoir, rn);
            if (run < 1 or run > 255) return error.RunOutOfRange;
            var marker: ?[]const u8 = null;
            if (findField(zoir, node, "marker")) |mn| {
                marker = try allocator.dupe(u8, try getString(zoir, mn));
            }
            return .{ .f = @intCast(f), .run = @intCast(run), .marker = marker };
        },
        else => return error.BadFrameEntry,
    }
}

fn findField(zoir: Zoir, node: Zoir.Node.Index, name: []const u8) ?Zoir.Node.Index {
    switch (node.get(zoir)) {
        .struct_literal => |s| {
            var i: u32 = 0;
            while (i < s.names.len) : (i += 1) {
                if (std.mem.eql(u8, s.names[i].get(zoir), name)) return s.vals.at(i);
            }
            return null;
        },
        else => return null,
    }
}

fn getString(zoir: Zoir, node: Zoir.Node.Index) ![]const u8 {
    return switch (node.get(zoir)) {
        .string_literal => |s| s,
        else => error.ExpectedString,
    };
}

fn getSmallInt(zoir: Zoir, node: Zoir.Node.Index) !i32 {
    return switch (node.get(zoir)) {
        .int_literal => |il| switch (il) {
            .small => |v| v,
            .big => error.IntTooBig,
        },
        else => error.ExpectedInt,
    };
}

fn getFloat(zoir: Zoir, node: Zoir.Node.Index) !f32 {
    return switch (node.get(zoir)) {
        .float_literal => |f| @floatCast(f),
        // A bare `.speed = 4` (int) is accepted as 4.0.
        .int_literal => |il| switch (il) {
            .small => |v| @floatFromInt(v),
            .big => error.IntTooBig,
        },
        else => error.ExpectedNumber,
    };
}

fn getEnumName(zoir: Zoir, node: Zoir.Node.Index) ![]const u8 {
    return switch (node.get(zoir)) {
        .enum_literal => |nts| nts.get(zoir),
        else => error.ExpectedEnum,
    };
}

fn modeFromName(name: []const u8) !Mode {
    if (std.mem.eql(u8, name, "time")) return .time;
    if (std.mem.eql(u8, name, "distance")) return .distance;
    if (std.mem.eql(u8, name, "static")) return .static;
    return error.UnknownMode;
}

// ── Registry seam (comptime table vs runtime def) ─────────────

/// The sprite-resolution indirection the driver reads. Release builds
/// register `.comptime_table` (wrapping `Def.spriteName`, status quo, one
/// branch). Preview builds register `.runtime` pointing at a loaded
/// `RuntimeAnimationDef`. Both answer the same `(clip, variant, frame) →
/// name` query.
pub const AnimDefSource = union(enum) {
    comptime_table: *const fn (clip: u8, variant: u8, frame: u8) []const u8,
    runtime: *RuntimeAnimationDef,

    pub fn spriteName(self: AnimDefSource, clip: u8, variant: u8, frame: u8) []const u8 {
        return switch (self) {
            .comptime_table => |f| f(clip, variant, frame),
            .runtime => |r| r.spriteName(clip, variant, frame),
        };
    }
};

// ── Live-entity refresh + generation bookkeeping ──────────────

/// Refresh one live `AnimationState` against a reloaded def: re-copy the
/// current clip's `frame_count`/`speed`/`mode` (live entities hold stale
/// copies since `transition` snapshots them), clamp `clip`/`variant`/
/// `frame` if the reload shrank the tables, and mark `dirty` so the sprite
/// re-resolves. `state` is duck-typed (reads/writes `.clip/.variant/
/// .frame/.frame_count/.speed/.mode/.dirty`) to dodge the
/// animation_state ↔ animation_def import cycle.
///
/// `.clip`/`.variant` may be plain `u8` (the engine `AnimationState`) OR
/// enums (game-typed wrappers like FP's, whose `Clip`/`Variant` come from
/// the comptime `AnimationDef`). Enum writes only ever happen on a
/// SHRINKING clamp — the new value `count - 1` is strictly below the old
/// (in-range) value, so `@enumFromInt` can never manufacture a tag the
/// enum doesn't have, even when the runtime def has MORE entries than the
/// comptime enum (a grown def leaves the fields untouched).
pub fn refreshState(state: anytype, def: *const RuntimeAnimationDef) void {
    const clip_count = def.clip_meta.len;
    if (clip_count == 0) return;
    if (rawIndex(state.clip) >= clip_count) {
        setIndex(&state.clip, @intCast(clip_count - 1));
    }
    if (def.variant_names.len > 0 and rawIndex(state.variant) >= def.variant_names.len) {
        setIndex(&state.variant, @intCast(def.variant_names.len - 1));
    }
    const meta = def.clip_meta[rawIndex(state.clip)];
    state.frame_count = meta.frame_count;
    state.speed = meta.speed;
    state.mode = meta.mode;
    if (meta.frame_count > 0 and state.frame >= meta.frame_count) {
        state.frame = meta.frame_count - 1;
    }
    state.dirty = true;
}

/// Read a clip/variant index field as its raw `u8` regardless of whether
/// the game types it as an int or an enum.
fn rawIndex(v: anytype) u8 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int => @intCast(v),
        .@"enum" => @intCast(@intFromEnum(v)),
        else => @compileError("animation clip/variant fields must be u8 or enum, got " ++
            @typeName(@TypeOf(v))),
    };
}

/// Write a clamped index back into an int- or enum-typed field. Callers
/// guarantee `idx` is below the field's current (valid) value — see
/// `refreshState`'s shrink-only invariant.
fn setIndex(ptr: anytype, idx: u8) void {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    ptr.* = switch (@typeInfo(T)) {
        .int => idx,
        .@"enum" => @enumFromInt(idx),
        else => unreachable, // rawIndex already rejected other types
    };
}

/// Owns the live def plus at most one prior generation, and tracks the
/// last-seen mtime. Filesystem-agnostic: the host supplies the mtime and
/// the parsed def, so this stays testable without `std.Io`.
///
/// Host loop (preview builds only; `comptime if` gates it out of release):
///
///   // once per second, throttled by frame count:
///   const mtime = statMtimeNs(io, path);
///   if (watcher.mtimeChanged(mtime)) {
///       const src = readFile(io, path);           // host owns Io
///       if (RuntimeAnimationDef.load(alloc, src)) |new_def| {
///           watcher.swapIn(new_def);              // retire old gen (deferred)
///           for (entitiesWith(AnimationState)) |*st| refreshState(st, watcher.def());
///       } else |err| logOnce("anim reload failed: {}", .{err});  // keep old def
///   }
///   // ...render...
///   watcher.releasePrevious();  // end-of-frame, after sprites re-resolved
pub const ReloadWatcher = struct {
    current: RuntimeAnimationDef,
    previous: ?RuntimeAnimationDef = null,
    last_mtime_ns: i128 = 0,
    mtime_seen: bool = false,

    /// `initial_mtime_ns` is the mtime of the file `initial` was parsed
    /// from — the first poll with an unchanged file then returns false
    /// instead of triggering a redundant startup reload.
    pub fn init(initial: RuntimeAnimationDef, initial_mtime_ns: i128) ReloadWatcher {
        return .{ .current = initial, .last_mtime_ns = initial_mtime_ns, .mtime_seen = true };
    }

    /// The def sprites should resolve against right now.
    pub fn def(self: *const ReloadWatcher) *const RuntimeAnimationDef {
        return &self.current;
    }

    /// True (and records the new value) when `mtime_ns` differs from the
    /// last seen — the host's cue to read + parse. Coalesces rapid saves
    /// naturally (a second change before the first is polled is one event).
    pub fn mtimeChanged(self: *ReloadWatcher, mtime_ns: i128) bool {
        if (self.mtime_seen and mtime_ns == self.last_mtime_ns) return false;
        self.last_mtime_ns = mtime_ns;
        self.mtime_seen = true;
        return true;
    }

    /// Install a freshly-parsed def. The outgoing generation is retained
    /// as `previous` because its sprite-name slices may still be held by
    /// `Sprite` components until the next re-resolve; any generation
    /// already pending free is released first, so at most one is held.
    pub fn swapIn(self: *ReloadWatcher, new_def: RuntimeAnimationDef) void {
        if (self.previous) |*p| p.deinit();
        self.previous = self.current;
        self.current = new_def;
    }

    /// Free the retained previous generation. Call at end-of-frame, after
    /// sprites have re-resolved against `current`.
    pub fn releasePrevious(self: *ReloadWatcher) void {
        if (self.previous) |*p| {
            p.deinit();
            self.previous = null;
        }
    }

    pub fn deinit(self: *ReloadWatcher) void {
        if (self.previous) |*p| p.deinit();
        self.current.deinit();
        self.* = undefined;
    }
};

// ── Named runtime-def store (editor hot-reload) ───────────────

/// Runtime animation-def store for a running game — the map behind
/// `Game.loadAnimationDefSource` / `editor_api.editor_load_animation_def`.
/// Keys are def NAMES (the `.zon` stem, `"worker"` for
/// `animations/worker.zon`); values are the latest parsed generation.
///
/// **Replaced generations are RETIRED, not freed.** A def's sprite-name
/// slices may be held by live `Sprite.sprite_name` fields, and game code
/// may hold `get()` borrows across frames; unlike `ReloadWatcher`'s
/// host-loop protocol there is no "everyone re-resolved by end-of-frame"
/// guarantee here — the editor can push while the sim is PAUSED
/// (`editor_pause`), when no tick will re-resolve anything for an
/// arbitrary number of rendered frames. Retired generations go to a
/// graveyard freed only in `deinit`: each is a few KB of name strings and
/// the count is bounded by editor saves per session, which buys zero
/// use-after-free risk for a negligible ceiling. Release builds never
/// construct one of these (the surface is only reached via `editor_api`
/// / explicit host calls), so shipped games pay nothing.
pub const RuntimeAnimDefs = struct {
    allocator: std.mem.Allocator,
    /// name → live generation. Keys are owned dupes; values are
    /// heap-boxed so `get()` borrows stay pointer-stable across `put`s
    /// of OTHER names (StringHashMap moves values on rehash).
    map: std.StringHashMap(*RuntimeAnimationDef),
    /// Retired generations, kept alive until `deinit` (see above).
    graveyard: std.ArrayList(*RuntimeAnimationDef) = .empty,

    pub fn init(allocator: std.mem.Allocator) RuntimeAnimDefs {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(*RuntimeAnimationDef).init(allocator),
        };
    }

    pub fn deinit(self: *RuntimeAnimDefs) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.map.deinit();
        for (self.graveyard.items) |old| {
            old.deinit();
            self.allocator.destroy(old);
        }
        self.graveyard.deinit(self.allocator);
        self.* = undefined;
    }

    /// Install `def` as the live generation for `name`, retiring any
    /// previous one to the graveyard. Takes ownership of `def` on
    /// success; on error (OOM) ownership stays with the caller and the
    /// store is unchanged.
    pub fn put(self: *RuntimeAnimDefs, name: []const u8, def: RuntimeAnimationDef) !void {
        // Reserve the graveyard slot BEFORE any mutation so a failed
        // append can never strand the outgoing generation.
        try self.graveyard.ensureUnusedCapacity(self.allocator, 1);
        const boxed = try self.allocator.create(RuntimeAnimationDef);
        errdefer self.allocator.destroy(boxed);
        const gop = try self.map.getOrPut(name);
        if (gop.found_existing) {
            self.graveyard.appendAssumeCapacity(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, name) catch |err| {
                // Undo the half-inserted entry (its key is still the
                // caller's transient slice) before propagating.
                self.map.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        boxed.* = def;
        gop.value_ptr.* = boxed;
    }

    /// The live generation for `name`, or null when nothing was pushed.
    /// The borrow stays valid for the store's lifetime (generations are
    /// never freed before `deinit` — see the graveyard note).
    pub fn get(self: *const RuntimeAnimDefs, name: []const u8) ?*const RuntimeAnimationDef {
        return self.map.get(name);
    }

    /// Number of def names currently overridden.
    pub fn count(self: *const RuntimeAnimDefs) usize {
        return self.map.count();
    }
};
