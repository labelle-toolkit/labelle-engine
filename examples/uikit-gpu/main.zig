//! On-GPU UI-kit DrawList demo (labelle-engine#787, deliverable 1).
//!
//! This is the real-GPU render proof the headless #771 integration test could
//! not produce: a runnable sokol-desktop game that
//!
//!   1. builds a labelle-gui `ui_kit.Tree` (a 9-slice panel + two text lines
//!      + a focusable button with its own panel),
//!   2. runs `ui_kit.layout.apply` + `ui_kit.render.build` to walk it into a
//!      backend-agnostic `DrawList`,
//!   3. resolves panel frames through the engine's `game.resolveUiFrame`
//!      (wrapped in the kit's `render.FrameResolver`) and text fonts through a
//!      real `game.bakeUiFont` bake (wrapped in the kit's `render.FontResolver`
//!      via `ui_kit.font.FontMetrics`), and
//!   4. hands the list to `game.submitUiDrawList(list.items, opts)` — the exact
//!      #771 engine API — so `game.render()` composites it on the real GPU
//!      through the gfx screen-space primitives (`drawScreenTexture` /
//!      `drawScreenRect`, gfx #311).
//!
//! A `LABELLE_SCREENSHOT_PATH` capture of this shows: a 9-slice-bordered panel,
//! real rasterised text (Roboto via stb_truetype), and a focus ring around the
//! button — all drawn by the engine's UI-kit consumer on the GPU, not a mock
//! recording sink.
//!
//! NOTE: games can't yet declare a `ui_kit` dependency through the assembler
//! (see labelle-engine#787 §"blocker"); this example wires it by hand in
//! `build.zig`. The full assembler `ui_kit`-as-game-dep path + the editor
//! FrameResolver preview + the FP build-menu rebuild remain #787 follow-ups.

const std = @import("std");
const engine = @import("labelle-engine");
const gfx = @import("labelle-gfx");
const ui_kit = @import("ui_kit");

const BackendGfx = @import("backend_gfx");
const BackendInput = @import("backend_input");
const BackendAudio = @import("backend_audio");
const window = @import("backend_window");

// ── Engine game type (mirrors the assembler's generated wiring) ─────────────

const GameLayers = enum(u8) {
    background,
    world,
    ui,

    pub fn config(self: GameLayers) gfx.LayerConfig {
        return switch (self) {
            .background => .{ .order = 0, .space = .screen },
            .world => .{ .order = 1, .space = .world },
            .ui => .{ .order = 2, .space = .screen },
        };
    }
};

const EcsBackend = engine.MockEcsBackend(u32);
const Renderer = gfx.GfxRenderer(BackendGfx, GameLayers, EcsBackend.Entity);
const Components = engine.ComponentRegistry(.{});

const Game = engine.GameConfig(
    Renderer,
    EcsBackend,
    BackendInput,
    BackendAudio,
    engine.StubVideo,
    engine.StubGui,
    void, // hooks
    engine.core.StderrLogSink,
    Components,
    &.{}, // gizmo categories
    void, // game events
);

// ── Constants ───────────────────────────────────────────────────────────────

const screen_w: u32 = 800;
const screen_h: u32 = 600;
const screen_title = "LaBelle UI-kit — on-GPU DrawList demo (#787)";
const font_bytes = @embedFile("assets/Roboto-Medium.ttf");

// Procedural 9-slice theme atlas: a bordered panel frame.
const panel_dim: u32 = 64;
const panel_border: f32 = 12;

// ── Global state (C-calling-convention callbacks) ───────────────────────────

var gpa: std.heap.DebugAllocator(.{}) = .{};
var g: Game = undefined;
var tree: ui_kit.Tree = undefined;
var body_metrics: ui_kit.font.FontMetrics = undefined;
var root_id: ui_kit.ElementId = ui_kit.invalid_id;
var button_id: ui_kit.ElementId = ui_kit.invalid_id;
var panel_texture: u32 = 0;

var screenshot_req: ?engine.ScreenshotRequest = null;
var screenshot_start_ns: i128 = 0;
var screenshot_initialized: bool = false;

// ── Resolvers: the engine ⇄ kit binding seam ────────────────────────────────

/// Kit `FrameResolver` → engine `game.resolveUiFrame`. Maps the engine's
/// `ResolvedUiFrame` onto the kit's `ResolvedFrame { uv, frame_px }`.
fn resolveFrame(_: *const anyopaque, name: []const u8) ?ui_kit.render.ResolvedFrame {
    const rf = g.resolveUiFrame(name) orelse return null;
    return .{
        .uv = .{ .u0 = rf.uv.u0, .v0 = rf.uv.v0, .u1 = rf.uv.u1, .v1 = rf.uv.v1 },
        .frame_px = .{ .x = rf.frame_w, .y = rf.frame_h },
    };
}

/// Kit `FontResolver` → the engine's baked-font tables. The glyph/codepoint/
/// kern slices are `extern`-identical between labelle-core and the kit, so the
/// wrap is `@ptrCast` slices + four scalar copies (no per-glyph work).
fn resolveFont(_: *const anyopaque, name: []const u8) ?*const ui_kit.font.FontMetrics {
    if (!std.mem.eql(u8, name, "body")) return null;
    return &body_metrics;
}

fn metricsFromBaked(baked: *const engine.BakedUiFont) ui_kit.font.FontMetrics {
    return .{
        .glyphs = @ptrCast(baked.glyphs),
        .codepoint_index = @ptrCast(baked.codepoint_index),
        .kerning = @ptrCast(baked.kerning),
        .pixel_height = baked.pixel_height,
        .ascent = baked.ascent,
        .descent = baked.descent,
        .line_gap = baked.line_gap,
        .line_height = baked.line_height,
    };
}

// ── Theme atlas: a procedurally-drawn 9-slice panel frame ───────────────────

fn buildPanelTexture() !void {
    const alloc = gpa.allocator();
    const dim: usize = panel_dim;
    const pixels = try alloc.alloc(u8, dim * dim * 4);
    defer alloc.free(pixels);

    const b: usize = @intFromFloat(panel_border);
    var y: usize = 0;
    while (y < dim) : (y += 1) {
        var x: usize = 0;
        while (x < dim) : (x += 1) {
            const on_border = x < b or x >= dim - b or y < b or y >= dim - b;
            const i = (y * dim + x) * 4;
            if (on_border) {
                // Light-blue bevel border.
                pixels[i + 0] = 96;
                pixels[i + 1] = 132;
                pixels[i + 2] = 220;
                pixels[i + 3] = 255;
            } else {
                // Dark translucent interior.
                pixels[i + 0] = 26;
                pixels[i + 1] = 30;
                pixels[i + 2] = 44;
                pixels[i + 3] = 235;
            }
        }
    }

    panel_texture = try g.renderer.createTextureFromPixels(panel_dim, panel_dim, pixels);

    // Register it as a one-frame theme atlas so `resolveUiFrame("panel")`
    // returns UVs (0..1) + the bound texture id. Mirrors the catalog-atlas
    // path exercised in the #771 test.
    const mgr = g.getTextureManager();
    const atlas = try mgr.addAtlas("theme");
    atlas.texture_id = panel_texture;
    atlas.logical_width = panel_dim;
    atlas.logical_height = panel_dim;
    atlas.texture_scale_x = 1.0;
    atlas.texture_scale_y = 1.0;
    try atlas.addSprite("panel", .{ .x = 0, .y = 0, .width = panel_dim, .height = panel_dim });
}

// ── The UI-kit tree ─────────────────────────────────────────────────────────

fn buildTree() !void {
    const white: ui_kit.Color = .{ .r = 0.95, .g = 0.96, .b = 1.0, .a = 1.0 };
    const dim: ui_kit.Color = .{ .r = 0.72, .g = 0.78, .b = 0.92, .a = 1.0 };

    tree = ui_kit.Tree.init(gpa.allocator());

    root_id = try tree.add(ui_kit.invalid_id, .{
        .size = .{ .x = 420, .y = 260 },
        .anchor = .center,
        .panel = .{ .sprite_name = "panel", .border = ui_kit.Insets.uniform(panel_border) },
        .layout = .{
            .direction = .column,
            .gap = 18,
            .padding = ui_kit.Insets.uniform(28),
            .cross_align = .center,
        },
    });

    _ = try tree.add(root_id, .{
        .size = .{ .x = 360, .y = 40 },
        .text = .{
            .content = "LaBelle UI Kit",
            .size_px = 30,
            .color = white,
            .font_name = "body",
            .halign = .center,
            .wrap = false,
        },
    });

    _ = try tree.add(root_id, .{
        .size = .{ .x = 360, .y = 56 },
        .text = .{
            .content = "9-slice panel + rasterised text + focus ring, drawn on the GPU via game.submitUiDrawList.",
            .size_px = 15,
            .color = dim,
            .font_name = "body",
            .halign = .center,
            .wrap = true,
        },
    });

    button_id = try tree.add(root_id, .{
        .size = .{ .x = 200, .y = 56 },
        .focusable = true,
        .panel = .{ .sprite_name = "panel", .border = ui_kit.Insets.uniform(panel_border) },
        .button = .{ .action_id = "start" },
        .layout = .{ .direction = .column, .cross_align = .center, .padding = ui_kit.Insets.uniform(14) },
    });

    _ = try tree.add(button_id, .{
        .size = .{ .x = 160, .y = 26 },
        .text = .{
            .content = "Start",
            .size_px = 20,
            .color = white,
            .font_name = "body",
            .halign = .center,
            .wrap = false,
        },
    });
}

// ── Submit the kit's DrawList to the engine, every frame ────────────────────

fn submitUi() void {
    const alloc = gpa.allocator();

    ui_kit.layout.apply(&tree, root_id, .{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(screen_w),
        .h = @floatFromInt(screen_h),
    }) catch return;

    var list = ui_kit.render.build(alloc, &tree, .{
        .frames = .{ .context = undefined, .resolveFn = resolveFrame },
        .fonts = .{ .context = undefined, .resolveFn = resolveFont },
        .default_text_metrics = body_metrics.provider(),
        .focused = button_id, // draw the focus ring around the button
    }) catch return;
    defer list.deinit(alloc);

    g.submitUiDrawList(list.items, .{
        .atlas_texture = panel_texture,
        .atlas_width = @floatFromInt(panel_dim),
        .atlas_height = @floatFromInt(panel_dim),
        .default_font = "body",
        .focus_color = .{ .r = 255, .g = 210, .b = 70, .a = 255 },
        .focus_thickness = 3,
    });
}

// ── FontBackend seam: sokol's stb_truetype baker → engine font_loader ────────

/// Adapt the sokol backend's `decodeFont` (params-by-pointer) to the engine's
/// `FontBackend.decode` (params-by-value). Upload/unload are unused —
/// `bakeUiFont` uploads through the renderer's `createTextureFromPixels`.
fn fontDecode(
    file_type: [:0]const u8,
    data: []const u8,
    params: engine.FontBakeParams,
    allocator: std.mem.Allocator,
) anyerror!engine.DecodedFont {
    // The sokol backend's `FontBakeParams` is nominally distinct from the
    // engine's (the backend has no labelle-core/font_types dep of its own), so
    // rebuild it field-for-field. Ranges left default (ASCII printable).
    const bp: BackendGfx.FontBakeParams = .{
        .pixel_height = params.pixel_height,
        .atlas_width = params.atlas_width,
        .atlas_height = params.atlas_height,
    };
    const d = try BackendGfx.decodeFont(file_type, data, &bp, allocator);
    // The backend's `DecodedFont` is nominally distinct from the engine's, but
    // the glyph/codepoint/kern tables are the same `extern` layout on both
    // sides (labelle-core contract), so the slices reinterpret straight across.
    return .{
        .bitmap = d.bitmap,
        .width = d.width,
        .height = d.height,
        .glyphs = @ptrCast(d.glyphs),
        .codepoint_index = @ptrCast(d.codepoint_index),
        .kerning = @ptrCast(d.kerning),
        .ascent = d.ascent,
        .descent = d.descent,
        .line_gap = d.line_gap,
        .line_height = d.line_height,
    };
}
fn fontUpload(_: engine.DecodedFont) anyerror!engine.FontId {
    return engine.FontId.invalid;
}
fn fontUnload(_: engine.FontId) void {}

// ── sokol callbacks ─────────────────────────────────────────────────────────

fn initInner() !void {
    engine.FontLoader.setBackend(.{
        .decode = fontDecode,
        .upload = fontUpload,
        .unload = fontUnload,
    });

    try buildPanelTexture();

    try g.bakeUiFont("body", "ttf", font_bytes, .{
        .pixel_height = 32,
        .atlas_width = 512,
        .atlas_height = 512,
    });
    body_metrics = metricsFromBaked(g.uiFont("body").?);

    try buildTree();
}

export fn init() callconv(.c) void {
    window.initGfx();
    g = Game.init(gpa.allocator());
    g.setScreenHeight(@floatFromInt(screen_h));
    initInner() catch |err| {
        std.debug.print("uikit-gpu: init failed: {any}\n", .{err});
    };
}

export fn frame() callconv(.c) void {
    BackendGfx.setScreenSize(window.width(), window.height());
    BackendGfx.setDesignSize(@intCast(screen_w), @intCast(screen_h));

    // Submit the UI-kit DrawList for this frame, then let the engine draw it
    // (renderSubmittedUi runs inside g.render(), after the world pass).
    submitUi();

    const pass_action = window.beginFrame();
    window.beginPass(pass_action);
    g.render();
    window.flushScene();
    window.endFrame();

    // LABELLE_SCREENSHOT_PATH one-shot (same shape as the generated main).
    if (!screenshot_initialized) {
        screenshot_req = engine.requestedScreenshot();
        screenshot_start_ns = engine.nowNs();
        screenshot_initialized = true;
    }
    if (screenshot_req) |req| {
        const now_ns: i128 = engine.nowNs();
        const elapsed_sec: f32 = @as(f32, @floatFromInt(@as(i64, @intCast(now_ns - screenshot_start_ns)))) / 1_000_000_000.0;
        if (elapsed_sec >= req.after_sec) {
            window.takeScreenshot(req.path);
            screenshot_req = null;
            window.requestQuit();
        }
    }

    BackendInput.newFrame();
}

fn sokolEvent(ev: [*c]const BackendInput.Event) callconv(.c) void {
    BackendInput.handleEvent(ev);
}

export fn cleanup() callconv(.c) void {
    tree.deinit();
    g.deinit();
    window.shutdownGfx();
    _ = gpa.deinit();
}

pub fn main() void {
    window.run(.{
        .init_cb = &init,
        .frame_cb = &frame,
        .cleanup_cb = &cleanup,
        .event_cb = &sokolEvent,
        .w = screen_w,
        .h = screen_h,
        .title = screen_title,
    });
}
