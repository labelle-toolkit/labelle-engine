/// GUI mixin — GUI begin/end, view rendering, and widget dispatch.
const std = @import("std");
const gui_types = @import("../gui_types.zig");

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

        fn renderGuiElementComptime(self: *Game, comptime element: gui_types.GuiElement) void {
            if (!element.isVisible()) return;
            switch (element) {
                .Label => |lbl| {
                    // Resolve the optional font asset to a runtime
                    // `FontId` when `lbl.font` is set. Comptime branch
                    // keeps the default-font path zero-overhead for
                    // labels that don't use a custom font.
                    if (comptime lbl.font) |font_name| {
                        // `Game.fontId` (atlas_mixin) — the SAME lookup a
                        // script reaches for `addText` / `setTextFont`.
                        // This used to be a private `resolveLabelFont`
                        // right here, which is precisely why the resource
                        // kind was unusable from anywhere but a GUI label
                        // (#842); it is now one implementation, and its
                        // null-while-streaming contract is documented on
                        // `atlas_mixin.fontId`. Null keeps the renderer's
                        // default-font path intact — the label draws in
                        // the backend's built-in font for a frame or two
                        // until the asset finishes baking.
                        const font_id = self.fontId(font_name);
                        // The backend's font-aware label draw is
                        // expected to accept an `?FontId` — null
                        // means "fall back to default font", same
                        // shape as `fontId`'s contract during
                        // streaming. Backends that don't
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
