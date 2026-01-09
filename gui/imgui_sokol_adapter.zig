//! ImGui Sokol Adapter
//!
//! GUI backend using Dear ImGui with sokol rendering.
//! Uses zgui for Zig bindings to ImGui.
//!
//! NOTE: Full ImGui support with sokol is not yet available.
//! Sokol doesn't expose a GLFW window handle needed by zgui's GLFW+OpenGL backend.
//! ImGui widgets will be skipped. Use zgpu backend for full ImGui support.
//!
//! Build with: zig build -Dbackend=sokol -Dgui_backend=imgui

const std = @import("std");
const types = @import("types.zig");
const zgui = @import("zgui");

const Self = @This();

// Window counter for unique IDs
window_counter: u32,

// Panel nesting level
panel_depth: u32,

// Allocator for zgui
allocator: std.mem.Allocator,

// Track if warning shown
warned: bool,

pub fn init() Self {
    const allocator = std.heap.page_allocator;

    // Initialize zgui core (backend not initialized - no GLFW window access)
    zgui.init(allocator);

    return Self{
        .window_counter = 0,
        .panel_depth = 0,
        .allocator = allocator,
        .warned = false,
    };
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    _ = self;
    zgui.deinit();
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    if (!self.warned) {
        std.log.warn("imgui_sokol: ImGui not available with sokol backend", .{});
        std.log.warn("imgui_sokol: Use zgpu backend for ImGui support", .{});
        self.warned = true;
    }
    // Skip ImGui processing since we can't render it
}

pub fn endFrame(self: *Self) void {
    _ = self;
    // Skip - nothing to render with sokol backend
}

fn nextWindowName(self: *Self, buf: []u8) [:0]const u8 {
    self.window_counter += 1;
    const result = std.fmt.bufPrintZ(buf, "##w{d}", .{self.window_counter}) catch {
        buf[0] = '#';
        buf[1] = '#';
        buf[2] = 'w';
        buf[3] = 0;
        return buf[0..3 :0];
    };
    return result;
}

pub fn label(self: *Self, lbl: types.Label) void {
    if (self.panel_depth > 0) {
        zgui.textColored(
            .{ @as(f32, @floatFromInt(lbl.color.r)) / 255.0, @as(f32, @floatFromInt(lbl.color.g)) / 255.0, @as(f32, @floatFromInt(lbl.color.b)) / 255.0, @as(f32, @floatFromInt(lbl.color.a)) / 255.0 },
            "{s}",
            .{lbl.text},
        );
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        zgui.setNextWindowPos(.{ .x = lbl.position.x, .y = lbl.position.y });
        zgui.setNextWindowSize(.{ .w = @floatFromInt(lbl.text.len * 10), .h = lbl.font_size + 8 });

        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
                .no_mouse_inputs = true,
            },
        })) {
            zgui.textColored(
                .{ @as(f32, @floatFromInt(lbl.color.r)) / 255.0, @as(f32, @floatFromInt(lbl.color.g)) / 255.0, @as(f32, @floatFromInt(lbl.color.b)) / 255.0, @as(f32, @floatFromInt(lbl.color.a)) / 255.0 },
                "{s}",
                .{lbl.text},
            );
        }
        zgui.end();
    }
}

pub fn button(self: *Self, btn: types.Button) bool {
    // Convert text to null-terminated
    var text_buf: [256]u8 = undefined;
    const text_z = std.fmt.bufPrintZ(&text_buf, "{s}", .{btn.text}) catch return false;

    if (self.panel_depth > 0) {
        return zgui.button(text_z, .{ .w = btn.size.width, .h = btn.size.height });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        zgui.setNextWindowPos(.{ .x = btn.position.x, .y = btn.position.y });
        zgui.setNextWindowSize(.{ .w = btn.size.width + 16, .h = btn.size.height + 16 });

        var clicked = false;
        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
            },
        })) {
            clicked = zgui.button(text_z, .{ .w = btn.size.width, .h = btn.size.height });
        }
        zgui.end();

        return clicked;
    }
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    if (self.panel_depth > 0) {
        zgui.progressBar(.{
            .fraction = bar.value,
            .overlay = null,
            .w = bar.size.width,
            .h = bar.size.height,
        });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        zgui.setNextWindowPos(.{ .x = bar.position.x, .y = bar.position.y });
        zgui.setNextWindowSize(.{ .w = bar.size.width + 16, .h = bar.size.height + 16 });

        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
            },
        })) {
            zgui.progressBar(.{
                .fraction = bar.value,
                .overlay = null,
                .w = bar.size.width,
                .h = bar.size.height,
            });
        }
        zgui.end();
    }
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    var name_buf: [32]u8 = undefined;
    const name = self.nextWindowName(&name_buf);

    zgui.setNextWindowPos(.{ .x = panel.position.x, .y = panel.position.y });
    zgui.setNextWindowSize(.{ .w = panel.size.width, .h = panel.size.height });

    _ = zgui.begin(name, .{
        .flags = .{
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
        },
    });
    self.panel_depth += 1;
}

pub fn endPanel(self: *Self) void {
    self.panel_depth -= 1;
    zgui.end();
}

pub fn image(self: *Self, img: types.Image) void {
    _ = self;
    _ = img;
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    var checked = cb.checked;

    // Convert text to null-terminated
    var text_buf: [256]u8 = undefined;
    const text_z = std.fmt.bufPrintZ(&text_buf, "{s}", .{cb.text}) catch return checked;

    if (self.panel_depth > 0) {
        _ = zgui.checkbox(text_z, .{ .v = &checked });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        const text_len: usize = cb.text.len;
        zgui.setNextWindowPos(.{ .x = cb.position.x, .y = cb.position.y });
        zgui.setNextWindowSize(.{ .w = @as(f32, @floatFromInt(text_len * 8)) + 50, .h = 40 });

        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
            },
        })) {
            _ = zgui.checkbox(text_z, .{ .v = &checked });
        }
        zgui.end();
    }

    return checked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    var value = sl.value;

    if (self.panel_depth > 0) {
        _ = zgui.sliderFloat("##slider", .{
            .v = &value,
            .min = sl.min,
            .max = sl.max,
        });
    } else {
        var name_buf: [32]u8 = undefined;
        const name = self.nextWindowName(&name_buf);

        zgui.setNextWindowPos(.{ .x = sl.position.x, .y = sl.position.y });
        zgui.setNextWindowSize(.{ .w = sl.size.width + 16, .h = sl.size.height + 16 });

        if (zgui.begin(name, .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_background = true,
            },
        })) {
            _ = zgui.sliderFloat("##slider", .{
                .v = &value,
                .min = sl.min,
                .max = sl.max,
            });
        }
        zgui.end();
    }

    return value;
}
