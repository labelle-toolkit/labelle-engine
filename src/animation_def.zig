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
    const ClipEnumFields = blk: {
        var fields: [clip_count]std.builtin.Type.EnumField = undefined;
        for (clip_fields, 0..) |f, i| {
            fields[i] = .{ .name = f.name, .value = i };
        }
        break :blk fields;
    };

    const Clip = @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = &ClipEnumFields,
        .decls = &.{},
        .is_exhaustive = true,
    } });

    // Build Variant enum fields
    const VariantEnumFields = blk: {
        var fields: [variant_count]std.builtin.Type.EnumField = undefined;
        for (0..variant_count) |i| {
            fields[i] = .{ .name = variant_list[i], .value = i };
        }
        break :blk fields;
    };

    const Variant = @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = &VariantEnumFields,
        .decls = &.{},
        .is_exhaustive = true,
    } });

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
            table[i] = .{
                .frame_count = clip_data.frames,
                .speed = speed,
                .mode = mode,
                .folder = folder,
            };
        }
        break :blk table;
    };

    // Find max frames across all clips
    const max_frames: usize = blk: {
        var mx: usize = 1;
        for (&clip_meta_table) |meta| {
            if (meta.frame_count > mx) mx = meta.frame_count;
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
            const folder = clip_meta_table[ci].folder;
            const fc = clip_meta_table[ci].frame_count;
            for (0..variant_count) |vi| {
                const vname: []const u8 = variant_list[vi];
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

        /// Get metadata for a clip (frame_count, speed, mode, folder).
        pub fn clipMeta(clip: Clip) ClipMeta {
            return clip_meta_table[@intFromEnum(clip)];
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
        pub fn variantFromIndex(idx: usize) Variant {
            if (idx < variant_count) {
                return @enumFromInt(idx);
            }
            return @enumFromInt(variant_count - 1);
        }
    };
}
