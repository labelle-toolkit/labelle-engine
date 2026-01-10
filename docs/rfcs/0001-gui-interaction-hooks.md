# RFC 0001: GUI Interaction System with Hooks and Form State Management

- **Status**: Draft
- **Issue**: [#210](https://github.com/labelle-toolkit/labelle-engine/issues/210)
- **Start Date**: 2026-01-09
- **Author**: @apotema

## Summary

Design and implement a comprehensive GUI interaction system for labelle-engine that leverages the existing hook system to handle user interactions (button clicks, text input, sliders, checkboxes) with support for complex multi-field forms.

## Motivation

### Current Limitations

The current GUI system has several significant gaps:

1. **Incomplete interaction handling**: The Clay backend doesn't detect button clicks - the `button()` function always returns `false` with a TODO comment
2. **Limited parameter passing**: Callbacks cannot receive rich context about the interaction (text values, slider positions, mouse coordinates)
3. **String-based callback dispatch**: The current system uses runtime string lookups via `on_click` field names, requiring reflection-like code
4. **No form state management pattern**: There's no established pattern for handling complex forms with multiple interdependent fields

### Real-World Requirements

Games frequently need to handle complex UI interactions:

```zig
// Example: Monster creation form
MonsterForm:
  - name_field: TextField
  - health_slider: Slider (0-1000)
  - attack_slider: Slider (0-100)
  - is_boss: Checkbox
  - element_dropdown: Dropdown (fire/water/earth/air)
  - submit_button: Button
  - cancel_button: Button

// Example: Wizard configuration form
WizardForm:
  - wizard_name: TextField
  - spell_slots: Slider (1-10)
  - school_dropdown: Dropdown
  - has_familiar: Checkbox
  - familiar_type: TextField (conditional: only if has_familiar = true)
  - save_button: Button
```

These forms require:
- **Multi-field state management**: Tracking values across multiple inputs
- **Validation**: Per-field and whole-form validation
- **Dynamic behavior**: Fields that appear/disappear based on other field values
- **Type safety**: Compile-time guarantees about field types and handlers
- **Performance**: Zero runtime overhead for event dispatch

## Backend Compatibility

**Important**: All current GUI backends (raygui, microui, Clay) and potential future backends (Dear ImGui, Nuklear) use **immediate-mode patterns** where widgets return interaction state in the same frame.

This RFC adopts a **hybrid approach**:
- Widget methods continue to return values immediately (backward compatible)
- Optionally queue hook events when element IDs are provided
- Developers choose immediate-mode or hooks based on use case
- Zero overhead for simple UIs, powerful hooks for complex forms

See [Backend Compatibility Analysis](./0001-gui-interaction-hooks/backend-compatibility.md) for detailed discussion of immediate-mode vs. retained-mode GUIs and implementation strategies for all backends.

## Detailed Design

### 1. GUI Hook Type System

Create a parallel hook system for GUI events that mirrors the existing `EngineHook` architecture:

```zig
// In gui/hooks.zig (new file)

/// GUI interaction hooks for user input events
pub const GuiHook = enum {
    // Button interactions
    button_clicked,
    button_pressed,
    button_released,
    
    // Text input
    text_input_changed,
    text_input_submitted,
    
    // Checkboxes and toggles
    checkbox_toggled,
    
    // Sliders and numeric inputs
    slider_changed,
    slider_released,
    
    // Selection and focus
    element_focused,
    element_blurred,
    
    // Custom events
    custom_event,
};
```

### 2. Rich Payload Types

Define comprehensive payload types that carry full context:

```zig
/// Information about a GUI element that triggered an event
pub const ElementInfo = struct {
    /// Element ID from .zon definition
    id: []const u8,
    /// Element type (button, checkbox, etc.)
    element_type: GuiElementType,
};

pub const GuiElementType = enum {
    button,
    checkbox,
    slider,
    text_input,
    label,
    panel,
    image,
    custom,
};

/// Payload for button click events
pub const ButtonClickInfo = struct {
    element: ElementInfo,
    /// Mouse position when clicked
    position: struct { x: f32, y: f32 },
    /// Which mouse button (useful for context menus)
    button: MouseButton = .left,
};

pub const MouseButton = enum { left, right, middle };

/// Payload for text input changes
pub const TextInputInfo = struct {
    element: ElementInfo,
    /// Current text value
    text: []const u8,
    /// Was this a submit action (Enter key)?
    submitted: bool = false,
};

/// Payload for checkbox toggle events
pub const CheckboxInfo = struct {
    element: ElementInfo,
    /// New checked state
    checked: bool,
};

/// Payload for slider change events
pub const SliderInfo = struct {
    element: ElementInfo,
    /// New slider value
    value: f32,
    /// Min/max range for context
    min: f32,
    max: f32,
    /// Is user still dragging?
    dragging: bool,
};

/// Payload for custom user-defined events
pub const CustomEventInfo = struct {
    element: ElementInfo,
    /// Custom event name/type
    event_name: []const u8,
    /// Optional payload data
    data: ?*const anyopaque = null,
};

/// Type-safe payload union for GUI hooks
pub const GuiHookPayload = union(GuiHook) {
    button_clicked: ButtonClickInfo,
    button_pressed: ButtonClickInfo,
    button_released: ButtonClickInfo,
    
    text_input_changed: TextInputInfo,
    text_input_submitted: TextInputInfo,
    
    checkbox_toggled: CheckboxInfo,
    
    slider_changed: SliderInfo,
    slider_released: SliderInfo,
    
    element_focused: ElementInfo,
    element_blurred: ElementInfo,
    
    custom_event: CustomEventInfo,
};
```

### 3. Hook Dispatcher Integration

```zig
const hooks = @import("../hooks/mod.zig");

/// Convenience type for creating a GUI hook dispatcher
pub fn GuiHookDispatcher(comptime HookMap: type) type {
    return hooks.HookDispatcher(GuiHook, GuiHookPayload, HookMap);
}

/// Merge multiple GUI hook handler structs
pub fn MergeGuiHooks(comptime handler_structs: anytype) type {
    return hooks.MergeHooks(GuiHook, GuiHookPayload, handler_structs);
}

/// Empty GUI hook dispatcher (no handlers)
pub const EmptyGuiDispatcher = hooks.EmptyDispatcher(GuiHook, GuiHookPayload);
```

### 4. Form State Management - Four Approaches

#### Approach A: ECS Components (Recommended for entity-bound forms)

Form state as ECS components:

```zig
// In components.zig
pub const MonsterFormState = struct {
    name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,
    element: MonsterElement = .fire,
    
    // Form metadata
    is_open: bool = false,
    is_valid: bool = false,
    
    pub const MonsterElement = enum { fire, water, earth, air };
    
    pub fn getName(self: MonsterFormState) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    
    pub fn setName(self: *MonsterFormState, name: []const u8) void {
        const len = @min(name.len, self.name.len - 1);
        @memcpy(self.name[0..len], name[0..len]);
        self.name[len] = 0;
    }
    
    pub fn validate(self: *MonsterFormState) bool {
        const name_len = std.mem.len(&self.name);
        const name_valid = name_len > 0 and name_len <= 32;
        const health_valid = self.health >= 1 and self.health <= 1000;
        const attack_valid = self.attack >= 1 and self.attack <= 100;
        
        self.is_valid = name_valid and health_valid and attack_valid;
        return self.is_valid;
    }
};
```

**Pros**: Type-safe, visible to ECS systems, integrates naturally with game entities
**Cons**: Manual handler wiring, verbose for many forms

#### Approach B: FormManager (Recommended for dynamic forms)

Centralized form state manager:

```zig
pub const FormManager = struct {
    forms: std.StringHashMap(FormState),
    allocator: std.mem.Allocator,
    
    pub const FormState = struct {
        fields: std.StringHashMap(FieldValue),
        is_open: bool,
        is_dirty: bool,
        
        pub const FieldValue = union(enum) {
            text: []const u8,
            number: f32,
            boolean: bool,
            selection: usize,
        };
    };
    
    pub fn createForm(self: *FormManager, form_id: []const u8) !void { ... }
    pub fn setField(self: *FormManager, form_id: []const u8, field_id: []const u8, value: FieldValue) !void { ... }
    pub fn getField(self: *FormManager, form_id: []const u8, field_id: []const u8) ?FieldValue { ... }
    
    /// Get form data as a typed struct
    pub fn getFormData(self: *FormManager, form_id: []const u8, comptime T: type) !T { ... }
};
```

**Pros**: Centralized, generic, runtime flexible
**Cons**: HashMap overhead, less type-safe than ECS approach

#### Approach C: Form Context in Payloads

Automatically populate form context in event payloads:

```zig
pub const FormContext = struct {
    form_id: []const u8,
    field_name: []const u8,
    form_state_ptr: *anyopaque,
    
    pub fn getState(self: FormContext, comptime T: type) *T {
        return @ptrCast(@alignCast(self.form_state_ptr));
    }
};

pub const ElementInfo = struct {
    id: []const u8,
    element_type: GuiElementType,
    form_context: ?FormContext = null,  // ← NEW
};
```

**Pros**: Clean handlers, automatic context passing
**Cons**: Backend complexity, requires form registry

#### Approach D: FormBinder with Comptime Reflection (Recommended for many forms)

Automatic field binding via reflection:

```zig
pub fn FormBinder(comptime T: type) type {
    return struct {
        pub fn bind(form_id: []const u8, state: *T) FormBinding(T) {
            return .{ .form_id = form_id, .state = state };
        }
    };
}

pub fn FormBinding(comptime T: type) type {
    return struct {
        form_id: []const u8,
        state: *T,
        
        pub fn handleEvent(self: @This(), payload: GuiHookPayload) void {
            switch (payload) {
                .text_input_changed => |info| {
                    if (!self.isOurField(info.element.id)) return;
                    const field_name = self.extractFieldName(info.element.id);
                    self.setTextField(field_name, info.text);
                },
                .slider_changed => |info| {
                    if (!self.isOurField(info.element.id)) return;
                    const field_name = self.extractFieldName(info.element.id);
                    self.setNumberField(field_name, info.value);
                },
                else => {},
            }
        }
        
        fn setTextField(self: @This(), field_name: []const u8, value: []const u8) void {
            inline for (@typeInfo(T).Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    // Automatically populate struct field
                }
            }
        }
    };
}

// Usage - single handler for ALL forms!
const MonsterBinder = FormBinder(MonsterFormState);
const WizardBinder = FormBinder(WizardFormState);

pub fn text_input_changed(payload: GuiHookPayload) void {
    monster_binding.handleEvent(payload);
}
```

**Pros**: Automatic binding, minimal code, type-safe, scales to many forms
**Cons**: Comptime complexity, requires naming convention

### 5. Backend Event Queueing

Backends transition from returning values to queueing events:

**Before (immediate return)**:
```zig
pub fn button(self: *Self, btn: types.Button) bool {
    // ... render button ...
    return clicked;  // ← Immediate return
}
```

**After (event queueing)**:
```zig
pub fn button(self: *Self, btn: types.Button) void {
    // ... render button ...
    
    if (clicked) {
        // Queue event for processing at frame end
        self.game_event_queue.append(.{
            .button_clicked = .{
                .element = .{ .id = btn.id, .element_type = .button },
                .position = mouse_position,
                .button = .left,
            },
        }) catch |err| {
            std.log.err("Failed to queue click event: {}", .{err});
        };
    }
}
```

### 6. Element ID Namespacing

Use dot notation for hierarchical organization:

```zig
// In gui/monster_form.zon
.elements = .{
    .{
        .TextField = .{
            .id = "monster_form.name_field",  // ← Namespaced
            .position = .{ .x = 10, .y = 50 },
            .placeholder = "Monster name...",
        },
    },
    .{
        .Slider = .{
            .id = "monster_form.health_slider",  // ← Namespaced
            .position = .{ .x = 10, .y = 130 },
            .min = 0,
            .max = 1000,
        },
    },
    .{
        .Button = .{
            .id = "monster_form.submit",  // ← Namespaced
            .text = "Create Monster",
            .position = .{ .x = 10, .y = 450 },
        },
    },
}
```

Handlers can parse the namespace:

```zig
pub fn text_input_changed(payload: GuiHookPayload) void {
    const info = payload.text_input_changed;
    
    var parts = std.mem.split(u8, info.element.id, ".");
    const form_id = parts.next() orelse return;
    const field_id = parts.next() orelse return;
    
    // Route to appropriate form handler
}
```

### 7. Game Integration

```zig
// In engine/game.zig

pub const GameConfig = struct {
    // ... existing fields ...
    gui_hooks: ?type = null,
};

pub fn Game(comptime config: GameConfig) type {
    const GuiDispatcher = if (config.gui_hooks) |hooks_type|
        gui_hooks_mod.GuiHookDispatcher(hooks_type)
    else
        gui_hooks_mod.EmptyGuiDispatcher;
    
    return struct {
        // ... existing fields ...
        gui_events: std.ArrayList(gui_hooks_mod.GuiHookPayload),
        
        pub fn processGuiEvents(self: *Self) void {
            for (self.gui_events.items) |payload| {
                GuiDispatcher.emit(payload);
            }
            self.gui_events.clearRetainingCapacity();
        }
    };
}
```

## Usage Examples

### Simple Button Handler

```zig
const MyGuiHandlers = struct {
    pub fn button_clicked(payload: GuiHookPayload) void {
        const info = payload.button_clicked;
        
        if (std.mem.eql(u8, info.element.id, "start_button")) {
            std.log.info("Starting game!", .{});
        } else if (std.mem.eql(u8, info.element.id, "quit_button")) {
            std.log.info("Quitting...", .{});
        }
    }
};
```

### Complex Form with FormBinder

```zig
// Define form state
pub const MonsterFormState = struct {
    name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,
};

// Create binder
const MonsterBinder = FormBinder(MonsterFormState);

// In game init
var monster_form_state = MonsterFormState{};
const monster_binding = MonsterBinder.bind("monster_form", &monster_form_state);

// Single handler for all events!
const MyGuiHandlers = struct {
    pub fn text_input_changed(payload: GuiHookPayload) void {
        monster_binding.handleEvent(payload);
    }

    pub fn slider_changed(payload: GuiHookPayload) void {
        monster_binding.handleEvent(payload);
    }
    
    pub fn button_clicked(payload: GuiHookPayload) void {
        const info = payload.button_clicked;
        
        if (std.mem.eql(u8, info.element.id, "monster_form.submit")) {
            // Form state is already populated by bindings!
            if (validateMonsterForm(&monster_form_state)) {
                createMonster(&monster_form_state);
            }
        }
    }
};
```

## Drawbacks

1. **API Breaking Change**: Backends transition from `button() bool` to `button() void`
   - **Mitigation**: Phased migration with deprecation warnings

2. **Backend Complexity**: Backends need event queue management
   - **Mitigation**: Provide helper utilities and clear documentation

3. **Comptime Complexity**: FormBinder uses advanced comptime reflection
   - **Mitigation**: Offer multiple approaches (ECS, FormManager, FormBinder)

4. **Memory Overhead**: Event queue allocations per frame
   - **Mitigation**: Use clearRetainingCapacity() to reuse allocations

5. **Learning Curve**: Developers need to understand hook system
   - **Mitigation**: Comprehensive examples and migration guide

## Alternatives Considered

### Alternative 1: Keep Immediate Return Values

Keep `button() bool` API and add hooks as optional enhancement.

**Pros**: No breaking changes
**Cons**: Inconsistent patterns, doesn't solve parameter passing, maintained dual systems

### Alternative 2: Callback Function Pointers

Store function pointers in element definitions:

```zig
.Button = .{
    .text = "Click Me",
    .on_click = &myButtonHandler,
}
```

**Pros**: Direct function calls, type-safe
**Cons**: Can't serialize .zon files with function pointers, comptime limitations

### Alternative 3: Message Queue with Custom Events

Generic message queue system for all game events:

```zig
pub const GameMessage = union(enum) {
    gui_button_click: ButtonClickInfo,
    entity_spawned: EntityInfo,
    level_complete: LevelInfo,
};
```

**Pros**: Unified event system for entire game
**Cons**: Overkill for GUI, mixes concerns, harder to reason about

## Open Questions

1. **Form State Primary Approach**: Which of the four form management approaches should be the "blessed" pattern in examples?
   - **Recommendation**: Use FormBinder (Approach D) for examples, document all four approaches

2. **Backward Compatibility**: Should we maintain `on_click` string callbacks during transition?
   - **Recommendation**: Yes, for one major version with deprecation warnings

3. **Validation Strategy**: Per-field validation vs whole-form validation?
   - **Recommendation**: Support both - per-field for immediate feedback, whole-form for submission

4. **Form Context Population**: Should backends automatically populate form context?
   - **Recommendation**: Yes, but make it opt-in via backend configuration

5. **Dynamic Field Visibility**: How to handle conditional fields (e.g., familiar_type only visible when has_familiar=true)?
   - **Recommendation**: Handle in view rendering logic based on form state

6. **Text Input Performance**: How to handle text input events efficiently (per-keystroke vs debounced)?
   - **Recommendation**: Emit on every change, let handlers decide if they want to debounce

## Implementation Plan

### Phase 1: Foundation (Week 1)
- [ ] Create `gui/hooks.zig` with types
- [ ] Implement `GuiHookDispatcher` and `MergeGuiHooks`
- [ ] Add `gui_events` queue to Game struct
- [ ] Implement `processGuiEvents()` in Game

### Phase 2: FormBinder (Week 2)
- [ ] Implement `FormBinder` with comptime reflection
- [ ] Add `setTextField`, `setNumberField`, `setBoolField` helpers
- [ ] Write unit tests for automatic field binding
- [ ] Document FormBinder usage patterns

### Phase 3: Backend Updates (Week 3)
- [ ] Update Clay backend with event queueing
- [ ] Implement Clay click detection with `Clay_PointerOver()`
- [ ] Update raygui backend with event queueing
- [ ] Update microui backend with event queueing

### Phase 4: Examples (Week 4)
- [ ] Create MonsterForm example with all field types
- [ ] Create WizardForm example with conditional fields
- [ ] Add validation examples (per-field and whole-form)
- [ ] Document all four form management approaches

### Phase 5: Migration & Documentation (Week 5)
- [ ] Write migration guide from string callbacks to hooks
- [ ] Add deprecation warnings to old `on_click` system
- [ ] Update all existing examples to use hooks
- [ ] Add performance benchmarks

## Success Metrics

- ✅ All GUI backends support event queueing
- ✅ Zero runtime overhead for hook dispatch (comptime only)
- ✅ MonsterForm and WizardForm examples working
- ✅ Migration guide written
- ✅ Performance benchmarks show no regression
- ✅ At least 80% test coverage for new code

## References

- [labelle-engine hooks system](../../hooks/mod.zig)
- [Clay UI library](https://github.com/nicbarker/clay)
- [Current GUI interface](../../gui/interface.zig)
- [Issue #210](https://github.com/labelle-toolkit/labelle-engine/issues/210)
- [Backend Compatibility Analysis](./0001-gui-interaction-hooks/backend-compatibility.md) - Immediate-mode vs. retained-mode GUIs
- [Approach A: ECS Components](./0001-gui-interaction-hooks/approach-a-ecs-components.md)
- [Approach B: FormManager](./0001-gui-interaction-hooks/approach-b-formmanager.md)
- [Approach C: Form Context](./0001-gui-interaction-hooks/approach-c-form-context.md)
- [Approach D: FormBinder (Recommended)](./0001-gui-interaction-hooks/approach-d-formbinder.md)

## Revision History

- **2026-01-09**: Initial draft by @apotema
- **2026-01-09**: Added backend compatibility analysis for Dear ImGui/Nuklear
- **2026-01-09**: Added detailed approach documents (A, B, C, D)
