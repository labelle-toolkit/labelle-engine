//! UI-kit mixin — the Game methods behind the DrawList renderer loop
//! (issue #771; see `src/ui_draw_list.zig` for the contract rationale).
//!
//! Frame shape (mirrors how gizmos work):
//!
//!   1. During update, game code builds/updates its `ui_kit` tree, runs the
//!      kit's `render.build(...)`, and calls
//!      `game.submitUiDrawList(list.items, opts)`. The engine converts +
//!      retains the commands (text slices are duped, so the source list may
//!      be freed immediately after submit).
//!   2. `render()` (loop_mixin) draws the retained commands AFTER the world
//!      sprite pass + particles and BEFORE gizmos — UI composites over the
//!      world, debug overlays stay on top — then clears them. Submitting is
//!      per-frame: nothing submitted → nothing drawn.
//!
//! Drawing goes through two labelle-gfx screen-space primitives —
//! `drawScreenTexture` / `drawScreenRect` — both thin forwarders over the
//! *required* backend-contract decls `drawTexturePro` / `drawRectangleRec`,
//! so the path is backend-agnostic by construction. Both are `@hasDecl`
//! gated here: on an older gfx (or the stub renderer) submit/draw are
//! silent no-ops, same stance as `drawMesh`.
//!
//! Font pipeline (`bakeUiFont`): TTF/OTF bytes → the injected
//! `FontBackend.decode` (stb_truetype on the backend, pure CPU) → the 8-bit
//! coverage atlas is expanded to white-RGBA and uploaded through the
//! renderer's `createTextureFromPixels` (required `uploadTexture` decl
//! underneath) → glyph/codepoint/kern tables are RETAINED engine-side in
//! `game.ui_fonts`. That retention is the piece the catalog's font path
//! doesn't do (it hands tables to the backend and frees them) — and it is
//! exactly what the kit's `FontResolver` needs: `uiFont(name)` exposes the
//! tables for game-side glue to wrap in a `ui_kit.font.FontMetrics`
//! (identity slice casts, four scalar copies).
const std = @import("std");
const ui_draw_list = @import("../ui_draw_list.zig");
const assets_mod = @import("../assets/mod.zig");
const font_loader = assets_mod.font_loader;

/// Returns the UI-kit mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        const UiDrawCmd = ui_draw_list.UiDrawCmd;
        const UiRect = ui_draw_list.UiRect;
        const UiRgba8 = ui_draw_list.UiRgba8;

        fn rendererCanDrawUi(comptime Renderer: type) bool {
            return @hasDecl(Renderer, "drawScreenTexture") and
                @hasDecl(Renderer, "drawScreenRect");
        }

        /// Submit a UI-kit DrawList for this frame. `cmds` is a slice of
        /// kit-shaped `DrawCmd` unions (pass `draw_list.items` from
        /// `ui_kit.render.build`, or any structurally matching union —
        /// see `ui_draw_list.convertCommand`). Unknown command tags are
        /// skipped. Text slices are duped; the caller may free the list
        /// right after this returns.
        ///
        /// Multiple submits in one frame accumulate (drawn in submit
        /// order); the LAST submit's `opts` win. Everything drains at the
        /// next `render()`. No-op (drops the commands) when the renderer
        /// lacks the screen-quad seam.
        pub fn submitUiDrawList(
            self: *Game,
            cmds: anytype,
            opts: ui_draw_list.UiRenderOptions,
        ) void {
            if (comptime !rendererCanDrawUi(@TypeOf(self.renderer.*))) return;
            // Free the prior frame/submit's owned default-font dupe before the
            // struct copy overwrites the pointer (multiple submits per frame).
            if (self.ui_render_opts.default_font.len > 0) {
                self.allocator.free(self.ui_render_opts.default_font);
            }
            self.ui_render_opts = opts;
            self.ui_render_opts.default_font = "";
            if (opts.default_font.len > 0) {
                // Dupe: the caller's option slice has no lifetime contract.
                if (self.allocator.dupe(u8, opts.default_font)) |owned| {
                    self.ui_render_opts.default_font = owned;
                } else |_| {}
            }
            for (cmds) |cmd| {
                const converted = ui_draw_list.convertCommand(cmd) orelse continue;
                const retained: UiDrawCmd = switch (converted) {
                    .text_line => |line| blk: {
                        const content = self.allocator.dupe(u8, line.content) catch continue;
                        const font_name = self.allocator.dupe(u8, line.font_name) catch {
                            self.allocator.free(content);
                            continue;
                        };
                        var owned = line;
                        owned.content = content;
                        owned.font_name = font_name;
                        break :blk .{ .text_line = owned };
                    },
                    else => converted,
                };
                self.ui_draw_list.append(self.allocator, retained) catch {
                    // Allocation pressure: drop the command, free any dupes.
                    freeCmd(self, retained);
                };
            }
        }

        /// Draw + drain the retained commands. Called by `render()` in
        /// loop_mixin — after world/particles, before gizmos.
        pub fn renderSubmittedUi(self: *Game) void {
            const Renderer = @TypeOf(self.renderer.*);
            if (comptime !rendererCanDrawUi(Renderer)) return;
            if (self.ui_draw_list.items.len == 0) return;

            const Sink = struct {
                renderer: *Renderer,
                pub fn drawTexturedQuad(
                    sink: @This(),
                    texture_id: u32,
                    src: UiRect,
                    dst: UiRect,
                    tint: UiRgba8,
                ) void {
                    sink.renderer.drawScreenTexture(
                        texture_id,
                        src.x,
                        src.y,
                        src.w,
                        src.h,
                        dst.x,
                        dst.y,
                        dst.w,
                        dst.h,
                        tint.r,
                        tint.g,
                        tint.b,
                        tint.a,
                    );
                }
                pub fn drawSolidRect(sink: @This(), dst: UiRect, color: UiRgba8) void {
                    sink.renderer.drawScreenRect(
                        dst.x,
                        dst.y,
                        dst.w,
                        dst.h,
                        color.r,
                        color.g,
                        color.b,
                        color.a,
                    );
                }
            };

            ui_draw_list.renderCommands(
                Sink{ .renderer = self.renderer },
                &self.ui_fonts,
                self.ui_draw_list.items,
                self.ui_render_opts,
            );
            clearSubmittedUi(self);
        }

        /// Free retained command dupes + reset the list. Also called from
        /// `deinit` for commands submitted after the last `render()`.
        pub fn clearSubmittedUi(self: *Game) void {
            for (self.ui_draw_list.items) |cmd| freeCmd(self, cmd);
            self.ui_draw_list.clearRetainingCapacity();
            if (self.ui_render_opts.default_font.len > 0) {
                self.allocator.free(self.ui_render_opts.default_font);
                self.ui_render_opts.default_font = "";
            }
        }

        fn freeCmd(self: *Game, cmd: UiDrawCmd) void {
            switch (cmd) {
                .text_line => |line| {
                    self.allocator.free(line.content);
                    self.allocator.free(line.font_name);
                },
                else => {},
            }
        }

        /// Rasterise a TTF/OTF into a baked UI font under `name`:
        /// `FontBackend.decode` (RFC-FONT-LOADER; stb_truetype CPU bake on
        /// the injected backend) → white-RGBA atlas texture via the
        /// renderer's `createTextureFromPixels` → glyph tables retained in
        /// `game.ui_fonts` for both the engine's `text_line` drawing and
        /// the kit's `FontResolver` (via `uiFont`).
        ///
        /// `file_type` is "ttf"/"otf". `data` is borrowed for the call.
        /// Errors: `error.FontBackendNotInitialized` (no injected backend
        /// — e.g. headless tests without a mock), `error.Unsupported` (the
        /// renderer lacks `createTextureFromPixels`, i.e. pre-#771 gfx),
        /// plus whatever the backend's decode raises on malformed bytes.
        ///
        /// Baked fonts live for the Game lifetime (tables freed at
        /// `deinit`; the GPU texture is torn down with the renderer).
        /// Re-baking an existing `name` replaces the tables.
        pub fn bakeUiFont(
            self: *Game,
            name: []const u8,
            file_type: [:0]const u8,
            data: []const u8,
            params: font_loader.FontBakeParams,
        ) !void {
            const Renderer = @TypeOf(self.renderer.*);
            if (comptime !@hasDecl(Renderer, "createTextureFromPixels")) {
                return error.Unsupported;
            }
            const backend = font_loader.currentBackend() orelse
                return error.FontBackendNotInitialized;

            const decoded = try backend.decode(file_type, data, params, self.allocator);
            // Bitmap is consumed here; tables are retained (ownership moves
            // into the store on success).
            defer self.allocator.free(decoded.bitmap);
            errdefer {
                self.allocator.free(decoded.glyphs);
                self.allocator.free(decoded.codepoint_index);
                self.allocator.free(decoded.kerning);
            }

            // Expand the 8-bit coverage atlas to straight-alpha white RGBA:
            // draws through the ordinary textured-quad pipeline on every
            // backend (no R8 sampler support needed) and tints with the
            // text color at draw time.
            const pixel_count = @as(usize, decoded.width) * @as(usize, decoded.height);
            const rgba = try self.allocator.alloc(u8, pixel_count * 4);
            defer self.allocator.free(rgba);
            for (decoded.bitmap[0..pixel_count], 0..) |alpha, i| {
                rgba[i * 4 + 0] = 255;
                rgba[i * 4 + 1] = 255;
                rgba[i * 4 + 2] = 255;
                rgba[i * 4 + 3] = alpha;
            }

            const texture_id: u32 = try self.renderer.createTextureFromPixels(
                decoded.width,
                decoded.height,
                rgba,
            );

            try self.ui_fonts.put(self.allocator, name, .{
                .texture_id = texture_id,
                .atlas_width = decoded.width,
                .atlas_height = decoded.height,
                .glyphs = decoded.glyphs,
                .codepoint_index = decoded.codepoint_index,
                .kerning = decoded.kerning,
                .pixel_height = params.pixel_height,
                .ascent = decoded.ascent,
                .descent = decoded.descent,
                .line_gap = decoded.line_gap,
                .line_height = decoded.line_height,
            });
        }

        /// Baked-font lookup — the engine half of the kit's `FontResolver`.
        /// Game-side glue wraps the returned tables in a
        /// `ui_kit.font.FontMetrics` (slice casts + scalar copies).
        pub fn uiFont(self: *const Game, name: []const u8) ?*const ui_draw_list.BakedUiFont {
            return self.ui_fonts.get(name);
        }

        /// Resolve an atlas sprite frame for the UI kit — the engine half
        /// of the kit's `FrameResolver`. Wraps `findSprite` + the
        /// renderer's texture dims into normalised UVs.
        ///
        /// Returns null when the sprite is unknown, its atlas texture dims
        /// can't be queried, or the frame is 90°-rotated in the atlas (the
        /// kit's `UvRect` cannot express rotation — v1 limitation; pack UI
        /// themes with rotation disabled).
        pub fn resolveUiFrame(self: *Game, sprite_name: []const u8) ?ui_draw_list.ResolvedUiFrame {
            const found = self.findSprite(sprite_name) orelse return null;
            if (found.sprite.rotated) return null;
            const dims = self.queryTextureDims(found.texture_id) orelse return null;
            if (dims.width == 0 or dims.height == 0) return null;
            const aw: f32 = @floatFromInt(dims.width);
            const ah: f32 = @floatFromInt(dims.height);
            // Physical atlas footprint: logical grid × texture_scale (same
            // mapping `resolveAtlasSprites` applies for sprite draws).
            const px = @as(f32, @floatFromInt(found.sprite.x)) * found.texture_scale_x;
            const py = @as(f32, @floatFromInt(found.sprite.y)) * found.texture_scale_y;
            const pw = @as(f32, @floatFromInt(found.sprite.width)) * found.texture_scale_x;
            const ph = @as(f32, @floatFromInt(found.sprite.height)) * found.texture_scale_y;
            return .{
                .uv = .{
                    .u0 = px / aw,
                    .v0 = py / ah,
                    .u1 = (px + pw) / aw,
                    .v1 = (py + ph) / ah,
                },
                .frame_w = @floatFromInt(found.sprite.getWidth()),
                .frame_h = @floatFromInt(found.sprite.getHeight()),
                .texture_id = found.texture_id,
                .atlas_width = aw,
                .atlas_height = ah,
            };
        }
    };
}
