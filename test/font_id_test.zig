//! `Game.fontId` and `Game.setTextFont` — the public name → `FontId`
//! bridge for declared `.font` resources (#842).
//!
//! Background: a game declares
//! `.{ .name = "ui", .font = "assets/Font.ttf", .font_params = … }`, the
//! assembler emits `loadFontFromMemory("ui", "ttf", @embedFile(…), &params)`,
//! and `TextVisual.font` is a `FontId`. But the only resolution in the repo
//! was `gui_mixin`'s PRIVATE `resolveLabelFont`, reachable from the GUI label
//! path and nowhere else — so `addText` from a script could only ever pass
//! `FontId.invalid`, and the whole resource kind was dead end to end. (No
//! project in the toolkit declares a `.font` at all, which is presumably why
//! nobody noticed.)
//!
//! What these tests actually prove, and why each one matters:
//! - `fontId` after `loadFontFromMemory` yields a VALID id (`isValid`), and it
//!   is the id the backend minted — not merely "non-null". A test that only
//!   asserted "null when absent" would pass with the feature entirely broken.
//! - a `Text` entity built through `addText(e, .{ .font = game.fontId(n).? })`
//!   carries that valid id — the end-to-end path the issue says is impossible
//!   today, exercised through a real `Game`, not a bare mock.
//! - the NOT-READY contract: `null` while a lazily registered font is still
//!   streaming, non-null after `loadFontIfNeeded` blocks it in. This is the
//!   documented pop-in behaviour, and it is the reason the accessor returns an
//!   optional rather than `FontId.invalid`.
//! - `null` for a name whose catalog entry holds a NON-font resource.
//!   `registerFontFromMemory` swallows `AssetAlreadyRegistered`, so a manifest
//!   that reuses a name lands here rather than at registration; coercing an
//!   image handle into a `FontId` would be a type pun.
//! - `setTextFont` swaps the component's font + marks the visual dirty exactly
//!   once, short-circuits on a repeat, and — unlike `setSpriteFrame` — leaves
//!   the component alone on an unresolved name, because a `Text` has no
//!   `font_name` field and no per-frame resolver to self-heal from.
//! - both guards compile away on a renderer with no `Text` at all and on one
//!   whose `Text` carries no `font` field.
//!
//! The GUI label path is not re-tested here: `gui_mixin` no longer has its own
//! lookup, it calls `self.fontId`, so these tests cover both callers. That
//! unification is the point — two copies of "name → FontId" is how #833's
//! duplicated wait loop got fixed in one copy only.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const MockEcs = core.MockEcsBackend(u32);

// ── Renderer with a font-carrying Text visual ─────────────────────────
//
// Stand-in for labelle-gfx's `TextVisual` (the real one lives outside this
// repo — the engine takes no gfx dependency and derives `Game.TextComp` from
// `RenderImpl.Text`). Only the `font: FontId` field is load-bearing here.

fn TextRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const Text = struct {
            content: []const u8 = "",
            font: engine.FontId = .invalid,
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        visual_dirty_count: usize = 0,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(self: *Self, _: Entity) void {
            self.visual_dirty_count += 1;
        }
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
    };
}

/// Same renderer with the `font` field removed — exercises the
/// `has_text_font` comptime guard on a `Text` that exists but predates the
/// font seam.
fn FontlessTextRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Text = struct {
            content: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        visual_dirty_count: usize = 0,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(self: *Self, _: Entity) void {
            self.visual_dirty_count += 1;
        }
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
    };
}

/// The shape labelle-gfx#349 ships: `Text.font` is gfx's OWN handle type,
/// `enum(u32) { invalid = 0, _ }`, NOT the engine's `{ index, generation }`
/// struct. Before engine#848 this renderer did not compile at all — the
/// `text.font = id` in `setTextFont` is a plain type error against it — which
/// is why `TextRenderer` above had to declare `font: engine.FontId` and why
/// the whole bug stayed invisible: every released gfx had no `font` field, so
/// `has_text_font` was false and the body was comptime-dead.
fn GfxTextRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        /// Byte-for-byte labelle-gfx's `types.FontId`.
        pub const FontId = enum(u32) {
            invalid = 0,
            _,

            pub fn from(id: u32) FontId {
                return @enumFromInt(id);
            }
            pub fn toInt(self: FontId) u32 {
                return @intFromEnum(self);
            }
        };

        pub const Sprite = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Text = struct {
            content: []const u8 = "",
            font: FontId = .invalid,
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        visual_dirty_count: usize = 0,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(self: *Self, _: Entity) void {
            self.visual_dirty_count += 1;
        }
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
    };
}

/// No `Text` decl at all, so `Game.TextComp == void` — the `StubRender`
/// shape. `has_text_font` must short-circuit on `Text != void` BEFORE the
/// `@hasField`, which would be a compile error on a non-struct.
fn TextlessRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        visual_dirty_count: usize = 0,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(self: *Self, _: Entity) void {
            self.visual_dirty_count += 1;
        }
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
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

fn GameFor(comptime Renderer: type) type {
    return engine.GameConfig(
        Renderer,
        MockEcs,
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

const TestGame = GameFor(TextRenderer(MockEcs.Entity));
const FontlessGame = GameFor(FontlessTextRenderer(MockEcs.Entity));
const TextlessGame = GameFor(TextlessRenderer(MockEcs.Entity));
const GfxRenderer = GfxTextRenderer(MockEcs.Entity);
const GfxGame = GameFor(GfxRenderer);
const GfxFontId = GfxRenderer.FontId;
const GfxText = GfxGame.TextComp;

const Text = TestGame.TextComp;

// ── Mock FontBackend ──────────────────────────────────────────────────
//
// The font loader's `backend` slot is a process-global; each test installs
// this and clears it on the way out (same pattern as
// `asset_streaming_shim_test.zig`). `uploadFn` hands back a DIFFERENT id per
// call so a font swap is observable — a backend that returned one sentinel
// would let a broken `setTextFont` pass the swap assertions.

const MockFont = struct {
    var next_index: u16 = 0;

    fn reset() void {
        next_index = 0;
    }

    fn decodeFn(
        _: [:0]const u8,
        _: []const u8,
        _: engine.FontBakeParams,
        allocator: std.mem.Allocator,
    ) anyerror!engine.DecodedFont {
        // 1×1 alpha atlas with a single ASCII-space glyph: the minimum
        // payload that satisfies the loader's slice-ownership contract.
        const bitmap = try allocator.alloc(u8, 1);
        bitmap[0] = 0xFF;
        const glyphs = try allocator.alloc(engine.Glyph, 1);
        glyphs[0] = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .xoff = 0, .yoff = 0, .advance = 8 };
        const idx = try allocator.alloc(engine.CodepointEntry, 1);
        idx[0] = .{ .codepoint = 0x20, .glyph_index = 0 };
        const kern = try allocator.alloc(engine.KernPair, 0);
        return .{
            .bitmap = bitmap,
            .width = 1,
            .height = 1,
            .glyphs = glyphs,
            .codepoint_index = idx,
            .ascent = 12,
            .descent = -4,
            .line_gap = 0,
            .line_height = 16,
            .kerning = kern,
        };
    }

    fn uploadFn(_: engine.DecodedFont) anyerror!engine.FontId {
        next_index += 1;
        // `generation` must be non-zero or `FontId.isValid` is false and the
        // handle is indistinguishable from `.invalid`.
        return .{ .index = next_index, .generation = 1 };
    }

    fn unloadFn(_: engine.FontId) void {}

    const backend: engine.FontBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

// ── Mock ImageBackend ─────────────────────────────────────────────────
//
// Only used by the wrong-kind test, which needs a catalog entry whose
// `resource` is populated with something that is NOT a font.

const MockImage = struct {
    fn decodeFn(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) anyerror!engine.DecodedImage {
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0x11);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }
    fn uploadFn(_: engine.DecodedImage) anyerror!engine.AssetTexture {
        return 900;
    }
    fn unloadFn(_: engine.AssetTexture) void {}

    const backend: engine.ImageBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

const fake_ttf: []const u8 = "fake-ttf-bytes";
const font_file_type: [:0]const u8 = "ttf";
const fake_png: []const u8 = "fake-png-bytes";
// Image `file_type` carries the leading dot; font/audio do not. See the
// convention note in `asset_streaming_shim_test.zig`.
const image_file_type: [:0]const u8 = ".png";

// ── fontId ────────────────────────────────────────────────────────────

test "fontId: an eagerly loaded font resolves to the backend's baked handle" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    // Exactly what the assembler emits for a `.font` resource declared
    // `lazy = false` in `project.labelle`.
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    const id = game.fontId("ui");
    try testing.expect(id != null);
    // The assertion the whole issue is about: a VALID id, not `.invalid`.
    try testing.expect(id.?.isValid());
    // ...and specifically the handle the backend minted, so this cannot pass
    // on a stub that fabricates a plausible-looking id.
    try testing.expectEqual(@as(u16, 1), id.?.index);
    try testing.expectEqual(@as(u16, 1), id.?.generation);
}

test "fontId: an unregistered name is null" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.fontId("never_declared") == null);
}

test "fontId: null while streaming, non-null after loadFontIfNeeded" {
    // The documented not-ready contract. A lazily declared font is REGISTERED
    // long before it is resident, and `fontId` must report that as `null`
    // rather than handing out a half-baked handle — which is why it returns
    // an optional instead of `FontId.invalid`. `loadFontIfNeeded` is the
    // blocking answer a load screen or setup script reaches for.
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 16 };
    try game.registerFontFromMemory("hud", font_file_type, fake_ttf, &params);

    // Registered, no decode in flight: the pop-in window a script sees on the
    // first frames of a lazy resource.
    try testing.expect(!game.assets.isReady("hud"));
    try testing.expect(game.fontId("hud") == null);

    _ = try game.loadFontIfNeeded("hud");

    try testing.expect(game.assets.isReady("hud"));
    const id = game.fontId("hud");
    try testing.expect(id != null);
    try testing.expect(id.?.isValid());
}

test "fontId: a name holding a non-font resource is null, never coerced" {
    engine.ImageLoader.setBackend(MockImage.backend);
    defer engine.ImageLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.loadImageFromMemory("panel", image_file_type, fake_png);
    try testing.expect(game.assets.isReady("panel"));

    // The entry is `.ready` with a populated `resource` — so a lookup that
    // checked only readiness would hand back a texture handle reinterpreted
    // as a `FontId`. The union tag is what makes this safe.
    try testing.expect(game.fontId("panel") == null);
}

// ── addText end to end ────────────────────────────────────────────────

test "addText: a Text entity carries the FontId resolved from a declared name" {
    // The exact flow the issue reports as impossible: declare a font, resolve
    // its name from a script, hand the id to `addText`, and have the entity
    // come back carrying a valid handle instead of `.invalid`.
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    const entity = game.createEntity();
    game.addText(entity, .{
        .content = "Seed: 42",
        .font = game.fontId("ui").?,
    });

    const text = game.getComponent(entity, Text).?;
    try testing.expect(text.font.isValid());
    try testing.expectEqual(game.fontId("ui").?, text.font);
}

// ── setTextFont ───────────────────────────────────────────────────────

test "setTextFont: stamps the resolved font and marks the visual dirty once" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    const entity = game.createEntity();
    // Starts at `.invalid` — the only value a script could reach before #842.
    game.addText(entity, .{ .content = "score" });
    try testing.expect(!game.getComponent(entity, Text).?.font.isValid());
    const dirty_before = game.renderer.visual_dirty_count;

    game.setTextFont(entity, "ui");

    const text = game.getComponent(entity, Text).?;
    try testing.expect(text.font.isValid());
    try testing.expectEqual(game.fontId("ui").?, text.font);
    // Forgetting the dirty-mark is the silent half of a hand-rolled swap:
    // the field updates and the renderer keeps drawing the old visual.
    try testing.expectEqual(dirty_before + 1, game.renderer.visual_dirty_count);
}

test "setTextFont: swapping between two declared fonts picks up the second handle" {
    // Two sizes of one face are two resources with two names and two ids —
    // the sizing story for text, in place of `setSpriteFrame`'s
    // `texture_scale`. A swap that silently kept the first handle would leave
    // the label rendering at the wrong bake.
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const small: engine.FontBakeParams = .{ .pixel_height = 12 };
    const large: engine.FontBakeParams = .{ .pixel_height = 48 };
    try game.loadFontFromMemory("ui_small", font_file_type, fake_ttf, &small);
    try game.loadFontFromMemory("ui_large", font_file_type, fake_ttf, &large);

    const small_id = game.fontId("ui_small").?;
    const large_id = game.fontId("ui_large").?;
    try testing.expect(!std.meta.eql(small_id, large_id));

    const entity = game.createEntity();
    game.addText(entity, .{ .content = "hp", .font = small_id });

    game.setTextFont(entity, "ui_large");
    try testing.expectEqual(large_id, game.getComponent(entity, Text).?.font);

    game.setTextFont(entity, "ui_small");
    try testing.expectEqual(small_id, game.getComponent(entity, Text).?.font);
}

test "setTextFont: re-setting the same font short-circuits the dirty-mark" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    const entity = game.createEntity();
    game.addText(entity, .{ .content = "score" });
    game.setTextFont(entity, "ui");
    const dirty_after_first = game.renderer.visual_dirty_count;

    game.setTextFont(entity, "ui");

    try testing.expectEqual(dirty_after_first, game.renderer.visual_dirty_count);
}

test "setTextFont: an unresolved name leaves the component alone and does not mark dirty" {
    // The documented asymmetry with `setSpriteFrame`, which DOES stamp the
    // name so `resolveAtlasSprites` can self-heal. A `Text` component has no
    // `font_name` field and no per-frame resolver, so there is nothing to
    // stamp and nothing would ever pick it up: the previous font must
    // survive, or a swap to a still-streaming font would blank the label.
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    const entity = game.createEntity();
    game.addText(entity, .{ .content = "score", .font = game.fontId("ui").? });
    const font_before = game.getComponent(entity, Text).?.font;
    const dirty_before = game.renderer.visual_dirty_count;

    game.setTextFont(entity, "never_declared");

    try testing.expectEqual(font_before, game.getComponent(entity, Text).?.font);
    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "setTextFont: entity without a Text component returns silently" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    const entity = game.createEntity();
    const dirty_before = game.renderer.visual_dirty_count;

    game.setTextFont(entity, "ui");

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "setTextFont: comptime no-op when Text carries no font field" {
    var game = FontlessGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addText(entity, .{ .content = "score" });
    const dirty_before = game.renderer.visual_dirty_count;

    // The point is the COMPILE: a renderer whose `Text` predates the font
    // seam must still be able to call this without a type error.
    game.setTextFont(entity, "ui");

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "setTextFont: comptime no-op when the renderer has no Text at all" {
    // `Game.TextComp == void` here (the `StubRender` shape). `@hasField` on a
    // non-struct is a compile error, so the guard must check `Text != void`
    // first — this test is what catches a regression that reorders it.
    var game = TextlessGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    const dirty_before = game.renderer.visual_dirty_count;

    game.setTextFont(entity, "ui");

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "fontId is available on a renderer with no Text component" {
    // The accessor lives on the ASSET mixin, not the visuals mixin: it is a
    // catalog lookup and must not be gated on the renderer shipping a text
    // visual. A game could reasonably want the id for its own UI kit.
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = TextlessGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    try testing.expect(game.fontId("ui").?.isValid());
}

// ── engine FontId → renderer handle bridge (engine#848) ───────────────
//
// Regression cover for the LATENT break gfx#349 arms: the engine mints a
// `{ index, generation }` struct, gfx's `TextComponent.font` is an
// `enum(u32)`, and `setTextFont` used to assign one straight to the other.
// It only ever compiled because no released gfx had the field.

test "setTextFont: works against a gfx-shaped enum(u32) Text.font" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = GfxGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    const entity = game.createEntity();
    game.addText(entity, .{ .content = "score" });
    try testing.expectEqual(GfxFontId.invalid, game.getComponent(entity, GfxText).?.font);
    const dirty_before = game.renderer.visual_dirty_count;

    game.setTextFont(entity, "ui");

    const id = game.fontId("ui").?;
    const stored = game.getComponent(entity, GfxText).?.font;
    try testing.expect(stored != GfxFontId.invalid);
    // The stored enum is the engine handle packed, and it decodes back to
    // exactly the id the backend minted — generation included.
    try testing.expectEqual(engine.packFontId(id), stored.toInt());
    try testing.expectEqual(id, engine.unpackFontId(stored.toInt()));
    try testing.expectEqual(dirty_before + 1, game.renderer.visual_dirty_count);
}

test "setTextFont: enum Text.font short-circuits on a repeat and swaps on a change" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = GfxGame.init(testing.allocator);
    defer game.deinit();

    const small: engine.FontBakeParams = .{ .pixel_height = 12 };
    const large: engine.FontBakeParams = .{ .pixel_height = 48 };
    try game.loadFontFromMemory("ui_small", font_file_type, fake_ttf, &small);
    try game.loadFontFromMemory("ui_large", font_file_type, fake_ttf, &large);

    const entity = game.createEntity();
    game.addText(entity, .{ .content = "hp" });

    game.setTextFont(entity, "ui_small");
    const after_first = game.renderer.visual_dirty_count;
    // The comparison now happens in the RENDERER's type; comparing the
    // engine struct against the enum is what used to be the type error.
    game.setTextFont(entity, "ui_small");
    try testing.expectEqual(after_first, game.renderer.visual_dirty_count);

    game.setTextFont(entity, "ui_large");
    try testing.expectEqual(after_first + 1, game.renderer.visual_dirty_count);
    try testing.expectEqual(
        game.fontId("ui_large").?,
        engine.unpackFontId(game.getComponent(entity, GfxText).?.font.toInt()),
    );
}

test "setTextFont: unresolved name leaves an enum Text.font alone" {
    MockFont.reset();
    engine.FontLoader.setBackend(MockFont.backend);
    defer engine.FontLoader.clearBackend();

    var game = GfxGame.init(testing.allocator);
    defer game.deinit();

    const params: engine.FontBakeParams = .{ .pixel_height = 24 };
    try game.loadFontFromMemory("ui", font_file_type, fake_ttf, &params);

    const entity = game.createEntity();
    game.addText(entity, .{ .content = "score" });
    game.setTextFont(entity, "ui");
    const before = game.getComponent(entity, GfxText).?.font;
    const dirty_before = game.renderer.visual_dirty_count;

    game.setTextFont(entity, "never_declared");

    try testing.expectEqual(before, game.getComponent(entity, GfxText).?.font);
    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "setTextFont: comptime no-op when the renderer ships no Text at all" {
    // `Text == void`, the `StubRender` shape. `has_text_font` must
    // short-circuit before `@FieldType(Text, \"font\")` is ever evaluated.
    var game = TextlessGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    const dirty_before = game.renderer.visual_dirty_count;

    game.setTextFont(entity, "ui");

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

// ── packFontId / normalizeFontHandle ──────────────────────────────────

test "packFontId: round-trips index AND generation, invalid maps to 0" {
    const id: engine.FontId = .{ .index = 517, .generation = 9 };
    const bits = engine.packFontId(id);
    // Index in the LOW half: a consumer keyed on the slot index (the
    // assembler's `FontBackendAdapter`) can truncate to `u16`.
    try testing.expectEqual(@as(u16, 517), @as(u16, @truncate(bits)));
    try testing.expectEqual(@as(u16, 9), @as(u16, @truncate(bits >> 16)));
    try testing.expectEqual(id, engine.unpackFontId(bits));

    // The two sentinels agree, so a default-constructed gfx `TextComponent`
    // and an engine `FontId.invalid` mean the same thing.
    try testing.expectEqual(@as(u32, 0), engine.packFontId(engine.FontId.invalid));
    try testing.expect(!engine.unpackFontId(0).isValid());
}

test "packFontId: generation is never dropped, so a stale handle stays detectable" {
    // Two handles for the same recycled SLOT differ only in generation.
    // Packing only the index would collapse them and defeat the whole point
    // of a generational handle.
    const first: engine.FontId = .{ .index = 3, .generation = 1 };
    const recycled: engine.FontId = .{ .index = 3, .generation = 2 };
    try testing.expect(engine.packFontId(first) != engine.packFontId(recycled));
}

test "normalizeFontHandle: engine struct -> gfx enum target" {
    const E = enum(u32) { invalid = 0, _ };
    const id: engine.FontId = .{ .index = 12, .generation = 3 };
    const out = engine.normalizeFontHandle(E, id);
    try testing.expectEqual(E, @TypeOf(out));
    try testing.expectEqual(id, engine.unpackFontId(@intFromEnum(out)));
}

test "normalizeFontHandle: engine struct target passes through untouched" {
    const id: engine.FontId = .{ .index = 12, .generation = 3 };
    try testing.expectEqual(id, engine.normalizeFontHandle(engine.FontId, id));
}

test "normalizeFontHandle: integer targets" {
    const id: engine.FontId = .{ .index = 12, .generation = 3 };
    // Wide enough for both halves: full packed value.
    try testing.expectEqual(engine.packFontId(id), engine.normalizeFontHandle(u32, id));
    try testing.expectEqual(@as(u64, engine.packFontId(id)), engine.normalizeFontHandle(u64, id));
    // Too narrow to hold a generation by construction — index only, and
    // explicitly, rather than an `@intCast` panic in a release-safe build.
    try testing.expectEqual(@as(u16, 12), engine.normalizeFontHandle(u16, id));
}
