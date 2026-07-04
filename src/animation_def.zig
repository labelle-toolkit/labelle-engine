/// AnimationDef — comptime animation definition from .zon data.
///
/// Parses a .zon struct with `.variants` and `.clips` fields and generates:
///   - A `Clip` enum with one tag per clip name
///   - A `Variant` enum with one tag per variant name
///   - A `ClipMeta` array indexed by clip ordinal (frame_count, speed, mode)
///   - A precomputed sprite name table: `[clips][variants][max_frames][]const u8`
///
/// Usage:
///   const WorkerAnim = AnimationDef(@import("animations/worker.zon"));
///   const clip = WorkerAnim.Clip.walk;
///   const meta = WorkerAnim.clipMeta(clip);
///   const name = WorkerAnim.spriteName(.walk, .m_bald, 2); // "walk/m_bald_0003.png"

const std = @import("std");

pub const Mode = enum {
    /// timer += dt * speed; frame cycles over time.
    time,
    /// Game writes timer from position delta; frame cycles over distance.
    distance,
    /// frame = 0 always.
    static,
};

pub const ClipMeta = struct {
    frame_count: u8,
    speed: f32,
    mode: Mode,
    /// Sprite folder name (may differ from clip name, e.g. carry → "take").
    folder: []const u8,
};

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

/// Comptime clip-name → ordinal lookup over the `.clips` struct fields.
fn clipIdxByName(comptime clip_fields: anytype, comptime name: []const u8) ?usize {
    inline for (clip_fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

/// Reject any override field that isn't `frames`/`speed`/`mode`/`folder`
/// — overrides may change clip content, never its identity (#666).
fn validateOverrideFields(comptime T: type, comptime clip_name: []const u8, comptime variant_name: []const u8) void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const ok = std.mem.eql(u8, f.name, "frames") or
            std.mem.eql(u8, f.name, "speed") or
            std.mem.eql(u8, f.name, "mode") or
            std.mem.eql(u8, f.name, "folder");
        if (!ok) @compileError("variant '" ++ variant_name ++ "' override for clip '" ++ clip_name ++
            "' has unknown field '" ++ f.name ++ "' (only frames/speed/mode/folder allowed)");
    }
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

    // Base ClipMeta per clip (variant-independent). `clipMeta(clip)`
    // returns this row; a plain-string variant sees exactly this.
    const clip_base_meta: [clip_count]ClipMeta = blk: {
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
            table[i] = .{
                .frame_count = clip_data.frames,
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
    // Variant's structural-consistency rule). Comptime-validated: override
    // keys must be existing clips; only the four content fields may appear.
    const clip_meta_2d: [clip_count][variant_count]ClipMeta = blk: {
        var table: [clip_count][variant_count]ClipMeta = undefined;
        for (0..clip_count) |ci| {
            for (0..variant_count) |vi| table[ci][vi] = clip_base_meta[ci];
        }
        inline for (variant_list, 0..) |velem, vi| {
            const vinfo = @typeInfo(@TypeOf(velem));
            if (vinfo == .@"struct" and @hasField(@TypeOf(velem), "overrides")) {
                const ov = velem.overrides;
                inline for (@typeInfo(@TypeOf(ov)).@"struct".fields) |of| {
                    const cidx = clipIdxByName(clip_fields, of.name) orelse
                        @compileError("variant '" ++ variantNameOf(velem) ++
                        "' overrides unknown clip '" ++ of.name ++ "'");
                    const override = @field(ov, of.name);
                    validateOverrideFields(@TypeOf(override), of.name, variantNameOf(velem));
                    var m = clip_base_meta[cidx];
                    if (@hasField(@TypeOf(override), "frames")) m.frame_count = override.frames;
                    if (@hasField(@TypeOf(override), "speed")) m.speed = override.speed;
                    if (@hasField(@TypeOf(override), "mode")) m.mode = override.mode;
                    if (@hasField(@TypeOf(override), "folder")) m.folder = override.folder;
                    table[cidx][vi] = m;
                }
            }
        }
        break :blk table;
    };

    // Max frames across base AND overridden counts — the sprite-name
    // table depth must fit the largest per-variant frame count.
    const max_frames: usize = blk: {
        var mx: usize = 1;
        for (0..clip_count) |ci| {
            for (0..variant_count) |vi| {
                if (clip_meta_2d[ci][vi].frame_count > mx) mx = clip_meta_2d[ci][vi].frame_count;
            }
        }
        break :blk mx;
    };

    // Build precomputed sprite name table
    // Format: "{folder}/{variant}_{frame:04}.png"
    const SpriteNameTable = [clip_count][variant_count][max_frames][]const u8;

    // Precompute all sprite name strings at comptime. The branch quota scales
    // with the table size because comptimePrint uses Writer internals that
    // consume many branches per formatted string.
    const sprite_names: SpriteNameTable = blk: {
        @setEvalBranchQuota(clip_count * variant_count * max_frames * 2000);
        var table: SpriteNameTable = undefined;
        for (0..clip_count) |ci| {
            for (0..variant_count) |vi| {
                // Per-variant folder + frame count (honors overrides).
                const folder = clip_meta_2d[ci][vi].folder;
                const fc = clip_meta_2d[ci][vi].frame_count;
                const vname: []const u8 = VariantNames.names[vi];
                for (0..max_frames) |fi| {
                    if (fi < fc) {
                        const frame_1 = fi + 1;
                        table[ci][vi][fi] = std.fmt.comptimePrint("{s}/{s}_{d:0>4}.png", .{ folder, vname, frame_1 });
                    } else {
                        table[ci][vi][fi] = "";
                    }
                }
            }
        }
        break :blk table;
    };

    return struct {
        pub const clips = Clip;
        pub const variants = Variant;
        pub const clip_count_val = clip_count;
        pub const variant_count_val = variant_count;
        pub const max_frames_val = max_frames;

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
            return clip_base_meta[@intFromEnum(clip)];
        }

        /// Metadata for a clip AS SEEN BY a specific variant (#666) —
        /// the base patched by that variant's `.overrides`, if any.
        pub fn clipMetaFor(clip: Clip, variant: Variant) ClipMeta {
            return clip_meta_2d[@intFromEnum(clip)][@intFromEnum(variant)];
        }

        /// Look up the precomputed sprite name for a clip/variant/frame combination.
        /// Frame is 0-based.
        pub fn spriteName(clip: Clip, variant: Variant, frame: u8) []const u8 {
            if (frame >= max_frames) return "";
            return sprite_names[@intFromEnum(clip)][@intFromEnum(variant)][frame];
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
            inline for (@typeInfo(Variant).@"enum".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return @field(Variant, field.name);
            }
            return null;
        }
    };
}
