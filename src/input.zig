/// Input module — re-exports from labelle-core interface + engine-owned types.
const core = @import("labelle-core");
pub const InputInterface = core.InputInterface;
pub const StubInput = core.StubInput;

// Engine-owned input types (backend-agnostic)
pub const input_types = @import("input_types.zig");
pub const KeyboardKey = input_types.KeyboardKey;
pub const MouseButton = input_types.MouseButton;
pub const MousePosition = input_types.MousePosition;
pub const Touch = input_types.Touch;
pub const TouchPhase = input_types.TouchPhase;
pub const MAX_TOUCHES = input_types.MAX_TOUCHES;
pub const GamepadButton = input_types.GamepadButton;
pub const GamepadAxis = input_types.GamepadAxis;

// Gesture recognition
pub const gestures_mod = @import("gestures.zig");
pub const Gestures = gestures_mod.Gestures;
pub const SwipeDirection = gestures_mod.SwipeDirection;
pub const Pinch = gestures_mod.Pinch;
pub const Pan = gestures_mod.Pan;
pub const Swipe = gestures_mod.Swipe;
pub const Tap = gestures_mod.Tap;
pub const DoubleTap = gestures_mod.DoubleTap;
pub const LongPress = gestures_mod.LongPress;
pub const Rotation = gestures_mod.Rotation;
