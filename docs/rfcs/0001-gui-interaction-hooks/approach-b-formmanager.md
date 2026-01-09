# Approach B: FormManager (Centralized Hash Map)

**Status**: Proposed  
**Best For**: Dynamic forms, runtime form generation, many similar forms  

## Overview

Store all form state in a centralized `FormManager` using hash maps keyed by element IDs. This approach provides runtime flexibility and reduces per-form boilerplate at the cost of some type safety.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  FormManager (Global Singleton)                 │
├─────────────────────────────────────────────────┤
│  fields: HashMap([]const u8, FieldValue)       │
│    - "monster_form.name_field" → .string        │
│    - "monster_form.health_slider" → .float      │
│    - "monster_form.attack_slider" → .float      │
│    - "monster_form.is_boss" → .bool             │
│    - "wizard_form.wizard_name" → .string        │
│    - "wizard_form.spell_slots" → .float         │
│    - "wizard_form.has_familiar" → .bool         │
├─────────────────────────────────────────────────┤
│  forms: HashMap([]const u8, FormMetadata)      │
│    - "monster_form" → { is_open, is_valid }    │
│    - "wizard_form" → { is_open, is_valid }     │
├─────────────────────────────────────────────────┤
│  validators: HashMap([]const u8, ValidatorFn)  │
│    - "monster_form" → validateMonsterForm       │
│    - "wizard_form" → validateWizardForm         │
└─────────────────────────────────────────────────┘
```

## Implementation

### 1. Define FormManager Type

```zig
// In form_manager.zig

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Tagged union for form field values
pub const FieldValue = union(enum) {
    string: []const u8,
    float: f32,
    int: i32,
    bool: bool,
    
    pub fn deinit(self: FieldValue, allocator: Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

/// Metadata about a form's state
pub const FormMetadata = struct {
    is_open: bool = false,
    is_valid: bool = false,
    is_dirty: bool = false,
};

/// Validation function signature
pub const ValidatorFn = *const fn (*FormManager, []const u8) bool;

/// Centralized form state manager
pub const FormManager = struct {
    allocator: Allocator,
    
    /// All field values keyed by "form_id.field_id"
    fields: std.StringHashMap(FieldValue),
    
    /// Form-level metadata keyed by "form_id"
    forms: std.StringHashMap(FormMetadata),
    
    /// Validators for each form
    validators: std.StringHashMap(ValidatorFn),
    
    pub fn init(allocator: Allocator) FormManager {
        return .{
            .allocator = allocator,
            .fields = std.StringHashMap(FieldValue).init(allocator),
            .forms = std.StringHashMap(FormMetadata).init(allocator),
            .validators = std.StringHashMap(ValidatorFn).init(allocator),
        };
    }
    
    pub fn deinit(self: *FormManager) void {
        // Clean up field values
        var field_iter = self.fields.iterator();
        while (field_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.fields.deinit();
        self.forms.deinit();
        self.validators.deinit();
    }
    
    /// Register a new form with optional validator
    pub fn registerForm(
        self: *FormManager,
        form_id: []const u8,
        validator: ?ValidatorFn,
    ) !void {
        const form_id_owned = try self.allocator.dupe(u8, form_id);
        try self.forms.put(form_id_owned, .{});
        
        if (validator) |v| {
            const validator_key = try self.allocator.dupe(u8, form_id);
            try self.validators.put(validator_key, v);
        }
    }
    
    /// Set a field value (string)
    pub fn setString(self: *FormManager, element_id: []const u8, value: []const u8) !void {
        const value_owned = try self.allocator.dupe(u8, value);
        const gop = try self.fields.getOrPut(element_id);
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.allocator);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, element_id);
        }
        gop.value_ptr.* = .{ .string = value_owned };
        self.markFormDirty(element_id);
    }

    /// Set a field value (float)
    pub fn setFloat(self: *FormManager, element_id: []const u8, value: f32) !void {
        const gop = try self.fields.getOrPut(element_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, element_id);
        }
        gop.value_ptr.* = .{ .float = value };
        self.markFormDirty(element_id);
    }

    /// Set a field value (bool)
    pub fn setBool(self: *FormManager, element_id: []const u8, value: bool) !void {
        const gop = try self.fields.getOrPut(element_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, element_id);
        }
        gop.value_ptr.* = .{ .bool = value };
        self.markFormDirty(element_id);
    }
    
    /// Get a string field value
    pub fn getString(self: *FormManager, element_id: []const u8) ?[]const u8 {
        const field = self.fields.get(element_id) orelse return null;
        return switch (field) {
            .string => |s| s,
            else => null,
        };
    }
    
    /// Get a float field value
    pub fn getFloat(self: *FormManager, element_id: []const u8) ?f32 {
        const field = self.fields.get(element_id) orelse return null;
        return switch (field) {
            .float => |f| f,
            else => null,
        };
    }
    
    /// Get a bool field value
    pub fn getBool(self: *FormManager, element_id: []const u8) ?bool {
        const field = self.fields.get(element_id) orelse return null;
        return switch (field) {
            .bool => |b| b,
            else => null,
        };
    }
    
    /// Get form metadata
    pub fn getFormMetadata(self: *FormManager, form_id: []const u8) ?FormMetadata {
        return self.forms.get(form_id);
    }
    
    /// Get mutable form metadata
    pub fn getFormMetadataMut(self: *FormManager, form_id: []const u8) ?*FormMetadata {
        return self.forms.getPtr(form_id);
    }
    
    /// Mark form as dirty (extract form_id from element_id)
    fn markFormDirty(self: *FormManager, element_id: []const u8) void {
        var parts = std.mem.split(u8, element_id, ".");
        const form_id = parts.next() orelse return;
        
        if (self.forms.getPtr(form_id)) |metadata| {
            metadata.is_dirty = true;
        }
    }
    
    /// Validate a form using its registered validator
    pub fn validateForm(self: *FormManager, form_id: []const u8) bool {
        const validator = self.validators.get(form_id) orelse return true;
        const is_valid = validator(self, form_id);
        
        if (self.forms.getPtr(form_id)) |metadata| {
            metadata.is_valid = is_valid;
        }
        
        return is_valid;
    }
    
    /// Reset a form (clear all fields and metadata)
    pub fn resetForm(self: *FormManager, form_id: []const u8) void {
        // Find and remove all fields for this form
        var field_iter = self.fields.iterator();
        var fields_to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer fields_to_remove.deinit();
        
        while (field_iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, form_id)) {
                fields_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }
        
        for (fields_to_remove.items) |key| {
            if (self.fields.fetchRemove(key)) |kv| {
                kv.value.deinit(self.allocator);
                self.allocator.free(kv.key);
            }
        }
        
        // Reset form metadata
        if (self.forms.getPtr(form_id)) |metadata| {
            metadata.* = .{};
        }
    }
    
    /// Open a form
    pub fn openForm(self: *FormManager, form_id: []const u8) void {
        if (self.forms.getPtr(form_id)) |metadata| {
            metadata.is_open = true;
        }
    }
    
    /// Close a form
    pub fn closeForm(self: *FormManager, form_id: []const u8) void {
        if (self.forms.getPtr(form_id)) |metadata| {
            metadata.is_open = false;
        }
    }
};
```

### 2. Define Validators

```zig
// In validators.zig

const std = @import("std");
const FormManager = @import("form_manager.zig").FormManager;

/// Validator for MonsterForm
pub fn validateMonsterForm(manager: *FormManager, form_id: []const u8) bool {
    _ = form_id; // form_id is "monster_form"
    
    // Validate name field
    const name = manager.getString("monster_form.name_field") orelse return false;
    if (name.len == 0 or name.len > 32) return false;
    
    // Validate health slider
    const health = manager.getFloat("monster_form.health_slider") orelse return false;
    if (health < 1.0 or health > 1000.0) return false;
    
    // Validate attack slider
    const attack = manager.getFloat("monster_form.attack_slider") orelse return false;
    if (attack < 1.0 or attack > 100.0) return false;
    
    return true;
}

/// Validator for WizardForm
pub fn validateWizardForm(manager: *FormManager, form_id: []const u8) bool {
    _ = form_id; // form_id is "wizard_form"
    
    // Validate wizard name
    const name = manager.getString("wizard_form.wizard_name") orelse return false;
    if (name.len == 0) return false;
    
    // Validate spell slots
    const slots = manager.getFloat("wizard_form.spell_slots") orelse return false;
    if (slots < 1.0 or slots > 10.0) return false;
    
    // If has familiar, familiar type must be set
    const has_familiar = manager.getBool("wizard_form.has_familiar") orelse false;
    if (has_familiar) {
        const familiar = manager.getString("wizard_form.familiar_type") orelse return false;
        if (familiar.len == 0) return false;
    }
    
    return true;
}
```

### 3. Initialize FormManager

```zig
// In main game initialization

const FormManager = @import("form_manager.zig").FormManager;
const validators = @import("validators.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create global form manager
    var form_manager = FormManager.init(allocator);
    defer form_manager.deinit();
    
    // Register forms with validators
    try form_manager.registerForm("monster_form", validators.validateMonsterForm);
    try form_manager.registerForm("wizard_form", validators.validateWizardForm);
    
    // Set default values for MonsterForm
    try form_manager.setString("monster_form.name_field", "");
    try form_manager.setFloat("monster_form.health_slider", 100.0);
    try form_manager.setFloat("monster_form.attack_slider", 10.0);
    try form_manager.setBool("monster_form.is_boss", false);
    
    // Set default values for WizardForm
    try form_manager.setString("wizard_form.wizard_name", "");
    try form_manager.setFloat("wizard_form.spell_slots", 5.0);
    try form_manager.setBool("wizard_form.has_familiar", false);
    try form_manager.setString("wizard_form.familiar_type", "");
    
    // Store reference for handlers (can be a global or game state field)
    gui_handlers.setFormManager(&form_manager);
    
    // ... rest of game initialization
}
```

### 4. GUI Hook Handlers

```zig
// In gui_handlers.zig

const std = @import("std");
const labelle = @import("labelle-engine");
const GuiHookPayload = labelle.GuiHookPayload;
const FormManager = @import("form_manager.zig").FormManager;

// Global form manager reference
var form_manager: ?*FormManager = null;

pub fn setFormManager(manager: *FormManager) void {
    form_manager = manager;
}

pub const MyGuiHandlers = struct {
    pub fn text_input_changed(payload: GuiHookPayload) void {
        const info = payload.text_input_changed;
        const manager = form_manager orelse return;
        
        // Store the new text value
        manager.setString(info.element.id, info.text) catch |err| {
            std.log.err("Failed to set string field: {}", .{err});
            return;
        };
        
        // Validate the parent form
        var parts = std.mem.split(u8, info.element.id, ".");
        const form_id = parts.next() orelse return;
        _ = manager.validateForm(form_id);
    }
    
    pub fn slider_changed(payload: GuiHookPayload) void {
        const info = payload.slider_changed;
        const manager = form_manager orelse return;
        
        // Store the new slider value
        manager.setFloat(info.element.id, info.value) catch |err| {
            std.log.err("Failed to set float field: {}", .{err});
            return;
        };
        
        // Validate the parent form
        var parts = std.mem.split(u8, info.element.id, ".");
        const form_id = parts.next() orelse return;
        _ = manager.validateForm(form_id);
    }
    
    pub fn checkbox_toggled(payload: GuiHookPayload) void {
        const info = payload.checkbox_toggled;
        const manager = form_manager orelse return;
        
        // Store the new checkbox state
        manager.setBool(info.element.id, info.checked) catch |err| {
            std.log.err("Failed to set bool field: {}", .{err});
            return;
        };
        
        // Special handling for conditional fields
        if (std.mem.eql(u8, info.element.id, "wizard_form.has_familiar")) {
            if (!info.checked) {
                // Clear familiar type when unchecking
                manager.setString("wizard_form.familiar_type", "") catch {};
            }
        }
        
        // Validate the parent form
        var parts = std.mem.split(u8, info.element.id, ".");
        const form_id = parts.next() orelse return;
        _ = manager.validateForm(form_id);
    }
    
    pub fn button_clicked(payload: GuiHookPayload) void {
        const info = payload.button_clicked;
        const manager = form_manager orelse return;
        
        // Handle form submission buttons
        if (std.mem.eql(u8, info.element.id, "monster_form.submit")) {
            handleMonsterFormSubmit(manager);
        } else if (std.mem.eql(u8, info.element.id, "monster_form.cancel")) {
            handleMonsterFormCancel(manager);
        } else if (std.mem.eql(u8, info.element.id, "wizard_form.save")) {
            handleWizardFormSave(manager);
        }
    }
};

fn handleMonsterFormSubmit(manager: *FormManager) void {
    // Validate form
    if (!manager.validateForm("monster_form")) {
        std.log.warn("Monster form is invalid!", .{});
        return;
    }
    
    // Extract values
    const name = manager.getString("monster_form.name_field") orelse "";
    const health = manager.getFloat("monster_form.health_slider") orelse 100.0;
    const attack = manager.getFloat("monster_form.attack_slider") orelse 10.0;
    const is_boss = manager.getBool("monster_form.is_boss") orelse false;
    
    // Create monster
    std.log.info("Creating monster: name={s}, health={d}, attack={d}, is_boss={}", .{
        name,
        health,
        attack,
        is_boss,
    });
    
    // Close and reset form
    manager.closeForm("monster_form");
    manager.resetForm("monster_form");
    
    // Re-initialize default values
    manager.setString("monster_form.name_field", "") catch {};
    manager.setFloat("monster_form.health_slider", 100.0) catch {};
    manager.setFloat("monster_form.attack_slider", 10.0) catch {};
    manager.setBool("monster_form.is_boss", false) catch {};
}

fn handleMonsterFormCancel(manager: *FormManager) void {
    manager.closeForm("monster_form");
    manager.resetForm("monster_form");
    
    // Re-initialize default values
    manager.setString("monster_form.name_field", "") catch {};
    manager.setFloat("monster_form.health_slider", 100.0) catch {};
    manager.setFloat("monster_form.attack_slider", 10.0) catch {};
    manager.setBool("monster_form.is_boss", false) catch {};
}

fn handleWizardFormSave(manager: *FormManager) void {
    // Validate form
    if (!manager.validateForm("wizard_form")) {
        std.log.warn("Wizard form is invalid!", .{});
        return;
    }
    
    // Extract values
    const name = manager.getString("wizard_form.wizard_name") orelse "";
    const spell_slots = manager.getFloat("wizard_form.spell_slots") orelse 5.0;
    const has_familiar = manager.getBool("wizard_form.has_familiar") orelse false;
    const familiar_type = manager.getString("wizard_form.familiar_type") orelse "";
    
    // Save wizard configuration
    std.log.info("Saving wizard: name={s}, slots={d}, has_familiar={}, familiar={s}", .{
        name,
        spell_slots,
        has_familiar,
        familiar_type,
    });
    
    // Close form (but don't reset - wizard config persists)
    manager.closeForm("wizard_form");
}
```

## Pros

✅ **Low Boilerplate**: Generic handlers work for all forms  
✅ **Runtime Flexibility**: Add/remove fields dynamically  
✅ **Centralized State**: All form data in one place  
✅ **Easy Debugging**: Can dump entire FormManager state  
✅ **Scalability**: Adding new forms doesn't require new handler code  
✅ **Generic Validation**: Validators registered at runtime  

## Cons

❌ **Reduced Type Safety**: Field types only known at runtime  
❌ **HashMap Overhead**: Performance cost for lookups (minimal but present)  
❌ **Manual Field IDs**: Must maintain consistent naming convention  
❌ **Memory Management**: More allocations for string keys/values  
❌ **No ECS Integration**: Form state not visible to ECS systems  
❌ **Error Prone**: Typos in field IDs only caught at runtime  

## Best Use Cases

1. **Dynamic Forms**: Forms generated from configuration files
2. **Large Form Count**: Games with 20+ similar forms
3. **Runtime Form Generation**: Creating forms from server data
4. **Form Templates**: Reusable form patterns with different field sets
5. **Prototyping**: Quick iteration without recompilation for new forms

## Example: Complete MonsterForm Flow

```zig
// 1. User opens form
form_manager.openForm("monster_form");

// 2. User types name → text_input_changed hook fired
// Handler calls: form_manager.setString("monster_form.name_field", "Dragon")
// Auto-validates: form_manager.validateForm("monster_form")

// 3. User adjusts health slider → slider_changed hook fired
// Handler calls: form_manager.setFloat("monster_form.health_slider", 500.0)
// Auto-validates: form_manager.validateForm("monster_form")

// 4. User clicks submit → button_clicked hook fired
// Handler validates, extracts values from FormManager, creates monster
// Handler calls: form_manager.closeForm("monster_form")
// Handler calls: form_manager.resetForm("monster_form")

// 5. FormManager state can be inspected at any time
const name = form_manager.getString("monster_form.name_field");
const metadata = form_manager.getFormMetadata("monster_form");
```

## Comparison with Other Approaches

| Feature | ECS Components | FormManager | Form Context | FormBinder |
|---------|---------------|-------------|--------------|------------|
| Type Safety | ✅ High | ⚠️ Medium | ✅ High | ✅ High |
| Boilerplate | ❌ High | ✅ Low | ⚠️ Medium | ✅ Low |
| ECS Integration | ✅ Native | ❌ None | ⚠️ Manual | ⚠️ Manual |
| Auto-Binding | ❌ No | ❌ No | ⚠️ Partial | ✅ Yes |
| Scalability | ⚠️ Manual per form | ✅ Automatic | ✅ Automatic | ✅ Automatic |
| Runtime Flexibility | ❌ Compile-time only | ✅ Full | ⚠️ Limited | ❌ Compile-time only |
| Debug Visibility | ✅ ECS inspector | ✅ Can dump state | ⚠️ Depends | ⚠️ Depends |

## Migration Path

If starting with this approach and later wanting to switch:

**To ECS Components**: Convert FormManager state to component structs  
**To FormBinder**: Keep FormManager internally, add reflection layer on top  
**To Form Context**: Wrap FormManager in context structs, pass in payloads  

## Recommendation

**Use FormManager when:**
- You have many similar forms (> 20)
- Forms need to be generated dynamically
- You're prototyping and need fast iteration
- You need runtime form configuration
- Type safety is less critical than flexibility

**Consider alternatives when:**
- You have few forms (< 10) with unique structures
- Forms create/edit game entities (ECS Components better)
- You want maximum type safety (FormBinder better)
- Performance is critical (ECS Components or FormBinder better)

## Advanced: Form Templates

FormManager enables powerful form template patterns:

```zig
/// Template for creating similar forms
pub const FormTemplate = struct {
    form_id: []const u8,
    fields: []const FieldTemplate,
    validator: ?ValidatorFn,
};

pub const FieldTemplate = struct {
    field_id: []const u8,
    default_value: FieldValue,
};

/// Instantiate a form from a template
pub fn instantiateFormTemplate(
    manager: *FormManager,
    template: FormTemplate,
) !void {
    // Register the form
    try manager.registerForm(template.form_id, template.validator);
    
    // Initialize all fields with defaults
    for (template.fields) |field| {
        const element_id = try std.fmt.allocPrint(
            manager.allocator,
            "{s}.{s}",
            .{ template.form_id, field.field_id },
        );
        defer manager.allocator.free(element_id);
        
        switch (field.default_value) {
            .string => |s| try manager.setString(element_id, s),
            .float => |f| try manager.setFloat(element_id, f),
            .bool => |b| try manager.setBool(element_id, b),
            .int => |i| try manager.setInt(element_id, i),
        }
    }
}

// Example usage:
const monster_template = FormTemplate{
    .form_id = "monster_form",
    .validator = validators.validateMonsterForm,
    .fields = &.{
        .{ .field_id = "name_field", .default_value = .{ .string = "" } },
        .{ .field_id = "health_slider", .default_value = .{ .float = 100.0 } },
        .{ .field_id = "attack_slider", .default_value = .{ .float = 10.0 } },
        .{ .field_id = "is_boss", .default_value = .{ .bool = false } },
    },
};

try instantiateFormTemplate(&form_manager, monster_template);
```

This template system allows you to define forms declaratively and instantiate multiple variations with different field sets.
