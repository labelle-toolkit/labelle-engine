//! Clay UI Adapter
//!
//! GUI backend using Clay UI layout engine.
//! Clay provides a declarative, high-performance UI layout system.
//!
//! Architecture:
//! - Collector Pattern: Widget calls are stored during the frame
//! - Clay hierarchy is built in endFrame() from collected calls
//! - Render commands are processed by renderer.zig
//! - Rendering is delegated to labelle-gfx backends (raylib)
//!
//! This adapter bridges labelle-engine's immediate-mode API with Clay's
//! declarative scope-based API by collecting calls and building the hierarchy.

const std = @import("std");
const types = @import("../types.zig");
const clay = @import("bindings.zig").clay;
const rl = @import("raylib");
const renderer = @import("renderer.zig");

const Self = @This();

/// Widget call storage for collector pattern
const WidgetCall = union(enum) {
    label: types.Label,
    button: types.Button,
    progress_bar: types.ProgressBar,
    panel_begin: types.Panel,
    panel_end: void,
    image: types.Image,
    checkbox: types.Checkbox,
    slider: types.Slider,
};

// Clay memory and context
memory: []u8 = &.{},
allocator: std.mem.Allocator = undefined,
initialized: bool = false,

// Collector pattern storage
widget_calls: std.ArrayList(WidgetCall) = undefined,
gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined,

// Screen dimensions
screen_width: f32 = 1920,
screen_height: f32 = 1080,

pub fn init() Self {
    return .{
        .initialized = false,
    };
}

pub fn fixPointers(_: *Self) void {
    // Clay manages pointers internally
}

pub fn deinit(self: *Self) void {
    if (self.initialized) {
        self.widget_calls.deinit(self.allocator);
        self.allocator.free(self.memory);
        _ = self.gpa.deinit();
        self.initialized = false;
    }
}

pub fn beginFrame(self: *Self) void {
    // Lazy initialization on first frame
    if (!self.initialized) {
        self.gpa = std.heap.GeneralPurposeAllocator(.{}){};
        self.allocator = self.gpa.allocator();
        self.widget_calls = std.ArrayList(WidgetCall){};

        // Initialize Clay
        const min_memory = clay.minMemorySize();
        self.memory = self.allocator.alloc(u8, min_memory) catch {
            std.debug.print("Failed to allocate Clay memory\n", .{});
            return;
        };

        const arena = clay.createArenaWithCapacityAndMemory(self.memory);

        _ = clay.initialize(
            arena,
            .{ .w = self.screen_width, .h = self.screen_height },
            .{
                .error_handler_function = errorHandler,
                .user_data = null,
            },
        );

        // Set text measurement function for Clay layout calculations
        clay.setMeasureTextFunction(*Self, self, measureTextCallback);

        self.initialized = true;
    }

    // Clear collected calls for new frame
    self.widget_calls.clearRetainingCapacity();
}

pub fn endFrame(self: *Self) void {
    if (!self.initialized) return;

    // Begin Clay layout
    clay.beginLayout();

    // Build Clay hierarchy from collected calls
    var i: usize = 0;
    while (i < self.widget_calls.items.len) : (i += 1) {
        const call = self.widget_calls.items[i];
        switch (call) {
            .label => |lbl| buildClayLabel(lbl),
            .button => |btn| buildClayButton(btn),
            .progress_bar => |bar| buildClayProgressBar(bar),
            .panel_begin => |panel| buildClayPanelBegin(panel),
            .panel_end => buildClayPanelEnd(),
            .image => |img| buildClayImage(img),
            .checkbox => |cb| buildClayCheckbox(cb),
            .slider => |sl| buildClaySlider(sl),
        }
    }

    // Finalize Clay layout and get render commands
    const render_commands = clay.endLayout();

    // Process render commands through renderer
    renderer.processRenderCommands(render_commands);
}

pub fn label(self: *Self, lbl: types.Label) void {
    self.widget_calls.append(self.allocator, .{ .label = lbl }) catch {
        std.debug.print("Failed to append label widget call\n", .{});
    };
}

pub fn button(self: *Self, btn: types.Button) bool {
    self.widget_calls.append(self.allocator, .{ .button = btn }) catch {
        std.debug.print("Failed to append button widget call\n", .{});
    };
    // TODO: Return actual click state from Clay pointer state
    return false;
}

pub fn progressBar(self: *Self, bar: types.ProgressBar) void {
    self.widget_calls.append(self.allocator, .{ .progress_bar = bar }) catch {
        std.debug.print("Failed to append progress bar widget call\n", .{});
    };
}

pub fn beginPanel(self: *Self, panel: types.Panel) void {
    self.widget_calls.append(self.allocator, .{ .panel_begin = panel }) catch {
        std.debug.print("Failed to append panel begin widget call\n", .{});
    };
}

pub fn endPanel(self: *Self) void {
    self.widget_calls.append(self.allocator, .{ .panel_end = {} }) catch {
        std.debug.print("Failed to append panel end widget call\n", .{});
    };
}

pub fn image(self: *Self, img: types.Image) void {
    self.widget_calls.append(self.allocator, .{ .image = img }) catch {
        std.debug.print("Failed to append image widget call\n", .{});
    };
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    self.widget_calls.append(self.allocator, .{ .checkbox = cb }) catch {
        std.debug.print("Failed to append checkbox widget call\n", .{});
    };
    // TODO: Return actual checked state from Clay pointer state
    return cb.checked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    self.widget_calls.append(self.allocator, .{ .slider = sl }) catch {
        std.debug.print("Failed to append slider widget call\n", .{});
    };
    // TODO: Return actual value from Clay pointer state
    return sl.value;
}

// ============================================================================
// Clay Element Builders
// ============================================================================

fn buildClayLabel(lbl: types.Label) void {
    // Convert labelle color to Clay color
    const color: clay.Color = .{
        @floatFromInt(lbl.color.r),
        @floatFromInt(lbl.color.g),
        @floatFromInt(lbl.color.b),
        @floatFromInt(lbl.color.a),
    };

    // Create text config
    const text_config = clay.TextElementConfig{
        .color = color,
        .font_size = @intFromFloat(lbl.font_size),
        .letter_spacing = 0,
        .line_height = 0,
        .wrap_mode = .words,
    };

    // Use Clay's text function which handles everything
    clay.text(lbl.text, text_config);
}

fn buildClayButton(btn: types.Button) void {
    // Create button as a clickable rectangle with text
    clay.UI()(.{
        .layout = .{
            .sizing = .{
                .w = clay.SizingAxis.fixed(btn.size.width),
                .h = clay.SizingAxis.fixed(btn.size.height),
            },
            .padding = clay.Padding.all(8),
            .child_alignment = .center,
        },
        .background_color = .{ 80, 120, 200, 255 },
        .corner_radius = clay.CornerRadius.all(4),
    })({
        clay.text(btn.text, .{
            .font_size = 16,
            .color = .{ 255, 255, 255, 255 },
        });
    });
}

fn buildClayProgressBar(bar: types.ProgressBar) void {
    // Convert labelle color to Clay color
    const fill_color: clay.Color = .{
        @floatFromInt(bar.color.r),
        @floatFromInt(bar.color.g),
        @floatFromInt(bar.color.b),
        @floatFromInt(bar.color.a),
    };

    // Create container for progress bar
    clay.UI()(.{
        .layout = .{
            .sizing = .{
                .w = clay.SizingAxis.fixed(bar.size.width),
                .h = clay.SizingAxis.fixed(bar.size.height),
            },
        },
        .background_color = .{ 40, 40, 40, 255 }, // Dark background
        .corner_radius = clay.CornerRadius.all(4),
    })({
        // Fill bar (proportional to value)
        const fill_width = bar.size.width * @max(0.0, @min(1.0, bar.value));
        clay.UI()(.{
            .layout = .{
                .sizing = .{
                    .w = clay.SizingAxis.fixed(fill_width),
                    .h = clay.SizingAxis.grow,
                },
            },
            .background_color = fill_color,
            .corner_radius = clay.CornerRadius.all(4),
        })({});
    });
}

fn buildClayPanelBegin(panel: types.Panel) void {
    // Convert background color
    const bg_color: clay.Color = .{
        @floatFromInt(panel.background_color.r),
        @floatFromInt(panel.background_color.g),
        @floatFromInt(panel.background_color.b),
        @floatFromInt(panel.background_color.a),
    };

    // Open element and configure it
    clay.cdefs.Clay__OpenElement();
    clay.cdefs.Clay__ConfigureOpenElement(.{
        .layout = .{
            .sizing = .{
                .w = clay.SizingAxis.fixed(panel.size.width),
                .h = clay.SizingAxis.fixed(panel.size.height),
            },
            .padding = clay.Padding.all(10),
            .direction = .top_to_bottom,
            .child_gap = 5,
        },
        .background_color = bg_color,
        .corner_radius = clay.CornerRadius.all(8),
    });
}

fn buildClayPanelEnd() void {
    // Close the panel element
    clay.cdefs.Clay__CloseElement();
}

fn buildClayImage(img: types.Image) void {
    // For now, create a placeholder rectangle
    // TODO: Implement actual image rendering with texture loading
    const width = if (img.size) |s| s.width else 100;
    const height = if (img.size) |s| s.height else 100;

    clay.UI()(.{
        .layout = .{
            .sizing = .{
                .w = clay.SizingAxis.fixed(width),
                .h = clay.SizingAxis.fixed(height),
            },
        },
        .background_color = .{ 128, 128, 128, 255 },
        .corner_radius = clay.CornerRadius.all(4),
    })({
        // Show image name as placeholder
        clay.text(img.name, .{
            .font_size = 12,
            .color = .{ 200, 200, 200, 255 },
        });
    });
}

fn buildClayCheckbox(cb: types.Checkbox) void {
    // Create checkbox as a horizontal layout with box + label
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fit, .h = clay.SizingAxis.fit },
            .direction = .left_to_right,
            .child_gap = 8,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        // Checkbox box (20x20)
        clay.UI()(.{
            .layout = .{
                .sizing = .{
                    .w = clay.SizingAxis.fixed(20),
                    .h = clay.SizingAxis.fixed(20),
                },
            },
            .background_color = if (cb.checked) .{ 80, 200, 80, 255 } else .{ 60, 60, 60, 255 },
            .corner_radius = clay.CornerRadius.all(3),
            .border = .{
                .width = clay.BorderWidth.outside(2),
                .color = .{ 100, 100, 100, 255 },
            },
        })({
            // Checkmark (if checked)
            if (cb.checked) {
                clay.text("✓", .{
                    .font_size = 14,
                    .color = .{ 255, 255, 255, 255 },
                });
            }
        });

        // Label text
        clay.text(cb.text, .{
            .font_size = 16,
            .color = .{ 255, 255, 255, 255 },
        });
    });
}

fn buildClaySlider(sl: types.Slider) void {
    // Calculate slider fill percentage
    const range = sl.max - sl.min;
    const normalized = if (range > 0) (sl.value - sl.min) / range else 0.0;
    const fill_percentage = @max(0.0, @min(1.0, normalized));

    // Create slider as background + fill bar
    clay.UI()(.{
        .layout = .{
            .sizing = .{
                .w = clay.SizingAxis.fixed(sl.size.width),
                .h = clay.SizingAxis.fixed(sl.size.height),
            },
        },
        .background_color = .{ 50, 50, 50, 255 },
        .corner_radius = clay.CornerRadius.all(sl.size.height / 2), // Rounded ends
    })({
        // Fill portion
        const fill_width = sl.size.width * fill_percentage;
        clay.UI()(.{
            .layout = .{
                .sizing = .{
                    .w = clay.SizingAxis.fixed(fill_width),
                    .h = clay.SizingAxis.grow,
                },
            },
            .background_color = .{ 100, 150, 255, 255 },
            .corner_radius = clay.CornerRadius.all(sl.size.height / 2),
        })({});
    });
}

// ============================================================================
// Clay Callbacks
// ============================================================================

fn errorHandler(error_data: clay.ErrorData) callconv(.c) void {
    const error_text = error_data.error_text.chars[0..@intCast(error_data.error_text.length)];
    std.debug.print("Clay Error: {s}\n", .{error_text});
}

fn measureTextCallback(
    text: []const u8,
    config: *clay.TextElementConfig,
    userData: *Self,
) clay.Dimensions {
    const self = userData;

    // Use the adapter's allocator to create a temporary null-terminated string
    const text_nt = self.allocator.allocSentinel(u8, text.len, 0) catch |err| {
        std.debug.print("Failed to allocate for text measurement: {any}\n", .{err});
        return .{ .w = 0, .h = 0 };
    };
    defer self.allocator.free(text_nt);
    @memcpy(text_nt[0..text.len], text);

    // Measure using raylib
    const text_width = rl.measureText(text_nt, @intCast(config.font_size));
    const text_height = config.font_size;

    return .{
        .w = @floatFromInt(text_width),
        .h = @floatFromInt(text_height),
    };
}
