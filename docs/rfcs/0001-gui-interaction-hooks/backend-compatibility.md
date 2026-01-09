# Backend Compatibility: Immediate Mode vs. Retained Mode

**Status**: Addendum to RFC 0001  
**Date**: 2026-01-09

## Overview

After reviewing the existing GUI backend implementations (raygui, microui, Clay), we discovered that **all current backends use immediate-mode patterns** where widgets return interaction state in the same frame. This has important implications for our hook-based GUI interaction system design.

## Current Backend Architecture

All existing adapters follow this pattern:

```zig
// From widget_renderer.zig
pub fn drawButton(btn: types.Button) bool {
    // ... render button ...
    const clicked = hover and rl.isMouseButtonPressed(.left);
    return clicked;  // ← Immediate return
}

pub fn drawCheckbox(cb: types.Checkbox) bool {
    // ... render checkbox ...
    const clicked = hover and rl.isMouseButtonPressed(.left);
    return clicked;  // ← Immediate return
}

pub fn drawSlider(sl: types.Slider) f32 {
    // ... render slider ...
    return current_value;  // ← Immediate return
}
```

## Backend Types

### Immediate Mode (All Current Backends)

**Characteristics:**
- Widget rendering and interaction happen in the same function call
- Return values indicate interaction state
- No persistent widget state between frames
- Examples: Dear ImGui, Nuklear, raygui, microui

**Interaction Model:**
```zig
// User code
if (gui.button(.{ .id = "submit", .text = "Submit" })) {
    // Button was clicked this frame
    handleSubmit();
}

const new_value = gui.slider(.{ .id = "volume", .value = volume, .min = 0, .max = 1 });
if (new_value != volume) {
    // Slider changed this frame
    volume = new_value;
}
```

### Retained Mode (Clay UI)

**Characteristics:**
- Widget declaration separate from rendering
- State persists between frames
- Events queued for later processing
- Examples: Clay UI, HTML/CSS-like systems

**Interaction Model:**
```zig
// Declaration phase
gui.button(.{ .id = "submit", .text = "Submit" });

// Rendering phase (separate)
gui.render();

// Event processing phase (separate)
for (gui.getEvents()) |event| {
    if (event.type == .button_clicked and eql(event.id, "submit")) {
        handleSubmit();
    }
}
```

## Two Design Strategies

Given that all current backends are immediate-mode, we have two viable strategies:

### Strategy A: Hybrid Approach (RECOMMENDED)

**Keep immediate returns, add optional hook dispatch**

```zig
// Backend adapter
pub fn button(self: *Self, btn: types.Button) bool {
    const clicked = widget.drawButton(btn);
    
    // Also queue hook event if game instance available
    if (clicked) {
        if (getGameInstance()) |game| {
            const payload = GuiHookPayload{
                .button_clicked = .{
                    .element = .{
                        .id = btn.id,
                        .element_type = .button,
                    },
                    .position = rl.getMousePosition(),
                    .button = .left,
                },
            };
            game.queueGuiEvent(payload);
        }
    }
    
    return clicked;  // ← Still return immediately
}
```

**Benefits:**
- ✅ Backward compatible with existing code
- ✅ Works with both immediate-mode and hook-based patterns
- ✅ Low overhead (only queue if game instance set)
- ✅ Developers choose their preferred style

**Usage Example:**
```zig
// Option 1: Traditional immediate-mode (simple cases)
if (gui.button(.{ .id = "quick_button", .text = "Click" })) {
    std.log.info("Clicked!", .{});
}

// Option 2: Hook-based (complex forms)
gui.button(.{ .id = "monster_form.submit", .text = "Create Monster" });
// Handler receives event via hooks, uses FormBinder for automatic state management
```

### Strategy B: Pure Hook-Based

**Remove immediate returns, require hooks for all interactions**

```zig
// Backend adapter
pub fn button(self: *Self, btn: types.Button) void {
    const clicked = widget.drawButton(btn);
    
    if (clicked) {
        const game = getGameInstance() orelse return;
        const payload = GuiHookPayload{ .button_clicked = ... };
        game.queueGuiEvent(payload);
    }
}
```

**Benefits:**
- ✅ Unified event model
- ✅ Consistent with engine's hook architecture
- ✅ Better for complex UIs

**Drawbacks:**
- ❌ Breaking change for existing code
- ❌ Overkill for simple buttons
- ❌ Requires hooks even for trivial interactions

## Recommendation: Strategy A (Hybrid)

The **hybrid approach** provides the best developer experience:

1. **Simple UIs** can use immediate returns without any setup
2. **Complex forms** benefit from hooks + FormBinder with minimal boilerplate
3. **Gradual migration** path for existing code
4. **Zero overhead** for code that doesn't use hooks

## Implementation for Each Backend

### raygui / microui (Already Immediate-Mode)

These backends already return interaction state immediately. We just need to add optional hook dispatch:

```zig
// raygui_adapter.zig
pub fn button(self: *Self, btn: types.Button) bool {
    const clicked = widget.drawButton(btn);
    
    if (clicked and btn.id.len > 0) {
        dispatchButtonClickedHook(btn);
    }
    
    return clicked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    const new_value = widget.drawSlider(sl);
    
    if (new_value != sl.value and sl.id.len > 0) {
        dispatchSliderChangedHook(sl, new_value);
    }
    
    return new_value;
}

pub fn checkbox(self: *Self, cb: types.Checkbox) bool {
    const clicked = widget.drawCheckbox(cb);
    
    if (clicked and cb.id.len > 0) {
        dispatchCheckboxToggledHook(cb, !cb.checked);
    }
    
    return clicked;
}
```

### Clay UI (Retained Mode)

Clay already separates declaration from rendering, so it naturally fits the hook model:

```zig
// clay/adapter.zig
pub fn button(element: GuiElement) bool {
    // ... existing Clay rendering code ...
    
    const clicked = c.Clay_PointerOver(layout_id) and c.Clay_PointerJustPressed();
    
    if (clicked) {
        dispatchButtonClickedHook(element);
    }
    
    return clicked;  // Can still return for convenience
}
```

### Dear ImGui (If Added)

Dear ImGui is the canonical immediate-mode GUI library:

```zig
// imgui_adapter.zig
pub fn button(self: *Self, btn: types.Button) bool {
    const clicked = imgui.button(btn.text);
    
    if (clicked and btn.id.len > 0) {
        dispatchButtonClickedHook(btn);
    }
    
    return clicked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    var value = sl.value;
    const changed = imgui.sliderFloat("", &value, sl.min, sl.max);
    
    if (changed and sl.id.len > 0) {
        dispatchSliderChangedHook(sl, value);
    }
    
    return value;
}
```

### Nuklear (If Added)

Nuklear is also immediate-mode:

```zig
// nuklear_adapter.zig
pub fn button(self: *Self, btn: types.Button) bool {
    const ctx = &self.nk_context;
    const clicked = nk.button_label(ctx, btn.text) != 0;
    
    if (clicked and btn.id.len > 0) {
        dispatchButtonClickedHook(btn);
    }
    
    return clicked;
}

pub fn slider(self: *Self, sl: types.Slider) f32 {
    const ctx = &self.nk_context;
    var value = sl.value;
    _ = nk.slider_float(ctx, sl.min, &value, sl.max, 0.1);
    
    if (value != sl.value and sl.id.len > 0) {
        dispatchSliderChangedHook(sl, value);
    }
    
    return value;
}
```

## Helper Functions for Hook Dispatch

Create a shared helper module for all backends:

```zig
// In gui/hook_dispatcher.zig (new file)

const std = @import("std");
const GuiHookPayload = @import("../hooks/types.zig").GuiHookPayload;

// Global game instance reference (set during game initialization)
var game_instance: ?*anyopaque = null;

pub fn setGameInstance(game: *anyopaque) void {
    game_instance = game;
}

pub fn dispatchButtonClickedHook(btn: anytype) void {
    const game = game_instance orelse return;
    
    const payload = GuiHookPayload{
        .button_clicked = .{
            .element = .{
                .id = btn.id,
                .element_type = .button,
            },
            .position = getMousePosition(),
            .button = .left,
        },
    };
    
    queueGuiEvent(game, payload);
}

pub fn dispatchSliderChangedHook(slider: anytype, new_value: f32) void {
    const game = game_instance orelse return;
    
    const payload = GuiHookPayload{
        .slider_changed = .{
            .element = .{
                .id = slider.id,
                .element_type = .slider,
            },
            .value = new_value,
            .min = slider.min,
            .max = slider.max,
            .is_dragging = isMouseButtonDown(),
        },
    };
    
    queueGuiEvent(game, payload);
}

pub fn dispatchCheckboxToggledHook(checkbox: anytype, new_state: bool) void {
    const game = game_instance orelse return;
    
    const payload = GuiHookPayload{
        .checkbox_toggled = .{
            .element = .{
                .id = checkbox.id,
                .element_type = .checkbox,
            },
            .checked = new_state,
        },
    };
    
    queueGuiEvent(game, payload);
}

// Backend-agnostic mouse position (backends can override)
fn getMousePosition() struct { x: f32, y: f32 } {
    // Default implementation using raylib (can be overridden per-backend)
    const rl = @import("raylib");
    const pos = rl.getMousePosition();
    return .{ .x = pos.x, .y = pos.y };
}

fn isMouseButtonDown() bool {
    const rl = @import("raylib");
    return rl.isMouseButtonDown(.left);
}

fn queueGuiEvent(game: *anyopaque, payload: GuiHookPayload) void {
    // Type-erase and call game's queueGuiEvent method
    const Game = @import("../engine/game.zig").Game;
    const game_typed: *Game = @ptrCast(@alignCast(game));
    game_typed.queueGuiEvent(payload);
}
```

## Usage Comparison

### Simple Button (No Forms)

**Traditional Immediate-Mode:**
```zig
// No hooks needed
if (gui.button(.{ .text = "Pause" })) {
    game.pause();
}
```

**Hook-Based (Optional):**
```zig
// Define button
gui.button(.{ .id = "pause_button", .text = "Pause" });

// Handler
pub fn button_clicked(payload: GuiHookPayload) void {
    if (std.mem.eql(u8, payload.button_clicked.element.id, "pause_button")) {
        game.pause();
    }
}
```

### Complex Form

**Traditional Immediate-Mode (Verbose):**
```zig
// Must manually manage state
var monster_name: [128:0]u8 = std.mem.zeroes([128:0]u8);
var monster_health: f32 = 100;
var monster_attack: f32 = 10;
var is_boss: bool = false;

// In render loop
gui.textField(.{ .id = "name", .text = &monster_name });
monster_health = gui.slider(.{ .id = "health", .value = monster_health, .min = 1, .max = 1000 });
monster_attack = gui.slider(.{ .id = "attack", .value = monster_attack, .min = 1, .max = 100 });
if (gui.checkbox(.{ .id = "is_boss", .checked = is_boss })) {
    is_boss = !is_boss;
}

if (gui.button(.{ .text = "Create Monster" })) {
    // Manually validate and create
    if (std.mem.len(&monster_name) > 0) {
        createMonster(monster_name, monster_health, monster_attack, is_boss);
    }
}
```

**Hook-Based with FormBinder (Clean):**
```zig
// Define form state once
var monster_form = MonsterFormState{};
const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
const binder = MonsterBinder.init(&monster_form);

// In render loop (no state management needed!)
gui.textField(.{ .id = "monster_form.name" });
gui.slider(.{ .id = "monster_form.health", .value = monster_form.health, .min = 1, .max = 1000 });
gui.slider(.{ .id = "monster_form.attack", .value = monster_form.attack, .min = 1, .max = 100 });
gui.checkbox(.{ .id = "monster_form.is_boss", .checked = monster_form.is_boss });
gui.button(.{ .id = "monster_form.submit", .text = "Create Monster" });

// Handlers (one-liners!)
pub fn text_input_changed(payload: GuiHookPayload) void {
    binder.handleEvent(payload);  // Automatically updates monster_form.name
}

pub fn slider_changed(payload: GuiHookPayload) void {
    binder.handleEvent(payload);  // Automatically updates health/attack
}

pub fn checkbox_toggled(payload: GuiHookPayload) void {
    binder.handleEvent(payload);  // Automatically updates is_boss
}

pub fn button_clicked(payload: GuiHookPayload) void {
    if (monster_form.is_valid) {
        createMonster(monster_form);
    }
}
```

## Performance Considerations

**Immediate Returns:**
- Zero overhead (native to immediate-mode backends)

**Hook Dispatch:**
- Only triggered if element has an ID
- Only queued if game instance is set
- Approximate cost: ~50ns per event (allocation + queue insertion)

**Hybrid Overhead:**
- Simple buttons without IDs: 0ns overhead
- Buttons with IDs + hooks enabled: ~50ns per click
- Forms with 10 fields: ~500ns per frame (only when interacting)

## Migration Strategy

### Phase 1: Add Hook Support (Non-Breaking)
- Add `gui/hook_dispatcher.zig`
- Update backends to dispatch hooks optionally
- Keep existing immediate return values
- Document both usage patterns

### Phase 2: Implement FormBinder
- Add `gui/form_binder.zig`
- Create example forms in documentation
- Show side-by-side comparison with immediate-mode

### Phase 3: Optimize
- Add backend-specific optimizations
- Cache form state pointers
- Batch event processing

## Conclusion

The **hybrid approach (Strategy A)** is recommended because:

1. **Backward compatible**: Existing code continues to work
2. **Flexible**: Developers choose immediate-mode or hooks
3. **Zero overhead**: Only pay for what you use
4. **Best of both worlds**: Simple for simple UIs, powerful for complex forms
5. **Future-proof**: Works with Dear ImGui, Nuklear, and any immediate-mode backend

All four form state management approaches (ECS Components, FormManager, Form Context, FormBinder) work equally well with the hybrid backend strategy.
