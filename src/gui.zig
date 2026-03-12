/// GUI module — re-exports from labelle-core interface + engine-owned types.
const core = @import("labelle-core");
pub const GuiInterface = core.GuiInterface;
pub const StubGui = core.StubGui;

// Engine-owned GUI types (backend-agnostic)
pub const gui_types = @import("gui_types.zig");
pub const GuiColor = gui_types.GuiColor;
pub const GuiPosition = gui_types.GuiPosition;
pub const GuiSize = gui_types.GuiSize;
pub const Label = gui_types.Label;
pub const Button = gui_types.Button;
pub const ProgressBar = gui_types.ProgressBar;
pub const Panel = gui_types.Panel;
pub const Image = gui_types.Image;
pub const Checkbox = gui_types.Checkbox;
pub const Slider = gui_types.Slider;
pub const GuiElement = gui_types.GuiElement;

// View registry for declarative GUI
pub const gui_view = @import("gui_view.zig");
pub const ViewDef = gui_view.ViewDef;
pub const ViewRegistry = gui_view.ViewRegistry;
pub const EmptyViewRegistry = gui_view.EmptyViewRegistry;
