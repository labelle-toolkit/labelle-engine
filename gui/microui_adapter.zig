//! microui Adapter
//!
//! GUI backend using microui - a tiny immediate-mode UI library.
//! microui is lightweight (~1000 LOC) and easy to integrate.
//! Requires microui.zig dependency when building with -Dgui_backend=microui.
//!
//! TODO: Implement full microui integration:
//! - Add microui.zig dependency to build.zig.zon
//! - Initialize microui context
//! - Implement rendering with graphics backend

const std = @import("std");
const types = @import("types.zig");

const Self = @This();

// microui context would be stored here
// ctx: mu.Context = undefined,

pub fn init() Self {
    // TODO: Initialize microui context
    // mu.init(&ctx);
    // ctx.text_width = textWidth;
    // ctx.text_height = textHeight;
    std.log.info("microui adapter initialized (stub implementation)", .{});
    return .{};
}

pub fn deinit(self: *Self) void {
    _ = self;
    // microui doesn't require explicit cleanup
}

pub fn beginFrame(self: *Self) void {
    _ = self;
    // TODO: mu.begin(&ctx);
    // TODO: Handle input: mu.input_mousemove, mu.input_mousedown, etc.
}

pub fn endFrame(self: *Self) void {
    _ = self;
    // TODO: mu.end(&ctx);
    // TODO: Render commands from mu.command_next(&ctx)
    // while (mu.command_next(&ctx)) |cmd| {
    //     switch (cmd.type) {
    //         .RECT => drawRect(cmd.rect),
    //         .TEXT => drawText(cmd.text),
    //         .ICON => drawIcon(cmd.icon),
    //         .CLIP => setClip(cmd.clip),
    //     }
    // }
}

pub fn label(self: *Self, lbl: types.Label) void {
    _ = self;
    _ = lbl;
    // TODO: mu.label(&ctx, lbl.text);
}

pub fn button(self: *Self, btn: types.Button) bool {
    _ = self;
    _ = btn;
    // TODO: return mu.button(&ctx, btn.text) != 0;
    return false;
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    _ = self;
    _ = bar;
    // microui doesn't have a built-in progress bar
    // TODO: Draw custom progress bar using mu.draw_rect
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    _ = self;
    _ = panel;
    // TODO: mu.begin_window(&ctx, panel.id, mu.rect(panel.position.x, panel.position.y, panel.size.width, panel.size.height));
}

pub fn endPanel(self: *Self) void {
    _ = self;
    // TODO: mu.end_window(&ctx);
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    _ = img;
    // microui doesn't have built-in image support
    // TODO: Draw image using custom rendering
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    _ = self;
    _ = cb;
    // TODO: var state: c_int = if (cb.checked) 1 else 0;
    // TODO: mu.checkbox(&ctx, cb.text, &state);
    // TODO: return (state != 0) != cb.checked;
    return false;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    _ = self;
    // TODO: var value = sl.value;
    // TODO: mu.slider(&ctx, &value, sl.min, sl.max);
    // TODO: return value;
    return sl.value;
}
