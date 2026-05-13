/// GUI mixin — GUI begin/end, view rendering, and widget dispatch.
const std = @import("std");
const gui_types = @import("../gui_types.zig");
const font_types = @import("font_types");

/// Returns the GUI mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Gui = Game.Gui;

    return struct {
        pub fn guiBegin(_: *Game) void {
            Gui.begin();
        }

        pub fn guiEnd(_: *Game) void {
            Gui.end();
        }

        pub fn guiWantsMouse(_: *Game) bool {
            return Gui.wantsMouse();
        }

        pub fn guiWantsKeyboard(_: *Game) bool {
            return Gui.wantsKeyboard();
        }

        /// Render all views from a ViewRegistry.
        pub fn renderAllViews(self: *Game, comptime Views: type) void {
            inline for (comptime Views.names()) |view_name| {
                const view_def = comptime Views.get(view_name);
                inline for (view_def.elements) |element| {
                    renderGuiElementComptime(self, element);
                }
            }
        }

        /// Render a named view from a ViewRegistry.
        pub fn renderView(self: *Game, comptime Views: type, comptime view_name: []const u8) void {
            if (!Views.has(view_name)) return;
            const view_def = comptime Views.get(view_name);
            inline for (view_def.elements) |element| {
                renderGuiElementComptime(self, element);
            }
        }

        /// Runtime asset lookup for a label's optional `font` field.
        /// Returns the baked `FontId` when the asset is `.ready`,
        /// `null` otherwise (asset still loading, missing, or
        /// not-a-font payload). Falling back to `null` keeps the
        /// renderer's default-font path intact during streaming —
        /// the label simply uses the backend's built-in font for a
        /// frame or two until the asset finishes loading.
        fn resolveLabelFont(self: *Game, font_name: []const u8) ?font_types.FontId {
            const entry = self.assets.entries.getPtr(font_name) orelse return null;
            const resource = entry.resource orelse return null;
            return switch (resource) {
                .font => |id| id,
                else => null,
            };
        }

        fn renderGuiElementComptime(self: *Game, comptime element: gui_types.GuiElement) void {
            if (!element.isVisible()) return;
            switch (element) {
                .Label => |lbl| {
                    // Resolve the optional font asset to a runtime
                    // `FontId` when `lbl.font` is set. Comptime branch
                    // keeps the default-font path zero-overhead for
                    // labels that don't use a custom font.
                    if (comptime lbl.font) |font_name| {
                        const font_id = resolveLabelFont(self, font_name);
                        // The backend's font-aware label draw is
                        // expected to accept an `?FontId` — null
                        // means "fall back to default font", same
                        // shape as `resolveLabelFont`'s contract
                        // during streaming. Backends that don't
                        // implement `labelWidgetWithFont` keep
                        // working via the `@hasDecl` guard on the
                        // `Gui` wrapper.
                        Gui.labelWidgetWithFont(
                            lbl.text[0..lbl.text.len :0],
                            @intFromFloat(lbl.position.x),
                            @intFromFloat(lbl.position.y),
                            @intFromFloat(lbl.font_size),
                            lbl.color.r,
                            lbl.color.g,
                            lbl.color.b,
                            font_id,
                        );
                    } else {
                        Gui.labelWidget(
                            lbl.text[0..lbl.text.len :0],
                            @intFromFloat(lbl.position.x),
                            @intFromFloat(lbl.position.y),
                            @intFromFloat(lbl.font_size),
                            lbl.color.r,
                            lbl.color.g,
                            lbl.color.b,
                        );
                    }
                },
                .Button => |btn| _ = Gui.buttonWidget(
                    comptime std.hash.Fnv1a_32.hash(btn.id),
                    btn.text[0..btn.text.len :0],
                    @intFromFloat(btn.position.x),
                    @intFromFloat(btn.position.y),
                    @intFromFloat(btn.size.width),
                    @intFromFloat(btn.size.height),
                ),
                .ProgressBar => |bar| Gui.progressBarWidget(
                    @intFromFloat(bar.position.x),
                    @intFromFloat(bar.position.y),
                    @intFromFloat(bar.size.width),
                    @intFromFloat(bar.size.height),
                    bar.value,
                    bar.color.r,
                    bar.color.g,
                    bar.color.b,
                ),
                .Panel => |panel| {
                    Gui.panelWidget(
                        @intFromFloat(panel.position.x),
                        @intFromFloat(panel.position.y),
                        @intFromFloat(panel.size.width),
                        @intFromFloat(panel.size.height),
                    );
                    inline for (panel.children) |child| {
                        renderGuiElementComptime(self, child);
                    }
                },
                .Image => {},
                .Checkbox => |cb| _ = Gui.checkboxWidget(
                    comptime std.hash.Fnv1a_32.hash(cb.id),
                    cb.text[0..cb.text.len :0],
                    @intFromFloat(cb.position.x),
                    @intFromFloat(cb.position.y),
                    cb.checked,
                ),
                .Slider => |sl| _ = Gui.sliderWidget(
                    comptime std.hash.Fnv1a_32.hash(sl.id),
                    @intFromFloat(sl.position.x),
                    @intFromFloat(sl.position.y),
                    @intFromFloat(sl.size.width),
                    @intFromFloat(sl.size.height),
                    sl.value,
                    sl.min,
                    sl.max,
                ),
            }
        }
    };
}
