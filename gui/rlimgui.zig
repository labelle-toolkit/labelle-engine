//! rlImGui Zig Bindings
//!
//! Provides Zig bindings for rlImGui - a raylib + Dear ImGui integration library.
//! rlImGui uses raylib's input handling and rlgl rendering, avoiding GLFW symbol conflicts.
//!
//! See: https://github.com/raylib-extras/rlImGui

const c = @cImport({
    @cInclude("rlImGui.h");
});

// Re-export raylib types for convenience
pub const Texture = c.Texture;
pub const RenderTexture = c.RenderTexture;
pub const Rectangle = c.Rectangle;
pub const Vector2 = c.Vector2;

// ============================================================================
// Core API
// ============================================================================

/// Sets up ImGui, loads fonts and themes.
/// Calls ImGui_ImplRaylib_Init and sets the theme.
/// @param dark_theme When true (default) the dark theme is used, when false the light theme is used
pub fn setup(dark_theme: bool) void {
    c.rlImGuiSetup(dark_theme);
}

/// Starts a new ImGui frame.
/// Calls ImGui_ImplRaylib_NewFrame, ImGui_ImplRaylib_ProcessEvents, and ImGui::NewFrame together.
pub fn begin() void {
    c.rlImGuiBegin();
}

/// Ends an ImGui frame and submits all ImGui drawing to raylib for processing.
/// Calls ImGui::Render and ImGui_ImplRaylib_RenderDrawData to draw to the current raylib render target.
pub fn end() void {
    c.rlImGuiEnd();
}

/// Cleanup ImGui and unload font atlas.
/// Calls ImGui_ImplRaylib_Shutdown.
pub fn shutdown() void {
    c.rlImGuiShutdown();
}

// ============================================================================
// Advanced Startup API
// ============================================================================

/// Custom initialization - first part.
/// Not needed if you call setup(). Only needed for custom setup code.
/// Must be followed by endInitImGui().
pub fn beginInitImGui() void {
    c.rlImGuiBeginInitImGui();
}

/// Custom initialization - second part.
/// Not needed if you call setup(). Only needed for custom setup code.
/// Must be preceded by beginInitImGui().
pub fn endInitImGui() void {
    c.rlImGuiEndInitImGui();
}

// ============================================================================
// Advanced Update API
// ============================================================================

/// Starts a new ImGui frame with a specified delta time.
/// @param delta_time Delta time in seconds. Any value < 0 will use raylib's GetFrameTime().
pub fn beginDelta(delta_time: f32) void {
    c.rlImGuiBeginDelta(delta_time);
}

// ============================================================================
// Image API Extensions
// ============================================================================

/// Draw a texture as an image in an ImGui Context.
/// Uses the current ImGui cursor position and the full texture size.
pub fn image(tex: *const Texture) void {
    c.rlImGuiImage(tex);
}

/// Draw a texture as an image at a specific size.
/// The image will be scaled up or down to fit as needed.
pub fn imageSize(tex: *const Texture, width: c_int, height: c_int) void {
    c.rlImGuiImageSize(tex, width, height);
}

/// Draw a texture as an image at a specific size (Vector2 version).
pub fn imageSizeV(tex: *const Texture, size: Vector2) void {
    c.rlImGuiImageSizeV(tex, size);
}

/// Draw a portion of a texture as an image at a defined size.
/// Negative values for sourceRect width/height will flip the image.
pub fn imageRect(tex: *const Texture, dest_width: c_int, dest_height: c_int, source_rect: Rectangle) void {
    c.rlImGuiImageRect(tex, dest_width, dest_height, source_rect);
}

/// Draws a render texture as an image, automatically flipping the Y axis.
pub fn imageRenderTexture(render_tex: *const RenderTexture) void {
    c.rlImGuiImageRenderTexture(render_tex);
}

/// Draws a render texture fitted to the available content area, automatically flipping Y axis.
/// @param center When true, the image will be centered in the content area.
pub fn imageRenderTextureFit(render_tex: *const RenderTexture, center: bool) void {
    c.rlImGuiImageRenderTextureFit(render_tex, center);
}

/// Draws a texture as an image button using the full texture size.
/// @return True if the button was clicked.
pub fn imageButton(name: [*:0]const u8, tex: *const Texture) bool {
    return c.rlImGuiImageButton(name, tex);
}

/// Draws a texture as an image button at a specific size.
/// @return True if the button was clicked.
pub fn imageButtonSize(name: [*:0]const u8, tex: *const Texture, size: Vector2) bool {
    return c.rlImGuiImageButtonSize(name, tex, size);
}
