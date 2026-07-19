//! UI-kit DrawList consumer (issue #771).
//!
//! The in-game UI kit (labelle-gui `src/ui_kit/render.zig`, issue
//! labelle-gui#214) walks its retained widget tree into a flat,
//! GPU-agnostic `DrawList` of `DrawCmd`s: 9-slice `textured_quad`s,
//! `solid_quad` fallbacks, wrapped `text_line`s, and a `focus_highlight`
//! ring. That DrawList is the single cross-repo seam between the kit and
//! any renderer — this module is the *engine* side of that seam.
//!
//! ## Why the engine re-declares the command shape
//!
//! The engine cannot import labelle-gui (it would drag the whole editor
//! build into every game), so — exactly like the `Glyph`/`CodepointEntry`/
//! `KernPair` extern structs canonicalised in labelle-core — the command
//! shape is mirrored structurally. `convertCommand` accepts *any* union
//! whose tags/fields match the kit contract (duck-typed via `inline else`),
//! so a game passes `ui_kit.render.DrawList.items` straight in; unknown
//! tags are ignored at comptime, keeping the seam forward-compatible.
//!
//! ## Coordinate space
//!
//! Kit rects are SCREEN space: top-left origin, +y down, pixels — the same
//! convention as `drawRenderTarget` composites. Commands are drawn exactly
//! as given, with no camera transform and no y-axis flip; the renderer's
//! screen-quad primitives (`drawScreenTexture` / `drawScreenRect`,
//! labelle-gfx) already treat coordinates that way.
//!
//! ## Fonts
//!
//! `text_line` carries a font *name*, not glyphs — glyph drawing is the
//! renderer's job (the kit only measures/wraps). `UiFontStore` holds the
//! baked-atlas fonts the engine rasterised (see `bakeUiFont` in
//! `game/ui_kit_mixin.zig`): the glyph/codepoint/kern tables (labelle-core
//! extern layout — the same tables a `ui_kit.font.FontMetrics` borrows via
//! identity `@ptrCast`) plus the RGBA-expanded atlas texture. The walk here
//! reproduces the kit's pen advance (kern-then-advance, unbaked glyphs
//! advance 0) so drawn glyphs land exactly where the kit measured them.

const std = @import("std");
const font_types = @import("font_types");

// ─── Geometry / color ──────────────────────────────────────────────────────

/// Screen-space rectangle: top-left origin, +y down, pixels. Mirrors the
/// kit's `Rect { x, y, w, h }`.
pub const UiRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// 8-bit straight-alpha RGBA — the renderer boundary quantisation of the
/// kit's f32 `Color` (matching `ui_kit.Color.toU8`).
pub const UiRgba8 = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,
};

/// Normalised (0..1) UV sub-rect into the theme atlas texture. Mirrors the
/// kit's `UvRect`.
pub const UiUvRect = struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 1,
    v1: f32 = 1,
};

// ─── Commands (engine-internal, converted from the kit's DrawCmd) ──────────

/// One retained draw command. Field-for-field the kit's `DrawCmd` payloads
/// with colors quantised to `UiRgba8`; `text_line` slices are owned by the
/// submitting game (duped by `submitUiDrawList`, freed after the draw).
pub const UiDrawCmd = union(enum) {
    textured_quad: struct { dst: UiRect, uv: UiUvRect, tint: UiRgba8 },
    solid_quad: struct { dst: UiRect, color: UiRgba8 },
    text_line: struct {
        dst: UiRect,
        content: []const u8,
        color: UiRgba8,
        size_px: f32,
        font_name: []const u8,
    },
    /// The kit's `focus_highlight` minus the `ElementId` (the engine draws
    /// the ring; identity is a kit concern).
    focus_rect: struct { rect: UiRect },
};

fn quantColor(v: f32) u8 {
    // `@intFromFloat` panics on NaN in Debug/ReleaseSafe. A UI color can go
    // NaN through a 0/0 in layout/animation math — treat it as 0 (fully
    // transparent / black component) rather than crash the game.
    if (std.math.isNan(v)) return 0;
    const clamped = @max(0.0, @min(1.0, v));
    return @intFromFloat(@round(clamped * 255.0));
}

fn toRgba8(color: anytype) UiRgba8 {
    return .{
        .r = quantColor(color.r),
        .g = quantColor(color.g),
        .b = quantColor(color.b),
        .a = quantColor(color.a),
    };
}

fn toUiRect(rect: anytype) UiRect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

/// Convert one kit-shaped `DrawCmd` (any union whose tag names/payload
/// fields match the labelle-gui ui_kit contract) into the engine's
/// `UiDrawCmd`. Returns `null` for tags the engine does not know — the
/// caller skips them, so a newer kit keeps working against an older engine.
///
/// NOTE: `text_line` slices are borrowed from the input command here;
/// `submitUiDrawList` dupes them before retaining.
pub fn convertCommand(cmd: anytype) ?UiDrawCmd {
    switch (cmd) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            if (comptime std.mem.eql(u8, name, "textured_quad")) {
                return .{ .textured_quad = .{
                    .dst = toUiRect(payload.dst),
                    .uv = .{
                        .u0 = payload.uv.u0,
                        .v0 = payload.uv.v0,
                        .u1 = payload.uv.u1,
                        .v1 = payload.uv.v1,
                    },
                    .tint = toRgba8(payload.tint),
                } };
            } else if (comptime std.mem.eql(u8, name, "solid_quad")) {
                return .{ .solid_quad = .{
                    .dst = toUiRect(payload.dst),
                    .color = toRgba8(payload.color),
                } };
            } else if (comptime std.mem.eql(u8, name, "text_line")) {
                return .{ .text_line = .{
                    .dst = toUiRect(payload.dst),
                    .content = payload.content,
                    .color = toRgba8(payload.color),
                    .size_px = payload.size_px,
                    .font_name = payload.font_name,
                } };
            } else if (comptime std.mem.eql(u8, name, "focus_highlight")) {
                return .{ .focus_rect = .{ .rect = toUiRect(payload.rect) } };
            } else {
                return null;
            }
        },
    }
}

// ─── Baked UI fonts ────────────────────────────────────────────────────────

/// One rasterised font: the baked glyph tables (labelle-core extern layout,
/// pixel-space UV rects into the atlas) plus the atlas texture the engine
/// uploaded (RGBA-expanded, so it draws through the ordinary textured-quad
/// path and tints with the text color).
///
/// The three table slices are exactly what a `ui_kit.font.FontMetrics`
/// wants: `glyphs`/`codepoint_index`/`kerning` reinterpret across the repo
/// boundary as an identity `@ptrCast` (RFC-FONT-LOADER §3), the four
/// scalars copy. Game-side glue building the kit's `FontResolver` reads
/// them straight off this struct.
pub const BakedUiFont = struct {
    /// Renderer texture handle (`u32`, the engine-wide texture id shape).
    /// Re-minted by `reuploadUiFonts` after a GPU surface loss.
    texture_id: u32,
    atlas_width: u32,
    atlas_height: u32,

    /// The expanded white-RGBA atlas pixels (`atlas_width*atlas_height*4`),
    /// owned. Retained — NOT freed after the initial upload — so the atlas
    /// can be re-uploaded verbatim after an Android GPU surface loss
    /// (TERM_WINDOW destroys every texture). The bitmap→RGBA expansion and
    /// stb_truetype bake are the expensive parts; keeping the small RGBA
    /// buffer trades ~atlas_bytes of RAM for a decode-free restore.
    atlas_rgba: []u8,

    /// Dense glyph table, addressed via `codepoint_index`. Owned.
    glyphs: []font_types.Glyph,
    /// codepoint → glyph index, sorted ascending by codepoint. Owned.
    codepoint_index: []const font_types.CodepointEntry,
    /// Sparse GPOS kern pairs; empty when the face has none. Owned.
    kerning: []const font_types.KernPair,

    /// Pixel size the tables were baked at; advances scale by
    /// `size_px / pixel_height` at draw time.
    pixel_height: f32,
    ascent: f32,
    descent: f32, // negative (below baseline)
    line_gap: f32,
    line_height: f32,

    /// Glyph index for `codepoint` via binary search, or null if unbaked.
    pub fn glyphIndex(self: *const BakedUiFont, codepoint: u21) ?u32 {
        var lo: usize = 0;
        var hi: usize = self.codepoint_index.len;
        const key: u32 = codepoint;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = self.codepoint_index[mid].codepoint;
            if (c == key) return self.codepoint_index[mid].glyph_index;
            if (c < key) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Kern adjustment (baked px) between `left` then `right`; 0 when the
    /// pair is not in the table. Mirrors `ui_kit.font.FontMetrics.bakedKern`.
    pub fn kern(self: *const BakedUiFont, left: u21, right: u21) f32 {
        for (self.kerning) |k| {
            if (k.first == @as(u32, left) and k.second == @as(u32, right)) return k.advance;
        }
        return 0;
    }

    pub fn deinit(self: *BakedUiFont, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.codepoint_index);
        allocator.free(self.kerning);
        allocator.free(self.atlas_rgba);
    }
};

/// Name → baked font. Unmanaged (allocator passed per call) so the Game
/// field default-initialises. Keys are duped/owned.
pub const UiFontStore = struct {
    fonts: std.StringHashMapUnmanaged(BakedUiFont) = .empty,

    pub const empty: UiFontStore = .{};

    /// Insert (or replace) a baked font under `name`. Takes ownership of
    /// the font's table slices; dupes the name. On replace the previous
    /// tables are freed — the previous *texture* is not (the renderer owns
    /// GPU teardown; see `bakeUiFont` docs).
    pub fn put(
        self: *UiFontStore,
        allocator: std.mem.Allocator,
        name: []const u8,
        font: BakedUiFont,
    ) !void {
        const gop = try self.fonts.getOrPut(allocator, name);
        if (gop.found_existing) {
            gop.value_ptr.deinit(allocator);
        } else {
            const owned_name = allocator.dupe(u8, name) catch |err| {
                _ = self.fonts.remove(name);
                return err;
            };
            gop.key_ptr.* = owned_name;
        }
        gop.value_ptr.* = font;
    }

    pub fn get(self: *const UiFontStore, name: []const u8) ?*const BakedUiFont {
        return self.fonts.getPtr(name);
    }

    pub fn count(self: *const UiFontStore) usize {
        return self.fonts.count();
    }

    pub fn deinit(self: *UiFontStore, allocator: std.mem.Allocator) void {
        var it = self.fonts.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.fonts.deinit(allocator);
    }
};

// ─── Frame resolution (the kit's FrameResolver, engine side) ───────────────

/// An atlas sprite frame resolved for the UI kit: everything the game-side
/// glue needs to (a) answer the kit's `FrameResolver` (`uv` + `frame_px`)
/// and (b) fill `UiRenderOptions` (`texture_id` + atlas dims) for the draw.
/// Produced by `game.resolveUiFrame(name)` from the loaded atlas data.
pub const ResolvedUiFrame = struct {
    /// Normalised UV sub-rect of the frame inside its atlas texture.
    uv: UiUvRect,
    /// Source frame size in (logical) pixels — what the kit needs to map a
    /// panel's pixel border into UV space for the 9-slice.
    frame_w: f32,
    frame_h: f32,
    /// Renderer texture id of the atlas the frame lives in.
    texture_id: u32,
    /// Pixel dims of that atlas texture.
    atlas_width: f32,
    atlas_height: f32,
};

// ─── Render options ────────────────────────────────────────────────────────

/// Per-submission context the DrawList itself does not carry.
pub const UiRenderOptions = struct {
    /// Renderer texture id of the theme atlas every `textured_quad`'s UV
    /// rect indexes into (the kit's FrameResolver resolved against ONE
    /// host-known atlas). `null` = unknown → textured quads are skipped.
    /// Optional (not a `0` sentinel): `0` is a VALID texture handle on some
    /// backends (bgfx can bind an atlas at handle 0), so treating it as
    /// "missing" would drop every themed quad — see #771 review.
    atlas_texture: ?u32 = null,
    /// Pixel dims of that atlas texture — needed to turn the kit's
    /// normalised UVs into the pixel-space source rects the backend's
    /// `drawTexturePro` takes. `0` → textured quads are skipped.
    atlas_width: f32 = 0,
    atlas_height: f32 = 0,
    /// Store name used when a `text_line.font_name` is empty (the kit's
    /// "default font"). Empty + empty name → the line is skipped.
    default_font: []const u8 = "",
    /// Focus-ring styling for `focus_highlight` commands.
    focus_color: UiRgba8 = .{ .r = 255, .g = 200, .b = 60, .a = 255 },
    focus_thickness: f32 = 2,
};

// ─── The renderer loop ─────────────────────────────────────────────────────

/// Walk `cmds` in order (painter's order — the kit emits parents first) and
/// issue draw calls on `sink`. `sink` is any type providing:
///
///   fn drawTexturedQuad(sink, texture_id: u32, src_px: UiRect, dst: UiRect, tint: UiRgba8) void
///   fn drawSolidRect(sink, dst: UiRect, color: UiRgba8) void
///
/// (`src_px` is in texture pixels, matching the backend `drawTexturePro`
/// source-rect convention.) The Game mixin adapts the renderer's screen-quad
/// primitives to this sink; tests record calls.
///
/// Unresolvable work degrades, never errors: quads without a known atlas
/// and text without a baked font are skipped — mirroring the kit's own
/// "mis-authored themes stay visible, not fatal" stance.
pub fn renderCommands(
    sink: anytype,
    fonts: *const UiFontStore,
    cmds: []const UiDrawCmd,
    opts: UiRenderOptions,
) void {
    for (cmds) |cmd| switch (cmd) {
        .textured_quad => |q| {
            const tex = opts.atlas_texture orelse continue;
            if (opts.atlas_width <= 0 or opts.atlas_height <= 0) continue;
            const src: UiRect = .{
                .x = q.uv.u0 * opts.atlas_width,
                .y = q.uv.v0 * opts.atlas_height,
                .w = (q.uv.u1 - q.uv.u0) * opts.atlas_width,
                .h = (q.uv.v1 - q.uv.v0) * opts.atlas_height,
            };
            sink.drawTexturedQuad(tex, src, q.dst, q.tint);
        },
        .solid_quad => |q| sink.drawSolidRect(q.dst, q.color),
        .text_line => |line| drawTextLine(sink, fonts, line, opts),
        .focus_rect => |f| drawFocusRing(sink, f.rect, opts),
    };
}

fn drawTextLine(
    sink: anytype,
    fonts: *const UiFontStore,
    line: anytype,
    opts: UiRenderOptions,
) void {
    const name = if (line.font_name.len > 0) line.font_name else opts.default_font;
    if (name.len == 0) return;
    const font = fonts.get(name) orelse return;

    const scale: f32 = if (font.pixel_height > 0) line.size_px / font.pixel_height else 1.0;
    // The kit hands `dst.y` as the line's TOP; glyph rects hang off the
    // baseline (stbtt `yoff` is negative-up from it).
    const baseline_y = line.dst.y + font.ascent * scale;

    const view = std.unicode.Utf8View.init(line.content) catch return;
    var it = view.iterator();
    var pen_x = line.dst.x;
    var prev: ?u21 = null;
    while (it.nextCodepoint()) |cp| {
        // Pen walk mirrors `ui_kit.text.measure`: kern between the pair,
        // then the glyph's advance; unbaked codepoints advance 0.
        if (prev) |p| pen_x += font.kern(p, cp) * scale;
        prev = cp;
        const gi = font.glyphIndex(cp) orelse continue;
        if (gi >= font.glyphs.len) continue;
        const g = font.glyphs[gi];
        // Guard corrupt glyph metrics: a malformed font with `u1 < u0` or
        // `v1 < v0` would underflow the unsigned subtraction and panic in
        // Debug/ReleaseSafe. Skip the degenerate glyph — the pen still
        // advances below so the rest of the line stays aligned.
        if (g.u1 < g.u0 or g.v1 < g.v0) {
            pen_x += g.advance * scale;
            continue;
        }
        const gw: f32 = @floatFromInt(@as(u32, g.u1) - @as(u32, g.u0));
        const gh: f32 = @floatFromInt(@as(u32, g.v1) - @as(u32, g.v0));
        if (gw > 0 and gh > 0) {
            sink.drawTexturedQuad(font.texture_id, .{
                .x = @floatFromInt(g.u0),
                .y = @floatFromInt(g.v0),
                .w = gw,
                .h = gh,
            }, .{
                .x = pen_x + g.xoff * scale,
                .y = baseline_y + g.yoff * scale,
                .w = gw * scale,
                .h = gh * scale,
            }, line.color);
        }
        pen_x += g.advance * scale;
    }
}

fn drawFocusRing(sink: anytype, rect: UiRect, opts: UiRenderOptions) void {
    const t = opts.focus_thickness;
    if (t <= 0 or rect.w <= 0 or rect.h <= 0) return;
    const c = opts.focus_color;
    // Four edge strips drawn OUTSIDE the rect — `drawRectangleLinesEx` is an
    // optional backend decl, four solid rects are universal.
    sink.drawSolidRect(.{ .x = rect.x - t, .y = rect.y - t, .w = rect.w + 2 * t, .h = t }, c);
    sink.drawSolidRect(.{ .x = rect.x - t, .y = rect.y + rect.h, .w = rect.w + 2 * t, .h = t }, c);
    sink.drawSolidRect(.{ .x = rect.x - t, .y = rect.y, .w = t, .h = rect.h }, c);
    sink.drawSolidRect(.{ .x = rect.x + rect.w, .y = rect.y, .w = t, .h = rect.h }, c);
}
