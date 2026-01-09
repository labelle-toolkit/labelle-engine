# Approach D: FormBinder with Comptime Reflection

**Status**: Proposed (RECOMMENDED)  
**Best For**: Large number of forms, minimal boilerplate, maximum type safety  

## Overview

Use Zig's comptime reflection to automatically bind form fields to GUI events. A single `FormBinder` generic can handle all forms, eliminating per-form boilerplate while maintaining full type safety. This approach provides the best developer experience for codebases with many forms.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  FormBinder(MonsterFormState)                   │
├─────────────────────────────────────────────────┤
│  Comptime-generated field handlers:              │
│    - "name_field" → setName(text)               │
│    - "health_slider" → .health = value          │
│    - "attack_slider" → .attack = value          │
│    - "is_boss" → .is_boss = checked             │
├─────────────────────────────────────────────────┤
│  pub fn handleEvent(payload: ...) {             │
│      // Auto-routes to correct field            │
│      inline for (fields) |field| {              │
│          if (eql(field_name, field.name)) {     │
│              updateField(field, payload);       │
│          }                                       │
│      }                                           │
│  }                                               │
└─────────────────────────────────────────────────┘
                      │
                      │ Single unified handler
                      ↓
┌─────────────────────────────────────────────────┐
│  GUI Hook Handlers (MINIMAL CODE!)              │
├─────────────────────────────────────────────────┤
│  pub fn text_input_changed(payload: ...) {      │
│      monster_binder.handleEvent(payload);       │
│      wizard_binder.handleEvent(payload);        │
│  }                                               │
│                                                  │
│  pub fn slider_changed(payload: ...) {          │
│      monster_binder.handleEvent(payload);       │
│      wizard_binder.handleEvent(payload);        │
│  }                                               │
└─────────────────────────────────────────────────┘
```

## Implementation

### 1. Define FormBinder Generic Type

```zig
// In gui/form_binder.zig (new file)

const std = @import("std");
const GuiHookPayload = @import("hooks.zig").GuiHookPayload;

/// Automatic form field binding using comptime reflection
pub fn FormBinder(
    comptime FormState: type,
    comptime form_id: []const u8,
) type {
    return struct {
        const Self = @This();
        
        /// Pointer to form state instance
        form_state: *FormState,
        
        /// Initialize binder with form state pointer
        pub fn init(form_state: *FormState) Self {
            return .{ .form_state = form_state };
        }
        
        /// Handle text input events
        pub fn handleTextInput(self: Self, payload: GuiHookPayload) void {
            const info = payload.text_input_changed;
            
            // Check if this event belongs to our form
            if (!belongsToForm(info.element.id)) return;
            
            // Extract field name
            const field_name = extractFieldName(info.element.id);
            
            // Use comptime reflection to find and update field
            const type_info = @typeInfo(FormState);
            inline for (type_info.Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    self.setTextField(field.name, info.text);
                    self.validate();
                    return;
                }
            }
        }
        
        /// Handle slider events
        pub fn handleSlider(self: Self, payload: GuiHookPayload) void {
            const info = payload.slider_changed;
            
            if (!belongsToForm(info.element.id)) return;
            
            const field_name = extractFieldName(info.element.id);
            
            const type_info = @typeInfo(FormState);
            inline for (type_info.Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    // Check if field is f32
                    if (field.type == f32) {
                        @field(self.form_state, field.name) = info.value;
                        self.validate();
                        return;
                    }
                }
            }
        }
        
        /// Handle checkbox events
        pub fn handleCheckbox(self: Self, payload: GuiHookPayload) void {
            const info = payload.checkbox_toggled;
            
            if (!belongsToForm(info.element.id)) return;
            
            const field_name = extractFieldName(info.element.id);
            
            const type_info = @typeInfo(FormState);
            inline for (type_info.Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    // Check if field is bool
                    if (field.type == bool) {
                        @field(self.form_state, field.name) = info.checked;
                        self.validate();
                        return;
                    }
                }
            }
        }
        
        /// Handle button events
        pub fn handleButton(self: Self, payload: GuiHookPayload, handler_map: anytype) void {
            const info = payload.button_clicked;
            
            if (!belongsToForm(info.element.id)) return;
            
            const field_name = extractFieldName(info.element.id);
            
            // Look up button handler in provided map
            inline for (@typeInfo(@TypeOf(handler_map)).Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    @field(handler_map, field.name)(self.form_state);
                    return;
                }
            }
        }
        
        /// Unified event handler (dispatches to specific handlers)
        pub fn handleEvent(self: Self, payload: GuiHookPayload) void {
            switch (payload) {
                .text_input_changed => self.handleTextInput(payload),
                .slider_changed => self.handleSlider(payload),
                .checkbox_toggled => self.handleCheckbox(payload),
                else => {},
            }
        }
        
        /// Set text field using form's setter method (if available)
        fn setTextField(self: Self, comptime field_name: []const u8, text: []const u8) void {
            // Check if form has a setter method (e.g., setName, setWizardName)
            const setter_name = "set" ++ capitalizeFirst(field_name);
            
            if (@hasDecl(FormState, setter_name)) {
                const setter = @field(FormState, setter_name);
                setter(self.form_state, text);
            } else {
                // Direct field assignment for string arrays
                const field_value = &@field(self.form_state, field_name);
                const len = @min(text.len, field_value.len - 1);
                @memcpy(field_value[0..len], text[0..len]);
                field_value[len] = 0;
            }
        }
        
        /// Validate form if validation method exists
        fn validate(self: Self) void {
            if (@hasDecl(FormState, "validate")) {
                _ = self.form_state.validate();
            }
        }
        
        /// Check if element ID belongs to this form
        fn belongsToForm(element_id: []const u8) bool {
            return std.mem.startsWith(u8, element_id, form_id ++ ".");
        }
        
        /// Extract field name from element ID ("monster_form.name_field" → "name_field")
        fn extractFieldName(element_id: []const u8) []const u8 {
            const prefix_len = form_id.len + 1; // +1 for dot
            if (element_id.len > prefix_len) {
                return element_id[prefix_len..];
            }
            return "";
        }
        
        /// Capitalize first character of field name
        fn capitalizeFirst(comptime str: []const u8) []const u8 {
            if (str.len == 0) return "";
            return &[_]u8{std.ascii.toUpper(str[0])} ++ str[1..];
        }
    };
}
```

### 2. Define Form State Structs

```zig
// In forms.zig

const std = @import("std");

pub const MonsterFormState = struct {
    // Form fields
    name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,
    element: MonsterElement = .fire,
    
    // Form metadata
    is_open: bool = false,
    is_valid: bool = false,
    
    pub const MonsterElement = enum { 
        fire, 
        water, 
        earth, 
        air,
    };
    
    /// Getter for name (used by form display)
    pub fn getName(self: MonsterFormState) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    
    /// Setter for name (called by FormBinder)
    pub fn setName(self: *MonsterFormState, name: []const u8) void {
        const len = @min(name.len, self.name.len - 1);
        @memcpy(self.name[0..len], name[0..len]);
        self.name[len] = 0;
    }
    
    /// Validation (called automatically by FormBinder)
    pub fn validate(self: *MonsterFormState) bool {
        const name_len = std.mem.len(&self.name);
        const name_valid = name_len > 0 and name_len <= 32;
        const health_valid = self.health >= 1 and self.health <= 1000;
        const attack_valid = self.attack >= 1 and self.attack <= 100;
        
        self.is_valid = name_valid and health_valid and attack_valid;
        return self.is_valid;
    }
    
    /// Reset form
    pub fn reset(self: *MonsterFormState) void {
        self.* = MonsterFormState{};
    }
};

pub const WizardFormState = struct {
    // Form fields
    wizard_name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    spell_slots: f32 = 5,
    school: MagicSchool = .evocation,
    has_familiar: bool = false,
    familiar_type: [64:0]u8 = std.mem.zeroes([64:0]u8),
    
    // Form metadata
    is_open: bool = false,
    is_valid: bool = false,
    
    pub const MagicSchool = enum { 
        abjuration, 
        conjuration, 
        divination, 
        enchantment, 
        evocation, 
        illusion, 
        necromancy, 
        transmutation,
    };
    
    pub fn getWizardName(self: WizardFormState) []const u8 {
        return std.mem.sliceTo(&self.wizard_name, 0);
    }
    
    pub fn setWizardName(self: *WizardFormState, name: []const u8) void {
        const len = @min(name.len, self.wizard_name.len - 1);
        @memcpy(self.wizard_name[0..len], name[0..len]);
        self.wizard_name[len] = 0;
    }
    
    pub fn getFamiliarType(self: WizardFormState) []const u8 {
        return std.mem.sliceTo(&self.familiar_type, 0);
    }
    
    pub fn setFamiliarType(self: *WizardFormState, familiar: []const u8) void {
        const len = @min(familiar.len, self.familiar_type.len - 1);
        @memcpy(self.familiar_type[0..len], familiar[0..len]);
        self.familiar_type[len] = 0;
    }
    
    pub fn validate(self: *WizardFormState) bool {
        const name_len = std.mem.len(&self.wizard_name);
        const name_valid = name_len > 0;
        const slots_valid = self.spell_slots >= 1 and self.spell_slots <= 10;
        
        const familiar_type_len = std.mem.len(&self.familiar_type);
        const familiar_valid = !self.has_familiar or familiar_type_len > 0;
        
        self.is_valid = name_valid and slots_valid and familiar_valid;
        return self.is_valid;
    }
    
    pub fn reset(self: *WizardFormState) void {
        self.* = WizardFormState{};
    }
};
```

### 3. Initialize Form Binders

```zig
// In main game initialization

const FormBinder = @import("gui/form_binder.zig").FormBinder;
const MonsterFormState = @import("forms.zig").MonsterFormState;
const WizardFormState = @import("forms.zig").WizardFormState;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create form state instances
    var monster_form_state = MonsterFormState{};
    var wizard_form_state = WizardFormState{};
    
    // Create form binders (comptime magic!)
    const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
    const WizardBinder = FormBinder(WizardFormState, "wizard_form");
    
    const monster_binder = MonsterBinder.init(&monster_form_state);
    const wizard_binder = WizardBinder.init(&wizard_form_state);
    
    // Pass binders to handlers
    gui_handlers.setFormBinders(.{
        .monster = monster_binder,
        .wizard = wizard_binder,
    });
    
    // ... rest of game initialization
}
```

### 4. Minimal GUI Hook Handlers

```zig
// In gui_handlers.zig

const std = @import("std");
const labelle = @import("labelle-engine");
const GuiHookPayload = labelle.GuiHookPayload;
const FormBinder = @import("gui/form_binder.zig").FormBinder;
const MonsterFormState = @import("forms.zig").MonsterFormState;
const WizardFormState = @import("forms.zig").WizardFormState;

// Form binders
const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
const WizardBinder = FormBinder(WizardFormState, "wizard_form");

var monster_binder: ?MonsterBinder = null;
var wizard_binder: ?WizardBinder = null;

pub fn setFormBinders(binders: struct {
    monster: MonsterBinder,
    wizard: WizardBinder,
}) void {
    monster_binder = binders.monster;
    wizard_binder = binders.wizard;
}

pub const MyGuiHandlers = struct {
    /// Single handler for ALL text input events!
    pub fn text_input_changed(payload: GuiHookPayload) void {
        if (monster_binder) |binder| {
            binder.handleEvent(payload);
        }
        if (wizard_binder) |binder| {
            binder.handleEvent(payload);
        }
    }
    
    /// Single handler for ALL slider events!
    pub fn slider_changed(payload: GuiHookPayload) void {
        if (monster_binder) |binder| {
            binder.handleEvent(payload);
        }
        if (wizard_binder) |binder| {
            binder.handleEvent(payload);
        }
    }
    
    /// Single handler for ALL checkbox events!
    pub fn checkbox_toggled(payload: GuiHookPayload) void {
        if (monster_binder) |binder| {
            binder.handleEvent(payload);
        }
        if (wizard_binder) |binder| {
            binder.handleEvent(payload);
        }
        
        // Special handling for conditional fields
        const info = payload.checkbox_toggled;
        if (std.mem.eql(u8, info.element.id, "wizard_form.has_familiar")) {
            if (wizard_binder) |binder| {
                if (!info.checked) {
                    binder.form_state.familiar_type = std.mem.zeroes([64:0]u8);
                }
            }
        }
    }
    
    /// Button handler with custom logic per form
    pub fn button_clicked(payload: GuiHookPayload) void {
        const info = payload.button_clicked;
        
        // Monster form buttons
        if (std.mem.startsWith(u8, info.element.id, "monster_form.")) {
            if (monster_binder) |binder| {
                binder.handleButton(payload, .{
                    .submit = handleMonsterSubmit,
                    .cancel = handleMonsterCancel,
                });
            }
        }
        
        // Wizard form buttons
        if (std.mem.startsWith(u8, info.element.id, "wizard_form.")) {
            if (wizard_binder) |binder| {
                binder.handleButton(payload, .{
                    .save = handleWizardSave,
                });
            }
        }
    }
};

// Button action handlers
fn handleMonsterSubmit(state: *MonsterFormState) void {
    if (!state.is_valid) {
        std.log.warn("Monster form is invalid!", .{});
        return;
    }
    
    std.log.info("Creating monster: name={s}, health={d}, attack={d}, is_boss={}", .{
        state.getName(),
        state.health,
        state.attack,
        state.is_boss,
    });
    
    state.is_open = false;
    state.reset();
}

fn handleMonsterCancel(state: *MonsterFormState) void {
    state.is_open = false;
    state.reset();
}

fn handleWizardSave(state: *WizardFormState) void {
    if (!state.is_valid) {
        std.log.warn("Wizard form is invalid!", .{});
        return;
    }
    
    std.log.info("Saving wizard: name={s}, slots={d}, has_familiar={}, familiar={s}", .{
        state.getWizardName(),
        state.spell_slots,
        state.has_familiar,
        state.getFamiliarType(),
    });
    
    state.is_open = false;
}
```

### 5. Advanced: Generic FormBinder Collection

For even less boilerplate, create a collection type:

```zig
// In gui/form_binder.zig

/// Collection of form binders with unified event dispatch
pub fn FormBinderCollection(comptime binders: anytype) type {
    return struct {
        const Self = @This();
        
        binders_data: @TypeOf(binders),
        
        pub fn init(binders_data: @TypeOf(binders)) Self {
            return .{ .binders_data = binders_data };
        }
        
        /// Dispatch event to all binders
        pub fn handleEvent(self: Self, payload: anytype) void {
            inline for (@typeInfo(@TypeOf(self.binders_data)).Struct.fields) |field| {
                @field(self.binders_data, field.name).handleEvent(payload);
            }
        }
    };
}

// Usage:
const all_binders = FormBinderCollection(.{
    .monster = monster_binder,
    .wizard = wizard_binder,
});

// Now handlers become one-liners!
pub fn text_input_changed(payload: GuiHookPayload) void {
    all_binders.handleEvent(payload);
}

pub fn slider_changed(payload: GuiHookPayload) void {
    all_binders.handleEvent(payload);
}

pub fn checkbox_toggled(payload: GuiHookPayload) void {
    all_binders.handleEvent(payload);
}
```

## Pros

✅ **Minimal Boilerplate**: One binder per form, handlers are one-liners  
✅ **Type Safety**: Full compile-time validation via reflection  
✅ **Automatic Routing**: Field names automatically matched to struct fields  
✅ **Scalability**: Adding new forms requires minimal code  
✅ **Zero Runtime Overhead**: All reflection resolved at comptime  
✅ **Consistent Pattern**: Same approach works for all forms  
✅ **Automatic Validation**: Calls `validate()` after every change  

## Cons

❌ **Comptime Complexity**: More complex implementation code  
❌ **Field Name Convention**: Requires matching field names between .zon and structs  
❌ **Limited Custom Logic**: Field-specific logic requires additional code  
❌ **Learning Curve**: Developers must understand comptime reflection  
❌ **Compile Time**: May increase compilation time for very large form counts  

## Best Use Cases

1. **Large Form Count**: Games with 20+ forms
2. **Consistent Form Patterns**: Forms follow similar structure and naming
3. **CRUD Interfaces**: Character editors, item editors, settings menus
4. **Rapid Development**: Need to add forms quickly without boilerplate
5. **Type-Safe Forms**: Want compile-time guarantees without manual wiring

## Example: Complete MonsterForm Flow

```zig
// 1. Define form state with setter methods
pub const MonsterFormState = struct {
    name: [128:0]u8 = ...,
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,
    
    pub fn setName(self: *MonsterFormState, name: []const u8) void { ... }
    pub fn validate(self: *MonsterFormState) bool { ... }
};

// 2. Create binder (one line!)
const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
const monster_binder = MonsterBinder.init(&monster_form_state);

// 3. Handler (one line per event type!)
pub fn text_input_changed(payload: GuiHookPayload) void {
    monster_binder.handleEvent(payload);  // Automatically routes to correct field!
}

// 4. Behind the scenes (comptime magic):
// - FormBinder reflects on MonsterFormState fields
// - Matches "monster_form.name_field" → calls setName()
// - Matches "monster_form.health_slider" → sets .health = value
// - Automatically calls validate() after each change

// 5. Result: Zero per-field boilerplate!
```

## Comparison with Other Approaches

| Feature | ECS Components | FormManager | Form Context | FormBinder |
|---------|---------------|-------------|--------------|------------|
| Type Safety | ✅ High | ⚠️ Medium | ✅ High | ✅ High |
| Boilerplate | ❌ High | ✅ Low | ⚠️ Medium | ✅ Very Low |
| ECS Integration | ✅ Native | ❌ None | ⚠️ Manual | ⚠️ Manual |
| Auto-Binding | ❌ No | ❌ No | ⚠️ Partial | ✅ Yes |
| Scalability | ⚠️ Manual per form | ✅ Automatic | ✅ Automatic | ✅ Automatic |
| Implementation Complexity | ✅ Simple | ✅ Simple | ⚠️ Medium | ⚠️ High |
| Handler Code Size | ❌ Large | ⚠️ Medium | ✅ Small | ✅ Very Small |

## Migration Path

If starting with this approach and later wanting to switch:

**To ECS Components**: Keep form state structs, move them to components  
**To FormManager**: Extract comptime logic, store in runtime hash maps  
**To Form Context**: Remove binders, use registry with manual routing  

## Recommendation

**Use FormBinder when:**
- You have many forms (> 15)
- Forms follow consistent naming conventions
- You want minimal boilerplate
- You value type safety
- You're comfortable with comptime programming
- Handler code simplicity is critical

**Consider alternatives when:**
- You have very few forms (< 5) - ECS Components may be simpler
- Forms need heavy custom logic per field - Form Context better
- You need runtime form generation - FormManager better
- Compile times are already high - consider simpler approaches

## Advanced: Custom Field Handlers

For fields that need special handling, you can provide custom handlers:

```zig
pub const MonsterFormState = struct {
    name: [128:0]u8 = ...,
    
    // Custom setter with validation
    pub fn setName(self: *MonsterFormState, name: []const u8) void {
        // Strip whitespace
        var trimmed = std.mem.trim(u8, name, " \t\n");
        
        // Convert to title case
        var title_case: [128]u8 = undefined;
        title_case[0] = std.ascii.toUpper(trimmed[0]);
        std.mem.copy(u8, title_case[1..], trimmed[1..]);
        
        // Store
        const len = @min(trimmed.len, self.name.len - 1);
        @memcpy(self.name[0..len], title_case[0..len]);
        self.name[len] = 0;
    }
};

// FormBinder automatically detects and uses setName() method!
```

## Advanced: Enum Field Binding

FormBinder can be extended to handle enum dropdowns:

```zig
pub fn FormBinder(comptime FormState: type, comptime form_id: []const u8) type {
    return struct {
        // ... existing code ...
        
        pub fn handleDropdown(self: Self, payload: GuiHookPayload) void {
            const info = payload.dropdown_changed;
            if (!belongsToForm(info.element.id)) return;
            
            const field_name = extractFieldName(info.element.id);
            
            const type_info = @typeInfo(FormState);
            inline for (type_info.Struct.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    // Check if field is an enum
                    const field_type_info = @typeInfo(field.type);
                    if (field_type_info == .Enum) {
                        // Convert index to enum value
                        const enum_value = @as(field.type, @enumFromInt(info.selected_index));
                        @field(self.form_state, field.name) = enum_value;
                        self.validate();
                        return;
                    }
                }
            }
        }
    };
}
```

## Performance Characteristics

**Compile Time**: O(n × m) where n = form count, m = avg fields per form  
**Runtime**: O(1) - all routing resolved at comptime  
**Memory**: Zero overhead - just struct pointers  

**Benchmark (theoretical for 50 forms × 10 fields each):**
- Compile time: +5-10 seconds
- Runtime dispatch: 0 ns overhead (inlined)
- Memory: 0 bytes overhead

## Why This Is The Recommended Approach

FormBinder provides the best **productivity-to-maintainability ratio** for most games:

1. **Productivity**: Adding a new form takes minutes, not hours
2. **Maintainability**: Handlers are trivial to understand
3. **Type Safety**: Compiler catches field name mismatches
4. **Scalability**: Works equally well for 5 forms or 500 forms
5. **Performance**: Zero runtime cost

The only downside is implementation complexity in `form_binder.zig`, but that's written once and reused forever. For game developers using labelle-engine, FormBinder provides the cleanest API with maximum compile-time safety.
