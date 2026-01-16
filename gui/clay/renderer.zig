//! Clay Renderer Interface
//!
//! Processes Clay render commands and converts them to raylib draw calls.
//! Clay calculates layouts and produces render commands, which we
//! translate to raylib rendering operations.

const std = @import("std");
const clay = @import("bindings.zig").clay;
const rl = @import("raylib");

/// Process Clay render commands and draw them using raylib
pub fn processRenderCommands(render_commands: []clay.RenderCommand) void {
    for (render_commands) |cmd| {
        switch (cmd.command_type) {
            .rectangle => {
                drawRectangle(cmd.render_data.rectangle, cmd.bounding_box);
            },
            .text => {
                drawText(cmd.render_data.text, cmd.bounding_box);
            },
            .image => {
                drawImage(cmd.render_data.image, cmd.bounding_box);
            },
            .scissor_start => {
                startScissor(cmd.bounding_box);
            },
            .scissor_end => {
                endScissor();
            },
            .border => {
                drawBorder(cmd.render_data.border, cmd.bounding_box);
            },
            .custom => {
                // Custom render commands not yet supported
            },
            .none => {
                // Skip none commands
            },
        }
    }
}

// ============================================================================
// Render Command Handlers
// ============================================================================

fn drawRectangle(config: clay.RectangleRenderData, bounds: clay.BoundingBox) void {
    const rect = rl.Rectangle{
        .x = bounds.x,
        .y = bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    };

    const color = clayColorToRaylib(config.background_color);

    // Check if we need rounded corners
    const has_rounded = config.corner_radius.top_left > 0 or
        config.corner_radius.top_right > 0 or
        config.corner_radius.bottom_left > 0 or
        config.corner_radius.bottom_right > 0;

    if (has_rounded) {
        // Use the maximum corner radius for simplicity
        const radius = @max(@max(config.corner_radius.top_left, config.corner_radius.top_right), @max(config.corner_radius.bottom_left, config.corner_radius.bottom_right));
        rl.drawRectangleRounded(rect, radius / @min(bounds.width, bounds.height), 8, color);
    } else {
        rl.drawRectangleRec(rect, color);
    }
}

fn drawText(config: clay.TextRenderData, bounds: clay.BoundingBox) void {
    // Use a temporary arena allocator to avoid large stack allocation
    // Emscripten requires c_allocator (page_allocator fails silently in WASM)
    const backing_allocator = if (@import("builtin").os.tag == .emscripten)
        std.heap.c_allocator
    else
        std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text_slice = config.string_contents.chars[0..@intCast(config.string_contents.length)];
    const text_nt = allocator.allocSentinel(u8, text_slice.len, 0) catch {
        std.debug.print("Failed to allocate for drawText\n", .{});
        return;
    };
    @memcpy(text_nt[0..text_slice.len], text_slice);

    const color = clayColorToRaylib(config.text_color);

    rl.drawText(
        text_nt,
        @intFromFloat(bounds.x),
        @intFromFloat(bounds.y),
        @intCast(config.font_size),
        color,
    );
}

fn drawImage(config: clay.ImageRenderData, bounds: clay.BoundingBox) void {
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

fn drawBorder(config: clay.BorderRenderData, bounds: clay.BoundingBox) void {
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
    const thickness: f32 = @floatFromInt(@max(@max(config.width.left, config.width.right), @max(config.width.top, config.width.bottom)));

    rl.drawRectangleLinesEx(rect, thickness, color);
}

fn startScissor(bounds: clay.BoundingBox) void {
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

fn clayColorToRaylib(color: clay.Color) rl.Color {
    return rl.Color{
        .r = @intFromFloat(color[0]),
        .g = @intFromFloat(color[1]),
        .b = @intFromFloat(color[2]),
        .a = @intFromFloat(color[3]),
    };
}
