//! ImGui Raylib Adapter
//!
//! GUI backend using Dear ImGui with raylib/GLFW+OpenGL3 rendering.
//! Uses zgui for Zig bindings to ImGui.
//!
//! Build with: zig build -Dbackend=raylib -Dgui_backend=imgui

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

// Track if initialized
initialized: bool,

pub fn init() Self {
    const allocator = std.heap.page_allocator;

    // Initialize zgui
    zgui.init(allocator);

    // Initialize the backend (GLFW+OpenGL3)
    zgui.backend.init();

    return Self{
        .window_counter = 0,
        .panel_depth = 0,
        .allocator = allocator,
        .initialized = true,
    };
}

pub fn fixPointers(self: *Self) void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    if (self.initialized) {
        zgui.backend.deinit();
        zgui.deinit();
        self.initialized = false;
    }
}

pub fn beginFrame(self: *Self) void {
    self.window_counter = 0;

    // Start new ImGui frame
    zgui.backend.newFrame();
    zgui.newFrame();
}

pub fn endFrame(self: *Self) void {
    _ = self;

    // Render ImGui
    zgui.render();
    zgui.backend.draw();
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
        // Inside a panel - use current layout
        zgui.textColored(
            .{ @as(f32, @floatFromInt(lbl.color.r)) / 255.0, @as(f32, @floatFromInt(lbl.color.g)) / 255.0, @as(f32, @floatFromInt(lbl.color.b)) / 255.0, @as(f32, @floatFromInt(lbl.color.a)) / 255.0 },
            "{s}",
            .{lbl.text},
        );
    } else {
        // Standalone label - create invisible window at position
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
    if (self.panel_depth > 0) {
        // Inside a panel - use current layout
        return zgui.button(btn.text, .{ .w = btn.size.width, .h = btn.size.height });
    } else {
        // Standalone button - create window at position
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
            clicked = zgui.button(btn.text, .{ .w = btn.size.width, .h = btn.size.height });
        }
        zgui.end();

        return clicked;
    }
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    if (self.panel_depth > 0) {
        // Inside a panel
        zgui.progressBar(.{
            .fraction = bar.value,
            .overlay = "",
            .size = .{ .x = bar.size.width, .y = bar.size.height },
        });
    } else {
        // Standalone progress bar
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
                .overlay = "",
                .size = .{ .x = bar.size.width, .y = bar.size.height },
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
    // TODO: Implement image rendering with ImGui
    // Would need to create a texture and use zgui.image()
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    var checked = cb.checked;

    if (self.panel_depth > 0) {
        // Inside a panel
        _ = zgui.checkbox(cb.text, .{ .v = &checked });
    } else {
        // Standalone checkbox
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
            _ = zgui.checkbox(cb.text, .{ .v = &checked });
        }
        zgui.end();
    }

    return checked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    var value = sl.value;

    if (self.panel_depth > 0) {
        // Inside a panel
        _ = zgui.sliderFloat("##slider", .{
            .v = &value,
            .min = sl.min,
            .max = sl.max,
        });
    } else {
        // Standalone slider
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
