# Approach C: Form Context in Payloads

**Status**: Proposed  
**Best For**: Mixed form patterns, forms with moderate complexity  

## Overview

Automatically populate form context in GUI event payloads, allowing backends to pass direct pointers to form state structs. This approach provides clean handler code with type-safe state access while pushing complexity into the backend layer.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  FormRegistry (Global Singleton)                │
├─────────────────────────────────────────────────┤
│  forms: HashMap([]const u8, FormRegistration)  │
│    - "monster_form" → {                         │
│         form_state_ptr: *MonsterFormState,      │
│         field_map: HashMap("name_field" → 0)    │
│      }                                           │
│    - "wizard_form" → {                          │
│         form_state_ptr: *WizardFormState,       │
│         field_map: HashMap("wizard_name" → 0)   │
│      }                                           │
└─────────────────────────────────────────────────┘
                      │
                      │ Backend queries registry
                      ↓
┌─────────────────────────────────────────────────┐
│  GuiHookPayload.ElementInfo                     │
├─────────────────────────────────────────────────┤
│  id: "monster_form.name_field"                  │
│  element_type: .text_field                      │
│  form_context: FormContext {                    │
│      form_id: "monster_form",                   │
│      field_name: "name_field",                  │
│      form_state_ptr: *anyopaque,  ← Points to   │
│  }                                  MonsterState │
└─────────────────────────────────────────────────┘
                      │
                      │ Handler receives context
                      ↓
┌─────────────────────────────────────────────────┐
│  Hook Handler (Clean, Type-Safe)                │
├─────────────────────────────────────────────────┤
│  pub fn text_input_changed(payload: ...) {      │
│      const ctx = payload.element.form_context;  │
│      var state = ctx.getState(MonsterFormState);│
│      state.setName(payload.text);               │
│  }                                               │
└─────────────────────────────────────────────────┘
```

## Implementation

### 1. Define FormContext Types

```zig
// In gui/hooks.zig (extend existing types)

const std = @import("std");

/// Context about the form that contains an element
pub const FormContext = struct {
    /// ID of the parent form (e.g., "monster_form")
    form_id: []const u8,
    
    /// Name of the field within the form (e.g., "name_field")
    field_name: []const u8,
    
    /// Opaque pointer to the form state struct
    form_state_ptr: *anyopaque,
    
    /// Get typed pointer to form state
    pub fn getState(self: FormContext, comptime T: type) *T {
        return @ptrCast(@alignCast(self.form_state_ptr));
    }
    
    /// Get const typed pointer to form state
    pub fn getStateConst(self: FormContext, comptime T: type) *const T {
        return @ptrCast(@alignCast(self.form_state_ptr));
    }
};

/// Information about a GUI element that triggered an event
pub const ElementInfo = struct {
    /// Element ID from .zon definition
    id: []const u8,
    
    /// Element type (button, checkbox, etc.)
    element_type: GuiElementType,
    
    /// Optional form context (populated if element belongs to a registered form)
    form_context: ?FormContext = null,
    
    // ... other fields
};
```

### 2. Create FormRegistry

```zig
// In gui/form_registry.zig (new file)

const std = @import("std");
const Allocator = std.mem.Allocator;
const FormContext = @import("hooks.zig").FormContext;

/// Registration info for a form
pub const FormRegistration = struct {
    /// Pointer to form state struct (type-erased)
    form_state_ptr: *anyopaque,
    
    /// Map from field name to field index (for fast lookup)
    field_map: std.StringHashMap(usize),
    
    /// Type name for debugging
    type_name: []const u8,
    
    pub fn deinit(self: *FormRegistration) void {
        self.field_map.deinit();
    }
};

/// Global registry of forms
pub const FormRegistry = struct {
    allocator: Allocator,
    forms: std.StringHashMap(FormRegistration),
    
    pub fn init(allocator: Allocator) FormRegistry {
        return .{
            .allocator = allocator,
            .forms = std.StringHashMap(FormRegistration).init(allocator),
        };
    }
    
    pub fn deinit(self: *FormRegistry) void {
        var iter = self.forms.valueIterator();
        while (iter.next()) |registration| {
            registration.deinit();
        }
        self.forms.deinit();
    }
    
    /// Register a form with its state struct
    pub fn registerForm(
        self: *FormRegistry,
        form_id: []const u8,
        form_state_ptr: anytype,
        comptime T: type,
    ) !void {
        const type_info = @typeInfo(T);
        if (type_info != .Struct) {
            @compileError("Form state must be a struct type");
        }
        
        // Build field map
        var field_map = std.StringHashMap(usize).init(self.allocator);
        errdefer field_map.deinit();
        
        inline for (type_info.Struct.fields, 0..) |field, i| {
            // Skip metadata fields (is_open, is_valid, etc.)
            if (std.mem.startsWith(u8, field.name, "is_")) continue;
            
            const field_name = try self.allocator.dupe(u8, field.name);
            try field_map.put(field_name, i);
        }
        
        // Create registration
        const registration = FormRegistration{
            .form_state_ptr = form_state_ptr,
            .field_map = field_map,
            .type_name = @typeName(T),
        };
        
        const form_id_owned = try self.allocator.dupe(u8, form_id);
        try self.forms.put(form_id_owned, registration);
    }
    
    /// Unregister a form
    pub fn unregisterForm(self: *FormRegistry, form_id: []const u8) void {
        if (self.forms.fetchRemove(form_id)) |kv| {
            var registration = kv.value;
            registration.deinit();
            self.allocator.free(kv.key);
        }
    }
    
    /// Build FormContext for an element ID
    /// Returns null if element doesn't belong to a registered form
    pub fn buildFormContext(
        self: *FormRegistry,
        element_id: []const u8,
    ) ?FormContext {
        // Parse element_id: "form_id.field_name"
        var parts = std.mem.split(u8, element_id, ".");
        const form_id = parts.next() orelse return null;
        const field_name = parts.next() orelse return null;
        
        // Look up form registration
        const registration = self.forms.get(form_id) orelse return null;
        
        return FormContext{
            .form_id = form_id,
            .field_name = field_name,
            .form_state_ptr = registration.form_state_ptr,
        };
    }
};

// Global instance (or can be stored in Game struct)
var global_form_registry: ?*FormRegistry = null;

pub fn setGlobalFormRegistry(registry: *FormRegistry) void {
    global_form_registry = registry;
}

pub fn getGlobalFormRegistry() ?*FormRegistry {
    return global_form_registry;
}
```

### 3. Update Backend to Populate FormContext

```zig
// In gui/clay/adapter.zig (or any backend)

const FormRegistry = @import("../form_registry.zig");

pub fn button(element: GuiElement) bool {
    // ... existing Clay button rendering code
    
    const clicked = c.Clay_PointerOver(layout_id) and c.Clay_PointerJustPressed();
    
    if (clicked) {
        // Build ElementInfo with form context
        var element_info = GuiHookPayload.ElementInfo{
            .id = element.id,
            .element_type = .button,
            .form_context = null,
        };
        
        // Populate form context if available
        if (FormRegistry.getGlobalFormRegistry()) |registry| {
            element_info.form_context = registry.buildFormContext(element.id);
        }
        
        // Queue GUI event
        const payload = GuiHookPayload{
            .button_clicked = .{
                .element = element_info,
                .position = .{ .x = mouse_x, .y = mouse_y },
                .button = .left,
            },
        };
        
        game.queueGuiEvent(payload);
    }
    
    return clicked;
}

pub fn textField(element: GuiElement, buffer: []u8) []const u8 {
    // ... Clay text field rendering
    
    if (text_changed) {
        var element_info = GuiHookPayload.ElementInfo{
            .id = element.id,
            .element_type = .text_field,
            .form_context = null,
        };
        
        // Populate form context
        if (FormRegistry.getGlobalFormRegistry()) |registry| {
            element_info.form_context = registry.buildFormContext(element.id);
        }
        
        const payload = GuiHookPayload{
            .text_input_changed = .{
                .element = element_info,
                .text = new_text,
            },
        };
        
        game.queueGuiEvent(payload);
    }
    
    return current_text;
}

// Similar updates for slider(), checkbox(), etc.
```

### 4. Define Form State Structs

```zig
// In components.zig or forms.zig

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
        
        pub fn toString(self: MonsterElement) []const u8 {
            return switch (self) {
                .fire => "Fire",
                .water => "Water",
                .earth => "Earth",
                .air => "Air",
            };
        }
    };
    
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
    
    pub fn reset(self: *MonsterFormState) void {
        self.* = MonsterFormState{};
    }
};

pub const WizardFormState = struct {
    wizard_name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    spell_slots: f32 = 5,
    school: MagicSchool = .evocation,
    has_familiar: bool = false,
    familiar_type: [64:0]u8 = std.mem.zeroes([64:0]u8),
    
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

### 5. Initialize and Register Forms

```zig
// In main game initialization

const FormRegistry = @import("gui/form_registry.zig").FormRegistry;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create form registry
    var form_registry = FormRegistry.init(allocator);
    defer form_registry.deinit();
    
    // Set global registry (so backends can access it)
    FormRegistry.setGlobalFormRegistry(&form_registry);
    
    // Create form state instances
    var monster_form_state = MonsterFormState{};
    var wizard_form_state = WizardFormState{};
    
    // Register forms with registry
    try form_registry.registerForm(
        "monster_form",
        &monster_form_state,
        MonsterFormState,
    );
    
    try form_registry.registerForm(
        "wizard_form",
        &wizard_form_state,
        WizardFormState,
    );
    
    // ... rest of game initialization
}
```

### 6. Clean Hook Handlers

```zig
// In gui_handlers.zig

const std = @import("std");
const labelle = @import("labelle-engine");
const GuiHookPayload = labelle.GuiHookPayload;
const MonsterFormState = @import("forms.zig").MonsterFormState;
const WizardFormState = @import("forms.zig").WizardFormState;

pub const MyGuiHandlers = struct {
    pub fn text_input_changed(payload: GuiHookPayload) void {
        const info = payload.text_input_changed;
        const ctx = info.element.form_context orelse return;
        
        // Determine form type and route
        if (std.mem.eql(u8, ctx.form_id, "monster_form")) {
            var state = ctx.getState(MonsterFormState);
            
            if (std.mem.eql(u8, ctx.field_name, "name_field")) {
                state.setName(info.text);
                _ = state.validate();
            }
        } else if (std.mem.eql(u8, ctx.form_id, "wizard_form")) {
            var state = ctx.getState(WizardFormState);
            
            if (std.mem.eql(u8, ctx.field_name, "wizard_name")) {
                state.setWizardName(info.text);
                _ = state.validate();
            } else if (std.mem.eql(u8, ctx.field_name, "familiar_type")) {
                state.setFamiliarType(info.text);
                _ = state.validate();
            }
        }
    }
    
    pub fn slider_changed(payload: GuiHookPayload) void {
        const info = payload.slider_changed;
        const ctx = info.element.form_context orelse return;
        
        if (std.mem.eql(u8, ctx.form_id, "monster_form")) {
            var state = ctx.getState(MonsterFormState);
            
            if (std.mem.eql(u8, ctx.field_name, "health_slider")) {
                state.health = info.value;
                _ = state.validate();
            } else if (std.mem.eql(u8, ctx.field_name, "attack_slider")) {
                state.attack = info.value;
                _ = state.validate();
            }
        } else if (std.mem.eql(u8, ctx.form_id, "wizard_form")) {
            var state = ctx.getState(WizardFormState);
            
            if (std.mem.eql(u8, ctx.field_name, "spell_slots")) {
                state.spell_slots = info.value;
                _ = state.validate();
            }
        }
    }
    
    pub fn checkbox_toggled(payload: GuiHookPayload) void {
        const info = payload.checkbox_toggled;
        const ctx = info.element.form_context orelse return;
        
        if (std.mem.eql(u8, ctx.form_id, "monster_form")) {
            var state = ctx.getState(MonsterFormState);
            
            if (std.mem.eql(u8, ctx.field_name, "is_boss")) {
                state.is_boss = info.checked;
                _ = state.validate();
            }
        } else if (std.mem.eql(u8, ctx.form_id, "wizard_form")) {
            var state = ctx.getState(WizardFormState);
            
            if (std.mem.eql(u8, ctx.field_name, "has_familiar")) {
                state.has_familiar = info.checked;
                
                // Clear familiar type when unchecking
                if (!info.checked) {
                    state.familiar_type = std.mem.zeroes([64:0]u8);
                }
                
                _ = state.validate();
            }
        }
    }
    
    pub fn button_clicked(payload: GuiHookPayload) void {
        const info = payload.button_clicked;
        const ctx = info.element.form_context orelse {
            // Handle non-form buttons here
            return;
        };
        
        if (std.mem.eql(u8, ctx.form_id, "monster_form")) {
            var state = ctx.getState(MonsterFormState);
            
            if (std.mem.eql(u8, ctx.field_name, "submit")) {
                handleMonsterFormSubmit(state);
            } else if (std.mem.eql(u8, ctx.field_name, "cancel")) {
                handleMonsterFormCancel(state);
            }
        } else if (std.mem.eql(u8, ctx.form_id, "wizard_form")) {
            var state = ctx.getState(WizardFormState);
            
            if (std.mem.eql(u8, ctx.field_name, "save")) {
                handleWizardFormSave(state);
            }
        }
    }
};

fn handleMonsterFormSubmit(state: *MonsterFormState) void {
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

fn handleMonsterFormCancel(state: *MonsterFormState) void {
    state.is_open = false;
    state.reset();
}

fn handleWizardFormSave(state: *WizardFormState) void {
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

## Pros

✅ **Clean Handlers**: Direct access to typed form state  
✅ **Type Safety**: Form state structs provide compile-time guarantees  
✅ **Automatic Context**: Backends populate form context automatically  
✅ **Less String Parsing**: Handlers get pre-parsed form_id and field_name  
✅ **Zero Runtime Overhead**: Pointer casting is zero-cost  
✅ **Mixed Patterns**: Can combine with ECS or standalone forms  

## Cons

❌ **Backend Complexity**: Backends must query FormRegistry  
❌ **Global State**: Requires global or game-owned FormRegistry  
❌ **Registration Boilerplate**: Must register each form explicitly  
❌ **Still Some String Comparison**: Handlers still need form_id/field_name checks  
❌ **Lifetime Management**: Form state must outlive all GUI events  

## Best Use Cases

1. **Mixed Form Types**: Some ECS-backed, some standalone
2. **Moderate Form Count**: 5-20 forms with varied structures
3. **Backend Abstraction**: Want clean separation between forms and backends
4. **Type-Safe Forms**: Need compile-time guarantees but not full auto-binding
5. **Rapid Prototyping**: Quick iteration without complex binding logic

## Example: Complete MonsterForm Flow

```zig
// 1. Initialization: Register form with registry
var monster_state = MonsterFormState{};
try form_registry.registerForm("monster_form", &monster_state, MonsterFormState);

// 2. User types name → Backend queries registry
const ctx = form_registry.buildFormContext("monster_form.name_field");
// ctx = { form_id: "monster_form", field_name: "name_field", form_state_ptr: &monster_state }

// 3. Backend queues event with populated FormContext
const payload = GuiHookPayload{
    .text_input_changed = .{
        .element = .{
            .id = "monster_form.name_field",
            .element_type = .text_field,
            .form_context = ctx,  // ← Auto-populated!
        },
        .text = "Dragon",
    },
};

// 4. Handler receives payload with context
pub fn text_input_changed(payload: GuiHookPayload) void {
    const ctx = payload.element.form_context.?;
    var state = ctx.getState(MonsterFormState);  // Direct typed access!
    state.setName(payload.text);
    _ = state.validate();
}

// 5. Submit button clicked
pub fn button_clicked(payload: GuiHookPayload) void {
    const ctx = payload.element.form_context.?;
    var state = ctx.getState(MonsterFormState);
    
    if (state.is_valid) {
        // Create monster from state
        createMonster(state);
        state.reset();
    }
}
```

## Comparison with Other Approaches

| Feature | ECS Components | FormManager | Form Context | FormBinder |
|---------|---------------|-------------|--------------|------------|
| Type Safety | ✅ High | ⚠️ Medium | ✅ High | ✅ High |
| Boilerplate | ❌ High | ✅ Low | ⚠️ Medium | ✅ Low |
| ECS Integration | ✅ Native | ❌ None | ⚠️ Manual | ⚠️ Manual |
| Auto-Binding | ❌ No | ❌ No | ⚠️ Partial | ✅ Yes |
| Scalability | ⚠️ Manual per form | ✅ Automatic | ✅ Good | ✅ Automatic |
| Handler Cleanliness | ❌ Verbose | ⚠️ Good | ✅ Clean | ✅ Very Clean |
| Backend Complexity | ✅ Low | ✅ Low | ⚠️ Medium | ⚠️ Medium |

## Migration Path

If starting with this approach and later wanting to switch:

**To ECS Components**: Move form state to components, keep FormContext pointing to components  
**To FormManager**: Replace FormRegistry with FormManager, adapt handlers  
**To FormBinder**: Add comptime reflection layer on top of FormContext  

## Recommendation

**Use Form Context when:**
- You have 5-20 forms with different structures
- You want cleaner handlers than ECS approach
- You're mixing ECS-backed and standalone forms
- Backend abstraction is important
- You're willing to maintain a FormRegistry

**Consider alternatives when:**
- You have very few forms (< 5) - use ECS Components directly
- You have many similar forms (> 20) - use FormBinder
- You want zero handler boilerplate - use FormBinder
- Backend simplicity is critical - use ECS Components or FormManager

## Advanced: Combining with ECS

You can use FormContext with ECS components by registering component pointers:

```zig
// Form state is an ECS component
const monster_entity = game.createEntity();
game.addComponent(monster_entity, MonsterFormState{});

// Register the component with FormRegistry
const state_ptr = game.getComponentMut(monster_entity, MonsterFormState).?;
try form_registry.registerForm("monster_form", state_ptr, MonsterFormState);

// Now FormContext works seamlessly with ECS!
// Handlers get direct access to component data
// ECS systems can also query the same component
```

This hybrid approach combines the benefits of ECS integration with the clean handler code of Form Context.
