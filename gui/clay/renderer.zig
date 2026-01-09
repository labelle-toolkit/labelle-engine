//! Clay Renderer Interface
//!
//! Processes Clay render commands and converts them to raylib draw calls.
//! Clay calculates layouts and produces render commands, which we
//! translate to raylib rendering operations.

const std = @import("std");
const clay = @import("bindings.zig").clay;
const rl = @import("raylib");

/// Process Clay render commands and draw them using raylib
pub fn processRenderCommands(render_commands: clay.Clay_RenderCommandArray) void {
    var i: u32 = 0;
    while (i < render_commands.length) : (i += 1) {
        const cmd = render_commands.internalArray[i];

        switch (cmd.commandType) {
            clay.CLAY_RENDER_COMMAND_TYPE_RECTANGLE => {
                drawRectangle(cmd.config.rectangleElementConfig.*, cmd.boundingBox);
            },
            clay.CLAY_RENDER_COMMAND_TYPE_TEXT => {
                drawText(cmd.config.textElementConfig.*, cmd.text, cmd.boundingBox);
            },
            clay.CLAY_RENDER_COMMAND_TYPE_IMAGE => {
                drawImage(cmd.config.imageElementConfig.*, cmd.boundingBox);
            },
            clay.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START => {
                startScissor(cmd.boundingBox);
            },
            clay.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END => {
                endScissor();
            },
            clay.CLAY_RENDER_COMMAND_TYPE_BORDER => {
                drawBorder(cmd.config.borderElementConfig.*, cmd.boundingBox);
            },
            clay.CLAY_RENDER_COMMAND_TYPE_CUSTOM => {
                // Custom render commands not yet supported
            },
            else => {
                // Unknown command type
            },
        }
    }
}

// ============================================================================
// Render Command Handlers
// ============================================================================

fn drawRectangle(config: clay.Clay_RectangleElementConfig, bounds: clay.Clay_BoundingBox) void {
    const rect = rl.Rectangle{
        .x = bounds.x,
        .y = bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    };

    const color = clayColorToRaylib(config.color);

    // Check if we need rounded corners
    const has_rounded = config.cornerRadius.topLeft > 0 or
        config.cornerRadius.topRight > 0 or
        config.cornerRadius.bottomLeft > 0 or
        config.cornerRadius.bottomRight > 0;

    if (has_rounded) {
        // Use the maximum corner radius for simplicity
        const radius = @max(@max(config.cornerRadius.topLeft, config.cornerRadius.topRight), @max(config.cornerRadius.bottomLeft, config.cornerRadius.bottomRight));
        rl.drawRectangleRounded(rect, radius / @min(bounds.width, bounds.height), 8, color);
    } else {
        rl.drawRectangleRec(rect, color);
    }
}

fn drawText(config: clay.Clay_TextElementConfig, text: clay.Clay_String, bounds: clay.Clay_BoundingBox) void {
    // Create null-terminated buffer for raylib
    const max_len = @min(text.length, 4096);
    var buf: [4096:0]u8 = undefined;
    @memcpy(buf[0..max_len], text.chars[0..max_len]);
    buf[max_len] = 0;

    const color = clayColorToRaylib(config.textColor);

    rl.drawText(
        &buf,
        @intFromFloat(bounds.x),
        @intFromFloat(bounds.y),
        @intCast(config.fontSize),
        color,
    );
}

fn drawImage(config: clay.Clay_ImageElementConfig, bounds: clay.Clay_BoundingBox) void {
    _ = config;

    // For now, draw a placeholder rectangle
    // TODO: Implement actual texture rendering when we have texture management
    const placeholder_color = rl.Color{ .r = 128, .g = 128, .b = 128, .a = 200 };
    const rect = rl.Rectangle{
        .x = bounds.x,
        .y = bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    };
    rl.drawRectangleRec(rect, placeholder_color);
}

fn drawBorder(config: clay.Clay_BorderElementConfig, bounds: clay.Clay_BoundingBox) void {
    const color = clayColorToRaylib(config.color);
    const rect = rl.Rectangle{
        .x = bounds.x,
        .y = bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    };

    // Draw border with the specified width
    // Clay borders can have different widths on each side, but raylib's drawRectangleLinesEx
    // uses uniform thickness. We'll use the maximum border width.
    const thickness = @max(@max(config.width.left, config.width.right), @max(config.width.top, config.width.bottom));

    rl.drawRectangleLinesEx(rect, thickness, color);
}

fn startScissor(bounds: clay.Clay_BoundingBox) void {
    rl.beginScissorMode(
        @intFromFloat(bounds.x),
        @intFromFloat(bounds.y),
        @intFromFloat(bounds.width),
        @intFromFloat(bounds.height),
    );
}

fn endScissor() void {
    rl.endScissorMode();
}

// ============================================================================
// Helper Functions
// ============================================================================

fn clayColorToRaylib(color: clay.Clay_Color) rl.Color {
    return rl.Color{
        .r = @intFromFloat(color.r),
        .g = @intFromFloat(color.g),
        .b = @intFromFloat(color.b),
        .a = @intFromFloat(color.a),
    };
}
