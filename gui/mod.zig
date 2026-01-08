//! GUI Module
//!
//! Declarative GUI system with multi-backend support.
//! Provides immediate-mode rendering with retained view definitions.
//!
//! ## Features
//! - Multiple backend support (raygui, imgui, nuklear, microui)
//! - Declarative views in .zon files
//! - Runtime element access and modification
//! - Script callback integration
//!
//! ## Example
//! ```zig
//! const gui = @import("labelle-engine").gui;
//!
//! // Define views registry
//! const Views = gui.ViewRegistry(.{
//!     .hud = @import("gui/hud.zon"),
//! });
//!
//! // Load and render
//! game.loadGuiView(Views, "hud");
//! game.renderGui(Scripts);
//! ```

// Backend interface
pub const interface = @import("interface.zig");
pub const Gui = interface.Gui;
pub const GuiBackend = interface.GuiBackend;

// Element types
pub const types = @import("types.zig");
pub const GuiElement = types.GuiElement;
pub const Label = types.Label;
pub const Button = types.Button;
pub const ProgressBar = types.ProgressBar;
pub const Panel = types.Panel;
pub const Image = types.Image;
pub const Checkbox = types.Checkbox;
pub const Slider = types.Slider;
pub const Color = types.Color;
pub const Position = types.Position;
pub const Size = types.Size;

// View registry
pub const view = @import("view.zig");
pub const ViewRegistry = view.ViewRegistry;
pub const ViewDef = view.ViewDef;
pub const EmptyViewRegistry = view.EmptyViewRegistry;

// Tests
test {
    _ = @import("view.zig");
    _ = @import("types.zig");
}
