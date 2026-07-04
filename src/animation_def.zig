/// AnimationDef — comptime animation definition from .zon data.
///
/// Parses a .zon struct with `.variants` and `.clips` fields and generates:
///   - A `Clip` enum with one tag per clip name
///   - A `Variant` enum with one tag per variant name
///   - A `ClipMeta` array indexed by clip ordinal (entry/beat counts, speed, mode)
///   - A precomputed sprite name table: `[clips][variants][max_slots][]const u8`
///
/// Usage:
///   const WorkerAnim = AnimationDef(@import("animations/worker.zon"));
///   const clip = WorkerAnim.Clip.walk;
///   const meta = WorkerAnim.clipMeta(clip);
///   const name = WorkerAnim.spriteName(.walk, .m_bald, 2); // "walk/m_bald_0003.png"
///
/// Frame schema (#664). A clip's `.frames` accepts three forms, all
/// comptime-normalized to a list of slots (`FrameEntry{ f, run }`):
///   .frames = 4                              // count: slots 1..4, run 1 each
///   .frames = .{ 1, 2, 3, 2 }                // explicit indices (reorder/reuse), run 1
///   .frames = .{ .{ .f = 1, .run = 2 }, 2 }  // per-slot holds; bare int == run 1
/// `speed` is beats/unit (seconds for `.time`, distance units for `.distance`);
/// a slot showing for `run` beats. The count form has run 1 everywhere, so
/// `beat_count == slot_count` and playback is bit-identical to pre-#664.

const std = @import("std");

pub const Mode = enum {
    /// timer += dt * speed; frame cycles over time.
    time,
    /// Game writes timer from position delta; frame cycles over distance.
    distance,
    /// frame = 0 always.
    static,
};

/// One slot in a clip: file index `f` (rendered into
/// `"{folder}/{variant}_{f:04}.png"`) shown for `run` beats.
pub const FrameEntry = struct {
    f: u16,
    run: u8,
};

pub const ClipMeta = struct {
    /// Number of slots in the clip (`.frames` list length; the count
    /// shorthand N gives N slots). This is what `frame` cycles over as
    /// a slot index. Kept named `frame_count` for back-compat: callers
    /// that predate #664 (transition, game FSMs) read this and, for the
    /// count-shorthand clips they all use today, it equals `beat_count`,
    /// so `AnimationState.advance` stays correct without a change.
    frame_count: u8,
    /// Alias of `frame_count` under the #664 vocabulary (slots).
    entry_count: u8,
    /// Total beats in the clip = sum of every slot's `run`. The cycle
    /// length for `advanceState`. Equals `entry_count` iff every run is 1.
    beat_count: u16,
    speed: f32,
    mode: Mode,
    /// Sprite folder name (may differ from clip name, e.g. carry → "take").
    folder: []const u8,
};

/// Normalize any of the three `.frames` forms into a slot list. Pure
/// comptime; the returned slice points at comptime memory. Rejects
/// malformed data with a clear message (empty, run 0, f out of the
/// 1–9999 filename range, >255 slots).
fn normalizeFrames(comptime frames: anytype) []const FrameEntry {
    const info = @typeInfo(@TypeOf(frames));
    // Form 1 — bare count N → slots {1,1},{2,1},…,{N,1}.
    if (info == .comptime_int or info == .int) {
        if (frames < 1) @compileError("clip .frames count must be >= 1");
        if (frames > 255) @compileError("clip .frames has more than 255 slots");
        const n: usize = frames;
        var entries: [n]FrameEntry = undefined;
        for (0..n) |i| entries[i] = .{ .f = @intCast(i + 1), .run = 1 };
        const out = entries;
        return &out;
    }
    // Forms 2 & 3 — a tuple of ints and/or `.{ .f, .run }` structs.
    if (info == .@"struct" and info.@"struct".is_tuple) {
        const fields = info.@"struct".fields;
        if (fields.len == 0) @compileError("clip .frames list must not be empty");
        if (fields.len > 255) @compileError("clip .frames has more than 255 slots");
        var entries: [fields.len]FrameEntry = undefined;
        inline for (fields, 0..) |field, i| {
            const elem = @field(frames, field.name);
            const einfo = @typeInfo(@TypeOf(elem));
            if (einfo == .comptime_int or einfo == .int) {
                entries[i] = .{ .f = checkedF(elem), .run = 1 };
            } else if (einfo == .@"struct") {
                if (!@hasField(@TypeOf(elem), "f")) @compileError("frame entry struct needs an `.f` field");
                const run = if (@hasField(@TypeOf(elem), "run")) elem.run else 1;
                if (run < 1) @compileError("frame .run must be >= 1");
                if (run > 255) @compileError("frame .run must be <= 255");
                entries[i] = .{ .f = checkedF(elem.f), .run = @intCast(run) };
            } else {
                @compileError("frame entry must be an int index or a `.{ .f, .run }` struct");
            }
        }
        const out = entries;
        return &out;
    }
    @compileError("clip .frames must be an int count or a tuple of frame entries");
}

fn checkedF(comptime f: anytype) u16 {
    if (f < 1) @compileError("frame index .f must be >= 1");
    if (f > 9999) @compileError("frame index .f must be <= 9999 (4-digit filename field)");
    return @intCast(f);
}

pub fn AnimationDef(comptime zon: anytype) type {
    if (!@hasField(@TypeOf(zon), "clips")) @compileError("animation .zon must have a .clips field");
    if (!@hasField(@TypeOf(zon), "variants")) @compileError("animation .zon must have a .variants field");

    const clip_fields = @typeInfo(@TypeOf(zon.clips)).@"struct".fields;
    const variant_list = zon.variants;
    const variant_count = variant_list.len;
    const clip_count = clip_fields.len;

    comptime {
        if (variant_count == 0) @compileError("animation .zon must define at least one variant");
        if (clip_count == 0) @compileError("animation .zon must define at least one clip");
    }

    // Build Clip enum fields
    const ClipNames = blk: {
        var names: [clip_count][]const u8 = undefined;
        var values: [clip_count]u8 = undefined;
        for (clip_fields, 0..) |f, i| {
            names[i] = f.name;
            values[i] = i;
        }
        break :blk .{ .names = names, .values = values };
    };

    const Clip = @Enum(u8, .exhaustive, &ClipNames.names, &ClipNames.values);

    // Build Variant enum fields
    const VariantNames = blk: {
        var names: [variant_count][]const u8 = undefined;
        var values: [variant_count]u8 = undefined;
        for (0..variant_count) |i| {
            names[i] = variant_list[i];
            values[i] = i;
        }
        break :blk .{ .names = names, .values = values };
    };

    const Variant = @Enum(u8, .exhaustive, &VariantNames.names, &VariantNames.values);

    // Per-clip normalized slot lists — the single source the meta table,
    // name table, and beat table all derive from.
    const clip_entries: [clip_count][]const FrameEntry = blk: {
        var arr: [clip_count][]const FrameEntry = undefined;
        for (clip_fields, 0..) |f, i| {
            arr[i] = normalizeFrames(@field(zon.clips, f.name).frames);
        }
        break :blk arr;
    };

    // Build ClipMeta table
    const clip_meta_table: [clip_count]ClipMeta = blk: {
        var table: [clip_count]ClipMeta = undefined;
        for (clip_fields, 0..) |f, i| {
            const clip_data = @field(zon.clips, f.name);
            const folder: []const u8 = if (@hasField(@TypeOf(clip_data), "folder"))
                clip_data.folder
            else
                f.name;
            const speed: f32 = if (@hasField(@TypeOf(clip_data), "speed"))
                clip_data.speed
            else
                1.0;
            const mode: Mode = if (@hasField(@TypeOf(clip_data), "mode"))
                clip_data.mode
            else
                .static;
            const entries = clip_entries[i];
            var beats: u16 = 0;
            for (entries) |e| beats += e.run;
            // A .static clip only ever shows slot 0, so per-slot holds
            // are meaningless — reject them rather than silently ignore.
            if (mode == .static) {
                for (entries) |e| {
                    if (e.run != 1) @compileError("clip '" ++ f.name ++ "' is .static but declares a .run — holds are meaningless when frame is always slot 0");
                }
            }
            table[i] = .{
                .frame_count = @intCast(entries.len),
                .entry_count = @intCast(entries.len),
                .beat_count = beats,
                .speed = speed,
                .mode = mode,
                .folder = folder,
            };
        }
        break :blk table;
    };

    // Max slots (name-table depth) and max beats (beat-table depth).
    const max_slots: usize = blk: {
        var mx: usize = 1;
        for (&clip_meta_table) |meta| {
            if (meta.entry_count > mx) mx = meta.entry_count;
        }
        break :blk mx;
    };
    const max_beats: usize = blk: {
        var mx: usize = 1;
        for (&clip_meta_table) |meta| {
            if (meta.beat_count > mx) mx = meta.beat_count;
        }
        break :blk mx;
    };

    // Precomputed sprite name table, keyed by SLOT. The name for slot i
    // uses `entries[i].f` (not i+1), so reordered/reused frames resolve
    // to the right file. Format: "{folder}/{variant}_{f:04}.png".
    const SpriteNameTable = [clip_count][variant_count][max_slots][]const u8;
    const sprite_names: SpriteNameTable = blk: {
        @setEvalBranchQuota(clip_count * variant_count * max_slots * 2000);
        var table: SpriteNameTable = undefined;
        for (0..clip_count) |ci| {
            const folder = clip_meta_table[ci].folder;
            const entries = clip_entries[ci];
            for (0..variant_count) |vi| {
                const vname: []const u8 = variant_list[vi];
                for (0..max_slots) |si| {
                    if (si < entries.len) {
                        table[ci][vi][si] = std.fmt.comptimePrint("{s}/{s}_{d:0>4}.png", .{ folder, vname, entries[si].f });
                    } else {
                        table[ci][vi][si] = "";
                    }
                }
            }
        }
        break :blk table;
    };

    // Beat → slot table: slot j repeated `run_j` times, so a runtime
    // `slot = beat_to_slot[clip][beat]` lookup is O(1) with no per-tick
    // summation. Padded to `max_beats`; entries past a clip's beat_count
    // are 0 (never read — `advanceState` mods by beat_count first).
    const beat_to_slot: [clip_count][max_beats]u8 = blk: {
        var table: [clip_count][max_beats]u8 = undefined;
        for (0..clip_count) |ci| {
            const entries = clip_entries[ci];
            var b: usize = 0;
            for (entries, 0..) |e, si| {
                var r: usize = 0;
                while (r < e.run) : (r += 1) {
                    table[ci][b] = @intCast(si);
                    b += 1;
                }
            }
            while (b < max_beats) : (b += 1) table[ci][b] = 0;
        }
        break :blk table;
    };

    return struct {
        pub const clips = Clip;
        pub const variants = Variant;
        pub const clip_count_val = clip_count;
        pub const variant_count_val = variant_count;
        /// Depth of the slot-keyed sprite-name table. Named `max_frames_val`
        /// for back-compat (== max slot count).
        pub const max_frames_val = max_slots;
        pub const max_slots_val = max_slots;
        pub const max_beats_val = max_beats;

        /// Get metadata for a clip (counts, speed, mode, folder).
        pub fn clipMeta(clip: Clip) ClipMeta {
            return clip_meta_table[@intFromEnum(clip)];
        }

        /// Look up the precomputed sprite name for a clip/variant/SLOT.
        /// `frame` is the slot index (0-based).
        pub fn spriteName(clip: Clip, variant: Variant, frame: u8) []const u8 {
            if (frame >= max_slots) return "";
            return sprite_names[@intFromEnum(clip)][@intFromEnum(variant)][frame];
        }

        /// The slot shown at a given beat of a clip (0-based beat). Beats
        /// past the clip's `beat_count` wrap via the caller's mod; this
        /// clamps defensively.
        pub fn slotForBeat(clip: Clip, beat: u16) u8 {
            const ci = @intFromEnum(clip);
            const bc = clip_meta_table[ci].beat_count;
            if (bc == 0) return 0;
            return beat_to_slot[ci][beat % bc];
        }

        /// Get variant name string.
        pub fn variantName(variant: Variant) []const u8 {
            return @tagName(variant);
        }

        /// Get clip name string.
        pub fn clipName(clip: Clip) []const u8 {
            return @tagName(clip);
        }

        /// Map an index to a variant, with fallback to the last variant.
        ///
        /// Deprecated as a *persistence* path (#665): a raw index makes
        /// the `.variants` order load-bearing, so any reorder/rename
        /// silently corrupts saves. Persist the variant NAME and resolve
        /// via `variantFromName` instead. `variantFromIndex` remains only
        /// for migrating pre-manifest saves (translate a saved index
        /// through the save-time name manifest, then re-resolve by name).
        pub fn variantFromIndex(idx: usize) Variant {
            if (idx < variant_count) {
                return @enumFromInt(idx);
            }
            return @enumFromInt(variant_count - 1);
        }

        /// Resolve a variant NAME to its `Variant`, or `null` when no
        /// variant carries that name (renamed or deleted). This is the
        /// stable-identity persistence path (#665): unlike an index, a
        /// name survives reordering the `.variants` list. Comptime-
        /// unrolled string compare — one branch per variant, no
        /// allocation. Callers translate `null` into their own fallback
        /// (e.g. variant 0 + a warning) since the engine can't know the
        /// game's default skin.
        pub fn variantFromName(name: []const u8) ?Variant {
            return std.meta.stringToEnum(Variant, name);
        }

        /// Beat-aware advance for clips with per-slot holds. Mirrors
        /// `AnimationState.advance` but cycles over BEATS (sum of runs)
        /// and maps the current beat to a slot via the comptime beat
        /// table, writing the slot into `state.frame`. `state` is
        /// duck-typed (`.clip/.mode/.speed/.timer/.frame`) to avoid a
        /// circular import with `animation_state.zig`.
        ///
        /// For count-shorthand clips (every run 1) `beat_count ==
        /// entry_count` and this is identical to `advance`, so a game
        /// can switch to it wholesale; only clips that declare runs
        /// *need* it. Full advance-dedup is #667.
        pub fn advanceState(state: anytype, dt: f32) void {
            const ci = state.clip;
            const meta = clip_meta_table[ci];
            switch (meta.mode) {
                .time => {
                    state.timer += dt * state.speed;
                    if (meta.beat_count > 0) {
                        const bc: f32 = @floatFromInt(meta.beat_count);
                        const beat: u16 = @intFromFloat(@mod(state.timer, bc));
                        state.frame = beat_to_slot[ci][beat % meta.beat_count];
                    }
                },
                .distance => {
                    if (meta.beat_count > 0) {
                        const bc: f32 = @floatFromInt(meta.beat_count);
                        const beat: u16 = @intFromFloat(@mod(state.timer, bc));
                        state.frame = beat_to_slot[ci][beat % meta.beat_count];
                    }
                },
                .static => {
                    state.frame = 0;
                },
            }
        }
    };
}
