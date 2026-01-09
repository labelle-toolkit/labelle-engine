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

const root = @import("labelle-engine");

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

// Hook system for GUI interactions
pub const hooks = root.gui_hooks;
pub const GuiHook = hooks.GuiHook;
pub const GuiHookPayload = hooks.GuiHookPayload;
pub const GuiHookDispatcher = hooks.GuiHookDispatcher;
pub const MergeGuiHooks = hooks.MergeGuiHooks;
pub const EmptyGuiDispatcher = hooks.EmptyGuiDispatcher;
pub const ButtonClickedInfo = hooks.ButtonClickedInfo;
pub const CheckboxChangedInfo = hooks.CheckboxChangedInfo;
pub const SliderChangedInfo = hooks.SliderChangedInfo;
pub const MousePosition = hooks.MousePosition;

// Form state management
pub const form_binder = @import("form_binder.zig");
pub const FormBinder = form_binder.FormBinder;

// Runtime state management
pub const runtime_state = @import("runtime_state.zig");
pub const VisibilityState = runtime_state.VisibilityState;

// Tests
test {
    _ = @import("view.zig");
    _ = @import("types.zig");
    _ = root.gui_hooks;
    _ = @import("form_binder.zig");
    _ = @import("runtime_state.zig");
}
