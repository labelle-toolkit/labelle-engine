//! sokol_imgui Zig Bindings
//!
//! Provides Zig bindings for sokol_imgui - ImGui rendering on top of sokol_gfx.
//! sokol_imgui.c is compiled separately to avoid modifying sokol's dependency hash.
//!
//! See: https://github.com/floooh/sokol

const c = @cImport({
    @cDefine("SOKOL_IMGUI_NO_SOKOL_APP", ""); // We handle input manually via sokol_app events
    @cInclude("sokol_gfx.h"); // Required before sokol_imgui.h
    @cInclude("sokol_app.h"); // For sapp_isvalid() to check if app is running
    @cInclude("sokol_imgui.h");
});

/// Check if sokol_gfx is initialized and valid
pub fn isGfxValid() bool {
    return c.sg_isvalid();
}

/// Check if sokol_app is in a valid state (required for simgui_setup on Metal)
/// sokol_app's internal _sapp.valid is only true during callbacks
pub fn isAppValid() bool {
    // sapp_isvalid() returns true if sokol_app was initialized and is running
    return c.sapp_isvalid();
}

// Re-export C types
pub const Desc = c.simgui_desc_t;
pub const FrameDesc = c.simgui_frame_desc_t;
pub const FontTexDesc = c.simgui_font_tex_desc_t;
pub const Allocator = c.simgui_allocator_t;
pub const Logger = c.simgui_logger_t;
pub const ImageDesc = c.simgui_image_desc_t;

// Lifecycle functions
pub fn setup(desc: Desc) void {
    c.simgui_setup(&desc);
}

pub fn shutdown() void {
    c.simgui_shutdown();
}

// Frame management
pub fn newFrame(desc: FrameDesc) void {
    c.simgui_new_frame(&desc);
}

pub fn render() void {
    c.simgui_render();
}

// Font texture
pub fn createFontsTexture(desc: FontTexDesc) void {
    c.simgui_create_fonts_texture(&desc);
}

pub fn destroyFontsTexture() void {
    c.simgui_destroy_fonts_texture();
}

// Image/texture utilities
pub fn makeImage(desc: ImageDesc) c.simgui_image_t {
    return c.simgui_make_image(&desc);
}

pub fn destroyImage(img: c.simgui_image_t) void {
    c.simgui_destroy_image(img);
}

pub fn queryImageDesc(img: c.simgui_image_t) ImageDesc {
    return c.simgui_query_image_desc(img);
}

pub fn imtextureid(img: c.simgui_image_t) u64 {
    return c.simgui_imtextureid(img);
}

pub fn imageFromImtextureid(id: u64) c.simgui_image_t {
    return c.simgui_image_from_imtextureid(id);
}

// sokol_app window dimension accessors
pub fn width() i32 {
    return c.sapp_width();
}

pub fn height() i32 {
    return c.sapp_height();
}

pub fn frameDuration() f64 {
    return c.sapp_frame_duration();
}
