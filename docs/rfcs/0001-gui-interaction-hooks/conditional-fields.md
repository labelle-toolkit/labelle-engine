# Conditional Fields: Dynamic Form Visibility

**Use Case**: Show/hide form fields based on other field values (e.g., show "Boss Health" slider only when "Is Boss" checkbox is checked).

## Problem Statement

Forms often need dynamic behavior:
- Show "Advanced Settings" when checkbox enabled
- Show "Spell Selection" only for mage class
- Show "Mount Options" only when player level ≥ 20
- Show "Custom Amount" text field when "Amount" dropdown is "Other"

## Solution Approaches

### Approach A: Reactive View Updates (Recommended)

**Concept**: Form state changes trigger view regeneration with conditional logic.

#### Implementation

```zig
// Monster form with conditional fields
pub const MonsterFormState = struct {
    name: [32:0]u8 = std.mem.zeroes([32:0]u8),
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,
    
    // Boss-only fields (only shown when is_boss = true)
    boss_title: [32:0]u8 = std.mem.zeroes([32:0]u8),
    boss_phase_count: u32 = 1,
    
    // Generate GUI view based on current state
    pub fn generateView(self: MonsterFormState, allocator: Allocator) ![]gui.GuiElement {
        var elements = std.ArrayList(gui.GuiElement).init(allocator);
        
        // Always show base fields
        try elements.append(.{ .Label = .{
            .text = "Monster Name:",
            .position = .{ .x = 20, .y = 20 },
        }});
        
        try elements.append(.{ .Slider = .{
            .id = "monster_form.health",
            .position = .{ .x = 20, .y = 60 },
            .value = self.health,
            .min = 0,
            .max = 1000,
        }});
        
        try elements.append(.{ .Checkbox = .{
            .id = "monster_form.is_boss",
            .text = "Is Boss",
            .position = .{ .x = 20, .y = 100 },
            .checked = self.is_boss,
        }});
        
        // Conditionally show boss fields
        if (self.is_boss) {
            try elements.append(.{ .Label = .{
                .text = "Boss Title:",
                .position = .{ .x = 40, .y = 140 },  // Indented
                .color = .{ .r = 255, .g = 215, .b = 0 },  // Gold color
            }});
            
            try elements.append(.{ .Slider = .{
                .id = "monster_form.boss_phase_count",
                .position = .{ .x = 40, .y = 180 },
                .value = @floatFromInt(self.boss_phase_count),
                .min = 1,
                .max = 5,
            }});
        }
        
        return elements.toOwnedSlice();
    }
};
```

#### Usage in Game Loop

```zig
const GuiHooks = struct {
    pub fn checkbox_changed(payload: gui.GuiHookPayload) void {
        const binder = MonsterBinder.init(&monster_form);
        if (binder.handleEvent(payload)) {
            // Form state changed - regenerate view
            if (std.mem.eql(u8, payload.checkbox_changed.element.id, "monster_form.is_boss")) {
                game.updateDynamicView("monster_form", monster_form.generateView(allocator));
            }
        }
    }
};
```

**Pros**:
- ✅ Explicit control over visibility
- ✅ Can update any element property (not just visibility)
- ✅ Easy to reason about (pure function)
- ✅ Works with .zon files (generate at runtime)

**Cons**:
- ⚠️ Requires view regeneration on state change
- ⚠️ Allocation overhead (mitigated with ArenaAllocator)

---

### Approach B: Visibility Flags (Simpler)

**Concept**: Add `visible` field to GUI elements, toggle based on form state.

#### Extended GUI Types

```zig
// gui/types.zig
pub const Slider = struct {
    id: []const u8 = "",
    position: Position = .{},
    size: Size = .{},
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = 0,
    visible: bool = true,  // ← New field
};

pub const Label = struct {
    // ... existing fields ...
    visible: bool = true,  // ← New field
};

// ... add to all element types
```

#### Usage

```zig
// Define static view with all possible elements
const monster_form_view = &[_]gui.GuiElement{
    .{ .Label = .{ .text = "Monster Name:", .position = .{ .x = 20, .y = 20 } }},
    .{ .Checkbox = .{ .id = "monster_form.is_boss", .text = "Is Boss", .position = .{ .x = 20, .y = 60 } }},
    
    // Boss-only fields (hidden by default)
    .{ .Label = .{ 
        .id = "boss_title_label",
        .text = "Boss Title:", 
        .position = .{ .x = 40, .y = 100 },
        .visible = false,  // ← Hidden initially
    }},
    .{ .Slider = .{ 
        .id = "monster_form.boss_phase_count",
        .position = .{ .x = 40, .y = 140 },
        .visible = false,  // ← Hidden initially
    }},
};

// Update visibility when checkbox changes
const GuiHooks = struct {
    pub fn checkbox_changed(payload: gui.GuiHookPayload) void {
        const binder = MonsterBinder.init(&monster_form);
        if (binder.handleEvent(payload)) {
            if (std.mem.eql(u8, payload.checkbox_changed.element.id, "monster_form.is_boss")) {
                // Update visibility of boss fields
                game.setElementVisible("boss_title_label", monster_form.is_boss);
                game.setElementVisible("monster_form.boss_phase_count", monster_form.is_boss);
            }
        }
    }
};
```

**Game Method**:
```zig
// engine/game.zig
pub fn setElementVisible(self: *Self, element_id: []const u8, visible: bool) void {
    if (self.gui_state.element_map.getPtr(element_id)) |element| {
        switch (element.*) {
            .Label => |*label| label.visible = visible,
            .Slider => |*slider| slider.visible = visible,
            .Checkbox => |*checkbox| checkbox.visible = visible,
            // ... etc
        }
    }
}
```

**Pros**:
- ✅ Simple API (`setElementVisible()`)
- ✅ No view regeneration needed
- ✅ Works with static .zon files
- ✅ Low overhead (just boolean flip)

**Cons**:
- ⚠️ All elements exist in memory even when hidden
- ⚠️ Manual visibility management (must remember all dependent fields)

---

### Approach C: Declarative Visibility Rules (Most Elegant)

**Concept**: Define visibility rules in form state, automatically evaluated.

#### Implementation

```zig
pub const MonsterFormState = struct {
    name: [32:0]u8 = std.mem.zeroes([32:0]u8),
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,
    boss_title: [32:0]u8 = std.mem.zeroes([32:0]u8),
    boss_phase_count: u32 = 1,
    
    // Visibility rules (comptime generated)
    pub const VisibilityRules = .{
        .boss_title_label = "is_boss",           // Show when is_boss = true
        .boss_title_field = "is_boss",
        .boss_phase_count = "is_boss",
        .advanced_settings_panel = "show_advanced",
    };
    
    // Evaluate visibility for an element
    pub fn isVisible(self: MonsterFormState, element_id: []const u8) bool {
        // Check if element has visibility rule
        inline for (std.meta.fields(@TypeOf(VisibilityRules))) |field| {
            if (std.mem.eql(u8, field.name, element_id)) {
                const rule_field = @field(VisibilityRules, field.name);
                // Get the boolean field value
                return @field(self, rule_field);
            }
        }
        // No rule = always visible
        return true;
    }
};
```

#### FormBinder Extension

```zig
// gui/form_binder.zig
pub fn FormBinder(comptime FormStateType: type, comptime form_id: []const u8) type {
    return struct {
        // ... existing fields ...
        
        /// Update element visibility based on form state
        pub fn updateVisibility(self: Self, game: *Game) void {
            // Check if form has visibility rules
            if (!@hasDecl(FormStateType, "VisibilityRules")) return;
            
            // Apply visibility rules
            inline for (std.meta.fields(@TypeOf(FormStateType.VisibilityRules))) |field| {
                const element_id = field.name;
                const is_visible = self.form_state.isVisible(element_id);
                game.setElementVisible(element_id, is_visible);
            }
        }
    };
}
```

#### Usage

```zig
const GuiHooks = struct {
    pub fn checkbox_changed(payload: gui.GuiHookPayload) void {
        const binder = MonsterBinder.init(&monster_form);
        if (binder.handleEvent(payload)) {
            // Automatically update visibility based on rules
            binder.updateVisibility(&game);
        }
    }
    
    pub fn slider_changed(payload: gui.GuiHookPayload) void {
        const binder = MonsterBinder.init(&monster_form);
        if (binder.handleEvent(payload)) {
            binder.updateVisibility(&game);  // ← One line, all rules applied
        }
    }
};
```

**Pros**:
- ✅ Declarative (rules defined in form state)
- ✅ Automatic (no manual visibility management)
- ✅ Type-safe (comptime checked)
- ✅ One-line application (`updateVisibility()`)
- ✅ DRY (rules in one place)

**Cons**:
- ⚠️ Simple boolean rules only (for complex logic, use Approach A)
- ⚠️ Requires Game to track element state

---

### Approach D: Reactive Computed Properties (Advanced)

**Concept**: Form fields can be computed/derived from other fields.

```zig
pub const CharacterFormState = struct {
    class: enum { Warrior, Mage, Rogue } = .Warrior,
    level: u32 = 1,
    
    // Computed properties
    pub fn canSelectMount(self: CharacterFormState) bool {
        return self.level >= 20;
    }
    
    pub fn canSelectSpells(self: CharacterFormState) bool {
        return self.class == .Mage;
    }
    
    pub fn availableAbilityPoints(self: CharacterFormState) u32 {
        return self.level * 2;
    }
    
    // Visibility rules using computed properties
    pub const VisibilityRules = struct {
        pub fn mount_selection_panel(form: CharacterFormState) bool {
            return form.canSelectMount();
        }
        
        pub fn spell_selection_panel(form: CharacterFormState) bool {
            return form.canSelectSpells();
        }
    };
};
```

**Pros**:
- ✅ Maximum flexibility (any logic)
- ✅ Reusable computed properties
- ✅ Complex conditions supported

**Cons**:
- ⚠️ More boilerplate
- ⚠️ Runtime evaluation cost

---

## Recommended Pattern: Approach C (Declarative Rules)

**Best for most use cases** - strikes balance between simplicity and power.

### Complete Example: Wizard Form with Conditional Steps

```zig
pub const WizardFormState = struct {
    // Step 1: Basic Info
    name: [32:0]u8 = std.mem.zeroes([32:0]u8),
    class: enum { Warrior, Mage, Rogue } = .Warrior,
    
    // Step 2: Class-specific options
    // Warrior
    weapon_type: enum { Sword, Axe, Mace } = .Sword,
    shield_enabled: bool = true,
    
    // Mage
    spell_school: enum { Fire, Ice, Lightning } = .Fire,
    mana_regen: f32 = 10,
    
    // Rogue
    stealth_bonus: f32 = 0,
    dual_wield: bool = false,
    
    // Step 3: Confirmation
    current_step: u32 = 1,
    
    // Visibility rules
    pub const VisibilityRules = .{
        // Warrior fields
        .weapon_type_dropdown = "isWarrior",
        .shield_enabled_checkbox = "isWarrior",
        
        // Mage fields
        .spell_school_dropdown = "isMage",
        .mana_regen_slider = "isMage",
        
        // Rogue fields
        .stealth_bonus_slider = "isRogue",
        .dual_wield_checkbox = "isRogue",
        
        // Step visibility
        .step2_panel = "isStep2OrLater",
        .step3_panel = "isStep3",
        .back_button = "isStep2OrLater",
        .next_button = "isNotLastStep",
        .finish_button = "isStep3",
    };
    
    // Helper methods for visibility rules
    pub fn isWarrior(self: WizardFormState) bool {
        return self.class == .Warrior;
    }
    
    pub fn isMage(self: WizardFormState) bool {
        return self.class == .Mage;
    }
    
    pub fn isRogue(self: WizardFormState) bool {
        return self.class == .Rogue;
    }
    
    pub fn isStep2OrLater(self: WizardFormState) bool {
        return self.current_step >= 2;
    }
    
    pub fn isStep3(self: WizardFormState) bool {
        return self.current_step == 3;
    }
    
    pub fn isNotLastStep(self: WizardFormState) bool {
        return self.current_step < 3;
    }
};

// Usage - one line automatically handles all visibility
const GuiHooks = struct {
    pub fn button_clicked(payload: gui.GuiHookPayload) void {
        if (std.mem.eql(u8, payload.button_clicked.element.id, "next_button")) {
            wizard_form.current_step += 1;
            wizard_binder.updateVisibility(&game);  // ← All rules applied
        }
    }
    
    pub fn slider_changed(payload: gui.GuiHookPayload) void {
        const binder = WizardBinder.init(&wizard_form);
        if (binder.handleEvent(payload)) {
            binder.updateVisibility(&game);  // ← Automatic
        }
    }
};
```

## Implementation Plan

### Week 3: Add Conditional Field Support

1. Add `visible: bool` field to all GUI element types
2. Add `setElementVisible()` method to `Game`
3. Extend FormBinder with `updateVisibility()` method
4. Add `VisibilityRules` support to FormBinder
5. Update WizardForm example with conditional fields

### API Design

```zig
// Minimal API additions to Game
pub fn Game(...) type {
    return struct {
        pub fn setElementVisible(self: *Self, element_id: []const u8, visible: bool) void { ... }
        pub fn getElementVisible(self: *Self, element_id: []const u8) bool { ... }
    };
}

// FormBinder extension
pub fn FormBinder(...) type {
    return struct {
        pub fn updateVisibility(self: Self, game: *Game) void { ... }
        pub fn updateVisibilityFor(self: Self, game: *Game, element_id: []const u8) void { ... }
    };
}
```

## Performance Considerations

**Visibility Check Cost**:
- Simple boolean: ~1ns
- Computed property: ~5-10ns
- Typical form: 10-20 elements × 10ns = 100-200ns total
- **Negligible** for typical use cases

**Optimization**:
- Only call `updateVisibility()` when dependent fields change
- Use dirty flags for complex forms
- Cache computed property results if expensive

## Summary

**Conditional fields are fully supported** with multiple approaches:

1. **Approach A**: Regenerate view (most flexible)
2. **Approach B**: Visibility flags (simplest)
3. **Approach C**: Declarative rules (recommended) ⭐
4. **Approach D**: Computed properties (most powerful)

**Recommendation**: Start with **Approach C** (declarative rules) for most forms. It provides the best balance of simplicity, safety, and maintainability.

**One-line usage**:
```zig
binder.updateVisibility(&game);  // Apply all visibility rules
```

This pattern handles the vast majority of conditional field use cases with minimal boilerplate.
