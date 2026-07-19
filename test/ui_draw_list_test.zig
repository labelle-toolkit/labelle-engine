//! In-game UI-kit DrawList renderer loop + font pipeline (issue #771).
//!
//! Three layers, all headless:
//!   1. `ui_draw_list.renderCommands` against a recording sink — proves
//!      textured_quad UV→pixel-src mapping, solid_quad passthrough, the
//!      text_line glyph walk (kern + per-glyph advance + size scaling +
//!      baseline placement), and focus_rect → four edge strips.
//!   2. `convertUiDrawCommand` — a kit-shaped `DrawCmd` union converts +
//!      quantises correctly, and unknown tags are dropped.
//!   3. Full Game integration: a recording renderer with the screen-quad
//!      seam + a mock FontBackend. `bakeUiFont` rasterises through the
//!      backend and retains tables; `submitUiDrawList` + `render()` draw
//!      the commands in painter order after the world pass.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");
const font_loader = engine.FontLoader;

const UiDrawCmd = engine.UiDrawCmd;
const UiRect = engine.UiRect;
const UiRgba8 = engine.UiRgba8;
const UiFontStore = engine.UiFontStore;
const BakedUiFont = engine.BakedUiFont;
const UiRenderOptions = engine.UiRenderOptions;

// ─── A recording sink for the pure renderer loop ───────────────────────────

const TexCall = struct { tex: u32, src: UiRect, dst: UiRect, tint: UiRgba8 };
const RectCall = struct { dst: UiRect, color: UiRgba8 };

const RecordingSink = struct {
    tex: *std.ArrayListUnmanaged(TexCall),
    rect: *std.ArrayListUnmanaged(RectCall),
    alloc: std.mem.Allocator,

    pub fn drawTexturedQuad(self: RecordingSink, tex: u32, src: UiRect, dst: UiRect, tint: UiRgba8) void {
        self.tex.append(self.alloc, .{ .tex = tex, .src = src, .dst = dst, .tint = tint }) catch {};
    }
    pub fn drawSolidRect(self: RecordingSink, dst: UiRect, color: UiRgba8) void {
        self.rect.append(self.alloc, .{ .dst = dst, .color = color }) catch {};
    }
};

// A 10px-baked proportional fixture: 'i' advance 4, 'W' advance 12, with a
// W→i kern of -3. Glyph pixel rects are non-degenerate so they draw.
fn fixtureFont() BakedUiFont {
    // NOTE: these three slices are `const` fixtures — the Game-owned store
    // frees its tables, but here we build the store manually and never
    // deinit it, so static slices are fine (no alloc to leak).
    const glyphs = &[_]engine.Glyph{
        .{ .u0 = 0, .v0 = 0, .u1 = 4, .v1 = 10, .xoff = 0, .yoff = -8, .advance = 4 }, // 'i'
        .{ .u0 = 4, .v0 = 0, .u1 = 16, .v1 = 10, .xoff = 0, .yoff = -8, .advance = 12 }, // 'W'
    };
    const cps = &[_]engine.CodepointEntry{
        .{ .codepoint = 'W', .glyph_index = 1 },
        .{ .codepoint = 'i', .glyph_index = 0 },
    };
    const kern = &[_]engine.KernPair{
        .{ .first = 'W', .second = 'i', .advance = -3 },
    };
    return .{
        .texture_id = 99,
        .atlas_width = 16,
        .atlas_height = 10,
        .glyphs = @constCast(glyphs),
        .codepoint_index = cps,
        .kerning = kern,
        .pixel_height = 10,
        .ascent = 8,
        .descent = -2,
        .line_gap = 0,
        .line_height = 10,
    };
}

test "textured_quad maps normalised UV to pixel source rect against the atlas" {
    var tex: std.ArrayListUnmanaged(TexCall) = .empty;
    var rect: std.ArrayListUnmanaged(RectCall) = .empty;
    defer tex.deinit(testing.allocator);
    defer rect.deinit(testing.allocator);
    var fonts: UiFontStore = .empty;

    const cmds = [_]UiDrawCmd{
        .{ .textured_quad = .{
            .dst = .{ .x = 100, .y = 50, .w = 64, .h = 64 },
            .uv = .{ .u0 = 0.25, .v0 = 0.5, .u1 = 0.75, .v1 = 1.0 },
            .tint = .{ .r = 200, .g = 100, .b = 50, .a = 255 },
        } },
    };
    engine.renderUiCommands(
        RecordingSink{ .tex = &tex, .rect = &rect, .alloc = testing.allocator },
        &fonts,
        &cmds,
        .{ .atlas_texture = 7, .atlas_width = 256, .atlas_height = 128 },
    );

    try testing.expectEqual(@as(usize, 1), tex.items.len);
    const c = tex.items[0];
    try testing.expectEqual(@as(u32, 7), c.tex);
    // src = uv * atlas dims: x=0.25*256=64, y=0.5*128=64, w=0.5*256=128, h=0.5*128=64
    try testing.expectApproxEqAbs(@as(f32, 64), c.src.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 64), c.src.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 128), c.src.w, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 64), c.src.h, 0.001);
    // dst passes through unchanged.
    try testing.expectApproxEqAbs(@as(f32, 100), c.dst.x, 0.001);
    try testing.expectEqual(@as(u8, 200), c.tint.r);
}

test "textured_quad without a known atlas is skipped (degrade, not crash)" {
    var tex: std.ArrayListUnmanaged(TexCall) = .empty;
    var rect: std.ArrayListUnmanaged(RectCall) = .empty;
    defer tex.deinit(testing.allocator);
    defer rect.deinit(testing.allocator);
    var fonts: UiFontStore = .empty;
    const cmds = [_]UiDrawCmd{
        .{ .textured_quad = .{ .dst = .{ .w = 10, .h = 10 }, .uv = .{}, .tint = .{} } },
    };
    // atlas_texture defaults to 0 → unknown.
    engine.renderUiCommands(RecordingSink{ .tex = &tex, .rect = &rect, .alloc = testing.allocator }, &fonts, &cmds, .{});
    try testing.expectEqual(@as(usize, 0), tex.items.len);
}

test "solid_quad forwards dst + color verbatim" {
    var tex: std.ArrayListUnmanaged(TexCall) = .empty;
    var rect: std.ArrayListUnmanaged(RectCall) = .empty;
    defer tex.deinit(testing.allocator);
    defer rect.deinit(testing.allocator);
    var fonts: UiFontStore = .empty;
    const cmds = [_]UiDrawCmd{
        .{ .solid_quad = .{ .dst = .{ .x = 5, .y = 6, .w = 7, .h = 8 }, .color = .{ .r = 1, .g = 2, .b = 3, .a = 4 } } },
    };
    engine.renderUiCommands(RecordingSink{ .tex = &tex, .rect = &rect, .alloc = testing.allocator }, &fonts, &cmds, .{});
    try testing.expectEqual(@as(usize, 1), rect.items.len);
    try testing.expectEqual(@as(f32, 7), rect.items[0].dst.w);
    try testing.expectEqual(@as(u8, 3), rect.items[0].color.b);
}

test "text_line walks glyphs with kerning, advance, scale, and baseline" {
    var tex: std.ArrayListUnmanaged(TexCall) = .empty;
    var rect: std.ArrayListUnmanaged(RectCall) = .empty;
    defer tex.deinit(testing.allocator);
    defer rect.deinit(testing.allocator);

    var fonts: UiFontStore = .empty;
    // Manually seed the store (no alloc — static fixture tables).
    try fonts.fonts.put(testing.allocator, "ui", fixtureFont());
    defer fonts.fonts.deinit(testing.allocator);

    // "Wi" at size 20 (2× the baked 10px). Baseline = dst.y + ascent*scale
    // = 30 + 8*2 = 46. First glyph 'W' at pen 100; second 'i' pen =
    // 100 + advance(W)*2 + kern(W,i)*2 = 100 + 24 - 6 = 118.
    const cmds = [_]UiDrawCmd{
        .{ .text_line = .{
            .dst = .{ .x = 100, .y = 30, .w = 200, .h = 20 },
            .content = "Wi",
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .size_px = 20,
            .font_name = "ui",
        } },
    };
    engine.renderUiCommands(RecordingSink{ .tex = &tex, .rect = &rect, .alloc = testing.allocator }, &fonts, &cmds, .{});

    try testing.expectEqual(@as(usize, 2), tex.items.len);
    // Both glyphs sample the FONT atlas texture (99), not the theme atlas.
    try testing.expectEqual(@as(u32, 99), tex.items[0].tex);
    // 'W' src rect = its atlas pixel rect (4,0)-(16,10) → x=4 w=12 h=10.
    try testing.expectApproxEqAbs(@as(f32, 4), tex.items[0].src.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 12), tex.items[0].src.w, 0.001);
    // 'W' dst: pen 100 + xoff(0), baseline 46 + yoff(-8)*2 = 30; scaled size 12*2=24 wide.
    try testing.expectApproxEqAbs(@as(f32, 100), tex.items[0].dst.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30), tex.items[0].dst.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 24), tex.items[0].dst.w, 0.001);
    // 'i' dst.x = 118 (advance + kern applied).
    try testing.expectApproxEqAbs(@as(f32, 118), tex.items[1].dst.x, 0.001);
}

test "text_line falls back to the default font when its font_name is empty" {
    var tex: std.ArrayListUnmanaged(TexCall) = .empty;
    var rect: std.ArrayListUnmanaged(RectCall) = .empty;
    defer tex.deinit(testing.allocator);
    defer rect.deinit(testing.allocator);
    var fonts: UiFontStore = .empty;
    try fonts.fonts.put(testing.allocator, "ui", fixtureFont());
    defer fonts.fonts.deinit(testing.allocator);

    const cmds = [_]UiDrawCmd{
        .{ .text_line = .{ .dst = .{ .x = 0, .y = 0, .w = 50, .h = 10 }, .content = "i", .color = .{}, .size_px = 10, .font_name = "" } },
    };
    // default_font resolves the empty name.
    engine.renderUiCommands(RecordingSink{ .tex = &tex, .rect = &rect, .alloc = testing.allocator }, &fonts, &cmds, .{ .default_font = "ui" });
    try testing.expectEqual(@as(usize, 1), tex.items.len);

    // With no default font, the line is skipped.
    tex.clearRetainingCapacity();
    engine.renderUiCommands(RecordingSink{ .tex = &tex, .rect = &rect, .alloc = testing.allocator }, &fonts, &cmds, .{});
    try testing.expectEqual(@as(usize, 0), tex.items.len);
}

test "focus_rect emits four edge strips around the rect" {
    var tex: std.ArrayListUnmanaged(TexCall) = .empty;
    var rect: std.ArrayListUnmanaged(RectCall) = .empty;
    defer tex.deinit(testing.allocator);
    defer rect.deinit(testing.allocator);
    var fonts: UiFontStore = .empty;
    const cmds = [_]UiDrawCmd{
        .{ .focus_rect = .{ .rect = .{ .x = 50, .y = 50, .w = 40, .h = 20 } } },
    };
    engine.renderUiCommands(RecordingSink{ .tex = &tex, .rect = &rect, .alloc = testing.allocator }, &fonts, &cmds, .{ .focus_thickness = 2 });
    try testing.expectEqual(@as(usize, 4), rect.items.len);
}

// ─── convertUiDrawCommand ──────────────────────────────────────────────────

// A kit-shaped DrawCmd: structurally identical tag names + payload fields to
// labelle-gui `ui_kit.render.DrawCmd`, so `convertUiDrawCommand` accepts it.
const KitColor = struct { r: f32, g: f32, b: f32, a: f32 };
const KitRect = struct { x: f32, y: f32, w: f32, h: f32 };
const KitUv = struct { u0: f32, v0: f32, u1: f32, v1: f32 };
const KitDrawCmd = union(enum) {
    textured_quad: struct { dst: KitRect, uv: KitUv, tint: KitColor },
    solid_quad: struct { dst: KitRect, color: KitColor },
    text_line: struct { dst: KitRect, content: []const u8, color: KitColor, size_px: f32, font_name: []const u8 },
    focus_highlight: struct { id: u32, rect: KitRect },
};

test "convertUiDrawCommand quantises f32 colors and maps every known tag" {
    const solid = engine.convertUiDrawCommand(KitDrawCmd{
        .solid_quad = .{ .dst = .{ .x = 1, .y = 2, .w = 3, .h = 4 }, .color = .{ .r = 1.0, .g = 0.5, .b = 0.0, .a = 1.0 } },
    }).?;
    try testing.expect(solid == .solid_quad);
    try testing.expectEqual(@as(u8, 255), solid.solid_quad.color.r);
    try testing.expectEqual(@as(u8, 128), solid.solid_quad.color.g); // round(0.5*255)=128
    try testing.expectEqual(@as(u8, 0), solid.solid_quad.color.b);

    const focus = engine.convertUiDrawCommand(KitDrawCmd{ .focus_highlight = .{ .id = 5, .rect = .{ .x = 0, .y = 0, .w = 9, .h = 9 } } }).?;
    try testing.expect(focus == .focus_rect);

    const text = engine.convertUiDrawCommand(KitDrawCmd{
        .text_line = .{ .dst = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .content = "hi", .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 }, .size_px = 12, .font_name = "f" },
    }).?;
    try testing.expectEqualStrings("hi", text.text_line.content);
}

test "convertUiDrawCommand returns null for unknown tags" {
    const Unknown = union(enum) { mystery: struct { x: f32 } };
    try testing.expect(engine.convertUiDrawCommand(Unknown{ .mystery = .{ .x = 1 } }) == null);
}

// ─── Full Game integration ─────────────────────────────────────────────────

fn RecordingRender(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            shape: union(enum) { rectangle: struct { width: f32 = 10, height: f32 = 10 } } = .{ .rectangle = .{} },
            color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        render_count: usize = 0,
        tex_calls: std.ArrayListUnmanaged(TexCall) = .empty,
        rect_calls: std.ArrayListUnmanaged(RectCall) = .empty,
        /// True when a screen draw landed after render() — proves UI is in
        /// the render phase, over the world.
        first_ui_after_render: ?bool = null,
        next_texture: u32 = 1000,
        alloc: std.mem.Allocator = undefined,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .alloc = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.tex_calls.deinit(self.alloc);
            self.rect_calls.deinit(self.alloc);
        }

        pub fn trackEntity(_: *Self, _: Entity, _: core.render.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(_: *Self, _: Entity) void {}
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.gizmos.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
        pub fn render(self: *Self) void {
            self.render_count += 1;
        }
        pub fn clear(self: *Self) void {
            self.render_count = 0;
        }

        // ── The #771 screen-space seam ──
        pub fn createTextureFromPixels(self: *Self, w: u32, h: u32, pixels: []const u8) !u32 {
            std.debug.assert(pixels.len == @as(usize, w) * @as(usize, h) * 4);
            const id = self.next_texture;
            self.next_texture += 1;
            return id;
        }
        pub fn drawScreenTexture(
            self: *Self,
            tex: u32,
            sx: f32,
            sy: f32,
            sw: f32,
            sh: f32,
            dx: f32,
            dy: f32,
            dw: f32,
            dh: f32,
            r: u8,
            g: u8,
            b: u8,
            a: u8,
        ) void {
            if (self.first_ui_after_render == null) self.first_ui_after_render = self.render_count > 0;
            self.tex_calls.append(self.alloc, .{
                .tex = tex,
                .src = .{ .x = sx, .y = sy, .w = sw, .h = sh },
                .dst = .{ .x = dx, .y = dy, .w = dw, .h = dh },
                .tint = .{ .r = r, .g = g, .b = b, .a = a },
            }) catch {};
        }
        pub fn drawScreenRect(self: *Self, dx: f32, dy: f32, dw: f32, dh: f32, r: u8, g: u8, b: u8, a: u8) void {
            if (self.first_ui_after_render == null) self.first_ui_after_render = self.render_count > 0;
            self.rect_calls.append(self.alloc, .{
                .dst = .{ .x = dx, .y = dy, .w = dw, .h = dh },
                .color = .{ .r = r, .g = g, .b = b, .a = a },
            }) catch {};
        }
    };
}

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

fn RecordingGame() type {
    return engine.GameConfig(
        RecordingRender(u32),
        engine.MockEcsBackend(u32),
        engine.StubInput,
        engine.StubAudio,
        engine.StubVideo,
        engine.StubGui,
        void,
        engine.StubLogSink,
        EmptyComponents,
        &.{},
        void,
    );
}

// Mock font backend: bakes a 2×2 alpha atlas + a 1-glyph 'A' table, all
// allocator-owned (so the GPA catches leaks / double-frees).
const MockFontBackend = struct {
    fn decode(file_type: [:0]const u8, data: []const u8, params: font_loader.FontBakeParams, allocator: std.mem.Allocator) anyerror!engine.DecodedFont {
        _ = file_type;
        _ = data;
        _ = params;
        const bitmap = try allocator.alloc(u8, 4);
        @memset(bitmap, 0xAA);
        const glyphs = try allocator.alloc(engine.Glyph, 1);
        glyphs[0] = .{ .u0 = 0, .v0 = 0, .u1 = 2, .v1 = 2, .xoff = 0, .yoff = -2, .advance = 3 };
        const cps = try allocator.alloc(engine.CodepointEntry, 1);
        cps[0] = .{ .codepoint = 'A', .glyph_index = 0 };
        const kern = try allocator.alloc(engine.KernPair, 0);
        return .{
            .bitmap = bitmap,
            .width = 2,
            .height = 2,
            .glyphs = glyphs,
            .codepoint_index = cps,
            .ascent = 2,
            .descent = 0,
            .line_gap = 0,
            .line_height = 2,
            .kerning = kern,
        };
    }
    // upload/unload are unused by bakeUiFont (it uploads through the
    // renderer directly) but the FontBackend struct requires them.
    fn upload(_: engine.DecodedFont) anyerror!engine.FontId {
        return engine.FontId.invalid;
    }
    fn unload(_: engine.FontId) void {}

    const backend: font_loader.FontBackend = .{ .decode = decode, .upload = upload, .unload = unload };
};

test "bakeUiFont rasterises through the backend and retains glyph tables" {
    const RGame = RecordingGame();
    var game = RGame.init(testing.allocator);
    defer game.deinit();

    font_loader.setBackend(MockFontBackend.backend);
    defer font_loader.clearBackend();

    try game.bakeUiFont("body", "ttf", "fake-ttf-bytes", .{ .pixel_height = 16 });

    const f = game.uiFont("body").?;
    try testing.expectEqual(@as(usize, 1), f.glyphs.len);
    try testing.expectEqual(@as(f32, 16), f.pixel_height);
    try testing.expectEqual(@as(?u32, 0), f.glyphIndex('A'));
    try testing.expect(f.glyphIndex('Z') == null);
    // The renderer minted a texture id for the expanded RGBA atlas.
    try testing.expect(f.texture_id >= 1000);
}

test "multiple submits in one frame accumulate without leaking the default-font dupe" {
    const RGame = RecordingGame();
    var game = RGame.init(testing.allocator);
    defer game.deinit(); // GPA (testing.allocator) fails the test on any leak.

    const a = [_]KitDrawCmd{
        .{ .solid_quad = .{ .dst = .{ .x = 0, .y = 0, .w = 5, .h = 5 }, .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } } },
    };
    const b = [_]KitDrawCmd{
        .{ .solid_quad = .{ .dst = .{ .x = 5, .y = 5, .w = 5, .h = 5 }, .color = .{ .r = 0, .g = 1, .b = 0, .a = 1 } } },
    };
    // Two submits, each carrying an owned default_font dupe.
    game.submitUiDrawList(&a, .{ .default_font = "one" });
    game.submitUiDrawList(&b, .{ .default_font = "two" });
    game.render();
    // Both panels accumulated (submit order).
    try testing.expectEqual(@as(usize, 2), game.renderer.rect_calls.items.len);
}

test "submit + render draws the UI DrawList after the world pass, then drains" {
    const RGame = RecordingGame();
    var game = RGame.init(testing.allocator);
    defer game.deinit();

    font_loader.setBackend(MockFontBackend.backend);
    defer font_loader.clearBackend();
    try game.bakeUiFont("body", "ttf", "x", .{ .pixel_height = 2 });

    // A kit-shaped DrawList: a solid panel fallback, a focused button ring,
    // and a text line — the shapes `ui_kit.render.build` emits.
    const cmds = [_]KitDrawCmd{
        .{ .solid_quad = .{ .dst = .{ .x = 10, .y = 10, .w = 100, .h = 40 }, .color = .{ .r = 0.2, .g = 0.2, .b = 0.3, .a = 1 } } },
        .{ .text_line = .{ .dst = .{ .x = 20, .y = 15, .w = 80, .h = 10 }, .content = "A", .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 }, .size_px = 2, .font_name = "body" } },
        .{ .focus_highlight = .{ .id = 1, .rect = .{ .x = 10, .y = 10, .w = 100, .h = 40 } } },
    };
    game.submitUiDrawList(&cmds, .{ .default_font = "body" });

    // Mirror the generated frame: world pass, then the engine drains UI.
    game.render();

    const r = game.renderer;
    // Panel solid (1) + focus ring (4 strips) = 5 rect calls.
    try testing.expectEqual(@as(usize, 5), r.rect_calls.items.len);
    // One glyph ('A') textured.
    try testing.expectEqual(@as(usize, 1), r.tex_calls.items.len);
    // UI drew after the world render().
    try testing.expectEqual(@as(?bool, true), r.first_ui_after_render);
    // Drained: a second render() with no submit draws nothing new.
    r.rect_calls.clearRetainingCapacity();
    r.tex_calls.clearRetainingCapacity();
    game.render();
    try testing.expectEqual(@as(usize, 0), r.rect_calls.items.len);
    try testing.expectEqual(@as(usize, 0), r.tex_calls.items.len);
}
