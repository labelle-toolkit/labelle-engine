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
const anim_timing = @import("anim_timing.zig");
const anim_events = @import("animation_events.zig");

/// Cap on beats traversed per `advanceStateEvents` call. A normal tick
/// crosses 0–2 beats; only a pathological dt would exceed this. Beyond it,
/// the tail of markers/loop-ends is dropped (the saturating repetition
/// counter stays accurate arithmetically), bounding per-tick work.
const max_traverse: u32 = 512;

/// Deprecated alias (#667): the timer-driver axis now lives in
/// `anim_timing.AdvanceMode` (`engine.AdvanceMode`). Kept so `.zon`
/// `.mode` fields, `ClipMeta.mode`, and downstream code keep compiling.
pub const Mode = anim_timing.AdvanceMode;

/// One slot in a clip: file index `f` (rendered into
/// `"{folder}/{variant}_{f:04}.png"`) shown for `run` beats. An optional
/// `marker` name (#670) fires an `AnimMarkerHit` when the slot becomes
/// current — declared in `.zon` as `.{ .f = 4, .marker = "contact" }`.
pub const FrameEntry = struct {
    f: u16,
    run: u8,
    marker: ?[]const u8 = null,
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

/// A resolved transitional-clip rule (#671): when switching to `to`
/// (optionally only from `from`), play `via` once first.
pub const TransitionRule = struct { from: ?u8, to: u8, via: u8 };

/// Comptime clip-name → ordinal lookup over the `.clips` struct fields.
fn clipIdxByName(comptime clip_fields: anytype, comptime name: []const u8) ?u8 {
    inline for (clip_fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return null;
}

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
                const marker: ?[]const u8 = if (@hasField(@TypeOf(elem), "marker")) elem.marker else null;
                entries[i] = .{ .f = checkedF(elem.f), .run = @intCast(run), .marker = marker };
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

/// A `.variants` element is either a string (`"m_bald"`) or a struct
/// `.{ .name = "w_ginger", .overrides = .{ ... } }` (#666). Resolve its
/// display name either way.
fn variantNameOf(comptime elem: anytype) []const u8 {
    const info = @typeInfo(@TypeOf(elem));
    if (info == .pointer) return elem; // string literal (*const [N:0]u8)
    if (info == .@"struct") {
        if (!@hasField(@TypeOf(elem), "name")) @compileError("variant struct needs a `.name` field");
        return elem.name;
    }
    @compileError("variant must be a string or a `.{ .name, .overrides }` struct");
}

/// Reject any override field that isn't `frames`/`speed`/`mode`/`folder`
/// — overrides may change clip content, never its identity (#666).
fn validateOverrideFields(comptime T: type, comptime clip_name: []const u8, comptime variant_name: []const u8) void {
    if (@typeInfo(T) != .@"struct")
        @compileError("variant '" ++ variant_name ++ "' override for clip '" ++ clip_name ++
            "' must be a struct like `.{ .frames = 4 }`");
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const ok = std.mem.eql(u8, f.name, "frames") or
            std.mem.eql(u8, f.name, "speed") or
            std.mem.eql(u8, f.name, "mode") or
            std.mem.eql(u8, f.name, "folder");
        if (!ok) @compileError("variant '" ++ variant_name ++ "' override for clip '" ++ clip_name ++
            "' has unknown field '" ++ f.name ++ "' (only frames/speed/mode/folder allowed)");
    }
}

/// Clip index of a duck-typed state: game wrappers carry a typed `Clip`
/// enum where the engine component carries a `u8` — accept both (#686),
/// so `advanceState`/`advanceStateEvents` drop into either.
fn clipIndexOf(state: anytype) u8 {
    const T = @TypeOf(state.clip);
    return if (@typeInfo(T) == .@"enum") @intFromEnum(state.clip) else state.clip;
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

    // Build Variant enum fields (name from a string element or its `.name`).
    const VariantNames = blk: {
        var names: [variant_count][]const u8 = undefined;
        var values: [variant_count]u8 = undefined;
        inline for (variant_list, 0..) |velem, i| {
            names[i] = variantNameOf(velem);
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

    // Per-variant ClipMeta (#666): start from the base, then patch each
    // variant's `.overrides` block. Overrides change clip CONTENT (frames/
    // speed/mode/folder) only — never structure — so the single Clip/
    // Variant enum pair still drives every skin (Unity Sprite Library
    // Variant's structural-consistency rule).
    //
    // #664 reconciliation: a `.frames` override accepts the COUNT form
    // only (an entry-list override would need per-variant beat/marker
    // tables — a follow-up), and is rejected when the BASE clip declares
    // per-slot holds or markers (the base beat table would no longer
    // describe the overridden variant). Overridden variants play through
    // the state-carried path: `transitionFromMeta(clip, clipMetaFor(clip,
    // variant))` snapshots the right counts into AnimationState.
    const clip_meta_2d: [clip_count][variant_count]ClipMeta = blk: {
        var table: [clip_count][variant_count]ClipMeta = undefined;
        for (0..clip_count) |ci| {
            for (0..variant_count) |vi| table[ci][vi] = clip_meta_table[ci];
        }
        inline for (variant_list, 0..) |velem, vi| {
            const vinfo = @typeInfo(@TypeOf(velem));
            if (vinfo == .@"struct" and @hasField(@TypeOf(velem), "overrides")) {
                const ov = velem.overrides;
                if (@typeInfo(@TypeOf(ov)) != .@"struct")
                    @compileError("variant '" ++ variantNameOf(velem) ++
                        "' `.overrides` must be a struct of clip overrides");
                inline for (@typeInfo(@TypeOf(ov)).@"struct".fields) |of| {
                    const cidx = clipIdxByName(clip_fields, of.name) orelse
                        @compileError("variant '" ++ variantNameOf(velem) ++
                        "' overrides unknown clip '" ++ of.name ++ "'");
                    const override = @field(ov, of.name);
                    validateOverrideFields(@TypeOf(override), of.name, variantNameOf(velem));
                    var m = clip_meta_table[cidx];
                    if (@hasField(@TypeOf(override), "frames")) {
                        const finfo = @typeInfo(@TypeOf(override.frames));
                        if (!(finfo == .comptime_int or finfo == .int))
                            @compileError("variant '" ++ variantNameOf(velem) ++ "' override for clip '" ++
                                of.name ++ "': `.frames` must be a count — per-variant frame-entry overrides are a follow-up (#664 × #666)");
                        for (clip_entries[cidx], 0..) |e, ei| {
                            if (e.run != 1 or e.marker != null or e.f != ei + 1)
                                @compileError("variant '" ++ variantNameOf(velem) ++ "' cannot override `.frames` of clip '" ++
                                    of.name ++ "': the base clip declares holds/markers/reordering, which are per-clip (#664 × #666 follow-up)");
                        }
                        if (override.frames < 1 or override.frames > 255)
                            @compileError("override .frames must be 1..255");
                        m.frame_count = override.frames;
                        m.entry_count = override.frames;
                        m.beat_count = override.frames; // count form: 1 beat per slot
                    }
                    if (@hasField(@TypeOf(override), "speed")) m.speed = override.speed;
                    if (@hasField(@TypeOf(override), "mode")) m.mode = override.mode;
                    if (@hasField(@TypeOf(override), "folder")) m.folder = override.folder;
                    table[cidx][vi] = m;
                }
            }
        }
        break :blk table;
    };

    // Max slots (name-table depth; spans base AND overridden counts) and
    // max beats (beat-table depth; base only — see clip_meta_2d note).
    const max_slots: usize = blk: {
        var mx: usize = 1;
        for (0..clip_count) |ci| {
            for (0..variant_count) |vi| {
                if (clip_meta_2d[ci][vi].entry_count > mx) mx = clip_meta_2d[ci][vi].entry_count;
            }
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
            const entries = clip_entries[ci];
            for (0..variant_count) |vi| {
                // Per-variant folder + slot count (honors overrides). A
                // frames-overridden variant uses count-form files 1..N
                // (guarded above: only legal when the base has no
                // reorders/holds to preserve).
                const meta_v = clip_meta_2d[ci][vi];
                const folder = meta_v.folder;
                const overridden = meta_v.entry_count != clip_meta_table[ci].entry_count;
                const slot_count: usize = meta_v.entry_count;
                const vname: []const u8 = VariantNames.names[vi];
                for (0..max_slots) |si| {
                    if (si < slot_count) {
                        const file_idx: u16 = if (overridden or si >= entries.len)
                            @intCast(si + 1)
                        else
                            entries[si].f;
                        table[ci][vi][si] = std.fmt.comptimePrint("{s}/{s}_{d:0>4}.png", .{ folder, vname, file_idx });
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

    // Optional transitional-clip table (#671). When switching to `to`
    // (optionally only from a specific `from`), the driver plays `via`
    // once first. Comptime-validated: names resolve, `via != to` (no
    // self-loop), no duplicate (from, to) pair.
    const transition_table: []const TransitionRule = blk: {
        if (!@hasField(@TypeOf(zon), "transitions")) break :blk &[_]TransitionRule{};
        const trs = zon.transitions;
        const tinfo = @typeInfo(@TypeOf(trs));
        if (!(tinfo == .@"struct" and tinfo.@"struct".is_tuple))
            @compileError("animation .zon `.transitions` must be a tuple of rules");
        const tfields = tinfo.@"struct".fields;
        var rules: [tfields.len]TransitionRule = undefined;
        inline for (tfields, 0..) |tf, i| {
            const rule = @field(trs, tf.name);
            if (!@hasField(@TypeOf(rule), "to")) @compileError("transition rule needs a `.to` clip name");
            if (!@hasField(@TypeOf(rule), "via")) @compileError("transition rule needs a `.via` clip name");
            const to_idx = clipIdxByName(clip_fields, rule.to) orelse
                @compileError("transition `.to` names an unknown clip: " ++ rule.to);
            const via_idx = clipIdxByName(clip_fields, rule.via) orelse
                @compileError("transition `.via` names an unknown clip: " ++ rule.via);
            if (to_idx == via_idx)
                @compileError("transition `.via` must differ from `.to` (would loop): " ++ rule.to);
            const from_idx: ?u8 = if (@hasField(@TypeOf(rule), "from"))
                (clipIdxByName(clip_fields, rule.from) orelse
                    @compileError("transition `.from` names an unknown clip: " ++ rule.from))
            else
                null;
            rules[i] = .{ .from = from_idx, .to = to_idx, .via = via_idx };
        }
        for (rules, 0..) |a, ai| {
            for (rules[0..ai]) |b| {
                if (a.to == b.to and a.from == b.from)
                    @compileError("duplicate transition rule for the same (from, to) pair");
            }
        }
        const out = rules;
        break :blk &out;
    };

    // Marker → beat table (#670): the marker name at each beat that is a
    // slot's FIRST beat and carries a marker, else "". A held slot (run>1)
    // fires its marker once, at entry. Padded to `max_beats` with "".
    const marker_beats: [clip_count][max_beats][]const u8 = blk: {
        var table: [clip_count][max_beats][]const u8 = undefined;
        for (0..clip_count) |ci| {
            for (0..max_beats) |bi| table[ci][bi] = "";
            const entries = clip_entries[ci];
            var b: usize = 0;
            for (entries) |e| {
                if (e.marker) |name| table[ci][b] = name;
                b += e.run;
            }
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
        pub const transition_count_val = transition_table.len;

        /// Base (variant-independent) metadata for a clip.
        ///
        /// Deprecated for entities with per-variant overrides (#666): a
        /// variant that overrides this clip plays a DIFFERENT frame count/
        /// speed/folder, and reading the base row would drive the base
        /// count into empty sprite-name slots. Use `clipMetaFor(clip,
        /// variant)` in `transitionClip`-style call sites; `clipMeta` stays
        /// for callers with no overrides (it equals `clipMetaFor(clip, v)`
        /// for every non-overriding variant).
        pub fn clipMeta(clip: Clip) ClipMeta {
            return clip_meta_table[@intFromEnum(clip)];
        }

        /// Metadata for a clip AS SEEN BY a specific variant (#666) —
        /// the base patched by that variant's `.overrides`, if any.
        pub fn clipMetaFor(clip: Clip, variant: Variant) ClipMeta {
            return clip_meta_2d[@intFromEnum(clip)][@intFromEnum(variant)];
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
        /// name survives reordering the `.variants` list. Callers
        /// translate `null` into their own fallback (e.g. variant 0 + a
        /// warning) since the engine can't know the game's default skin.
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
            const ci = clipIndexOf(state);
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

        /// Resolve a transitional (`.via`) clip for a `from → to` switch,
        /// or null if no rule matches (#671). A `from`-specific rule wins
        /// over a wildcard (`from == null`) rule for the same `to`, so the
        /// driver can play e.g. `enter_combat` before any → `idle_combat`.
        pub fn transitionVia(from: u8, to: u8) ?u8 {
            var wildcard: ?u8 = null;
            for (transition_table) |r| {
                if (r.to != to) continue;
                if (r.from) |f| {
                    if (f == from) return r.via;
                } else {
                    wildcard = r.via;
                }
            }
            return wildcard;
        }

        /// The marker name at a beat of a clip, or "" if none (#670).
        /// Markers fire at a slot's FIRST beat only.
        pub fn markerAtBeat(clip: Clip, beat: u16) []const u8 {
            const cci = @intFromEnum(clip);
            const bc = clip_meta_table[cci].beat_count;
            if (bc == 0) return "";
            return marker_beats[cci][beat % bc];
        }

        /// Beat-aware advance that ALSO emits per-frame markers + loop-end
        /// events (#670) into `out`. Superset of `advanceState`: use it for
        /// entities whose clips carry markers or need lifecycle events; use
        /// `advanceState` when events aren't wanted (the no-event overload).
        ///
        /// Traverses the beats crossed THIS tick in linear (unwrapped)
        /// space, so a dt spike that skips frames still fires every skipped
        /// marker — oldest first — and every loop boundary, never "latest
        /// only" (a skipped `contact` marker is a silent punch). `state`
        /// needs the transient `.event_pos` (last processed beat position)
        /// and `.repetition` (saturating loop count) fields on top of what
        /// `advanceState` reads. The driver adds the entity and forwards
        /// `out` to `game.emit`.
        pub fn advanceStateEvents(state: anytype, dt: f32, out: *anim_events.PendingBuf) void {
            const ci = clipIndexOf(state);
            const meta = clip_meta_table[ci];
            if (meta.mode == .static) {
                state.frame = 0;
                state.event_pos = 0;
                return;
            }
            if (meta.mode == .time) state.timer += dt * state.speed;
            // .distance: `state.timer` is written externally by the game.

            const bc = meta.beat_count;
            if (bc == 0) return;

            var old_pos = state.event_pos;
            if (old_pos < 0) old_pos = 0;
            const new_pos = state.timer;

            if (new_pos > old_pos) {
                const bc_i: i64 = bc;
                const old_lin: i64 = @intFromFloat(@floor(old_pos));
                const new_lin: i64 = @intFromFloat(@floor(new_pos));

                // Authoritative saturating repetition over the FULL span —
                // stays correct even when per-beat emission is capped.
                const wraps_full: i64 = @divFloor(new_lin, bc_i) - @divFloor(old_lin, bc_i);
                const base_rep = state.repetition;

                // Beat 0 of the FIRST play-through: the traversal below
                // walks beats old_lin+1..new_lin, so the clip's entry beat
                // (displayed the moment the clip started) would never fire
                // its marker on the first cycle — only on wraps. Fire it
                // here exactly once, on the first forward advance.
                if (old_pos == 0 and old_lin == 0) {
                    const entry_name = marker_beats[ci][0];
                    if (entry_name.len > 0) {
                        _ = out.append(.{ .kind = .marker, .clip = ci, .frame = beat_to_slot[ci][0], .marker = entry_name, .repetition = base_rep });
                    }
                }

                var rep = base_rep;
                var b = old_lin + 1;
                var guard: u32 = 0;
                while (b <= new_lin and guard < max_traverse) : ({
                    b += 1;
                    guard += 1;
                }) {
                    const in_cycle: u16 = @intCast(@mod(b, bc_i));
                    if (in_cycle == 0) {
                        // Crossed a clip boundary — the prior cycle ended.
                        rep = anim_events.satAddU16(rep, 1);
                        _ = out.append(.{ .kind = .loop_end, .clip = ci, .repetition = rep });
                    }
                    const name = marker_beats[ci][in_cycle];
                    if (name.len > 0) {
                        _ = out.append(.{ .kind = .marker, .clip = ci, .frame = beat_to_slot[ci][in_cycle], .marker = name, .repetition = rep });
                    }
                }
                const add: u16 = if (wraps_full > 0xFFFF) 0xFFFF else @intCast(@max(wraps_full, 0));
                state.repetition = anim_events.satAddU16(base_rep, add);
            }

            state.event_pos = new_pos;
            const final_beat: u16 = @intCast(@mod(@as(i64, @intFromFloat(@floor(new_pos))), @as(i64, bc)));
            state.frame = beat_to_slot[ci][final_beat];
        }
    };
}
