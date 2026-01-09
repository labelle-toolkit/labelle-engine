# Approach A: ECS Components for Form State

**Status**: Proposed  
**Best For**: Forms tied to game entities, data that needs to be visible to ECS systems  

## Overview

Store form state as ECS components attached to entities. Each form gets its own entity with a dedicated state component. This approach leverages labelle-engine's existing ECS architecture for natural integration.

## Architecture

```
┌─────────────────────────────────────┐
│  Game Entity World                  │
├─────────────────────────────────────┤
│  Entity: monster_form               │
│    Component: MonsterFormState      │
│      - name: [128:0]u8              │
│      - health: f32                  │
│      - attack: f32                  │
│      - is_boss: bool                │
│      - is_open: bool                │
│      - is_valid: bool               │
├─────────────────────────────────────┤
│  Entity: wizard_form                │
│    Component: WizardFormState       │
│      - wizard_name: [128:0]u8       │
│      - spell_slots: f32             │
│      - has_familiar: bool           │
│      - is_open: bool                │
└─────────────────────────────────────┘
```

## Implementation

### 1. Define Form State Components

```zig
// In your components.zig

const std = @import("std");
const labelle = @import("labelle-engine");

/// Component holding state for MonsterForm
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
    is_dirty: bool = false,
    
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
    
    /// Get name as slice (safe string access)
    pub fn getName(self: MonsterFormState) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    
    /// Set name from slice (safe string assignment)
    pub fn setName(self: *MonsterFormState, name: []const u8) void {
        const len = @min(name.len, self.name.len - 1);
        @memcpy(self.name[0..len], name[0..len]);
        self.name[len] = 0;
        self.is_dirty = true;
    }
    
    /// Validate form state (per-field rules)
    pub fn validate(self: *MonsterFormState) bool {
        const name_len = std.mem.len(&self.name);
        const name_valid = name_len > 0 and name_len <= 32;
        const health_valid = self.health >= 1 and self.health <= 1000;
        const attack_valid = self.attack >= 1 and self.attack <= 100;
        
        self.is_valid = name_valid and health_valid and attack_valid;
        return self.is_valid;
    }
    
    /// Reset form to defaults
    pub fn reset(self: *MonsterFormState) void {
        self.* = MonsterFormState{};
    }
    
    /// Export data for monster creation
    pub fn toMonsterData(self: MonsterFormState) MonsterData {
        return .{
            .name = self.getName(),
            .health = @intFromFloat(self.health),
            .attack = @intFromFloat(self.attack),
            .is_boss = self.is_boss,
            .element = self.element,
        };
    }
};

/// Component holding state for WizardForm
pub const WizardFormState = struct {
    wizard_name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    spell_slots: f32 = 5,
    school: MagicSchool = .evocation,
    has_familiar: bool = false,
    familiar_type: [64:0]u8 = std.mem.zeroes([64:0]u8),
    
    is_open: bool = false,
    is_valid: bool = false,
    is_dirty: bool = false,
    
    pub const MagicSchool = enum { 
        abjuration, 
        conjuration, 
        divination, 
        enchantment, 
        evocation, 
        illusion, 
        necromancy, 
        transmutation,
        
        pub fn toString(self: MagicSchool) []const u8 {
            return @tagName(self);
        }
    };
    
    pub fn getWizardName(self: WizardFormState) []const u8 {
        return std.mem.sliceTo(&self.wizard_name, 0);
    }
    
    pub fn setWizardName(self: *WizardFormState, name: []const u8) void {
        const len = @min(name.len, self.wizard_name.len - 1);
        @memcpy(self.wizard_name[0..len], name[0..len]);
        self.wizard_name[len] = 0;
        self.is_dirty = true;
    }
    
    pub fn getFamiliarType(self: WizardFormState) []const u8 {
        return std.mem.sliceTo(&self.familiar_type, 0);
    }
    
    pub fn setFamiliarType(self: *WizardFormState, familiar: []const u8) void {
        const len = @min(familiar.len, self.familiar_type.len - 1);
        @memcpy(self.familiar_type[0..len], familiar[0..len]);
        self.familiar_type[len] = 0;
        self.is_dirty = true;
    }
    
    pub fn validate(self: *WizardFormState) bool {
        const name_len = std.mem.len(&self.wizard_name);
        const name_valid = name_len > 0;
        const slots_valid = self.spell_slots >= 1 and self.spell_slots <= 10;
        
        // If has familiar, familiar type must be set
        const familiar_type_len = std.mem.len(&self.familiar_type);
        const familiar_valid = !self.has_familiar or familiar_type_len > 0;
        
        self.is_valid = name_valid and slots_valid and familiar_valid;
        return self.is_valid;
    }
    
    pub fn reset(self: *WizardFormState) void {
        self.* = WizardFormState{};
    }
};

/// Register components with engine
pub const Components = labelle.ComponentRegistry(struct {
    pub const Position = labelle.Position;
    pub const MonsterFormState = MonsterFormState;
    pub const WizardFormState = WizardFormState;
});
```

### 2. Initialize Form Entities

```zig
// In your game initialization

pub fn main() !void {
    var game = try Game.init(allocator, .{
        .window = .{ .width = 1024, .height = 768 },
    });
    defer game.deinit();
    
    // Create form entities
    const monster_form_entity = game.createEntity();
    game.addComponent(monster_form_entity, MonsterFormState{});
    game.tagEntity(monster_form_entity, "monster_form");
    
    const wizard_form_entity = game.createEntity();
    game.addComponent(wizard_form_entity, WizardFormState{});
    game.tagEntity(wizard_form_entity, "wizard_form");
    
    // ... rest of game loop
}
```

### 3. GUI Hook Handlers

```zig
// In gui_handlers.zig

const std = @import("std");
const labelle = @import("labelle-engine");
const GuiHookPayload = labelle.GuiHookPayload;

// Store game reference (set during initialization)
var game_instance: ?*Game = null;

pub fn setGameInstance(game: *Game) void {
    game_instance = game;
}

pub const MyGuiHandlers = struct {
    pub fn text_input_changed(payload: GuiHookPayload) void {
        const info = payload.text_input_changed;
        const game = game_instance.?;
        
        // Parse form_id from element ID (assumes "form_id.field_id" format)
        var parts = std.mem.split(u8, info.element.id, ".");
        const form_id = parts.next() orelse return;
        const field_id = parts.next() orelse return;
        
        // Route to appropriate form handler
        if (std.mem.eql(u8, form_id, "monster_form")) {
            handleMonsterFormTextInput(game, field_id, info.text);
        } else if (std.mem.eql(u8, form_id, "wizard_form")) {
            handleWizardFormTextInput(game, field_id, info.text);
        }
    }
    
    pub fn slider_changed(payload: GuiHookPayload) void {
        const info = payload.slider_changed;
        const game = game_instance.?;
        
        var parts = std.mem.split(u8, info.element.id, ".");
        const form_id = parts.next() orelse return;
        const field_id = parts.next() orelse return;
        
        if (std.mem.eql(u8, form_id, "monster_form")) {
            handleMonsterFormSlider(game, field_id, info.value);
        } else if (std.mem.eql(u8, form_id, "wizard_form")) {
            handleWizardFormSlider(game, field_id, info.value);
        }
    }
    
    pub fn checkbox_toggled(payload: GuiHookPayload) void {
        const info = payload.checkbox_toggled;
        const game = game_instance.?;
        
        var parts = std.mem.split(u8, info.element.id, ".");
        const form_id = parts.next() orelse return;
        const field_id = parts.next() orelse return;
        
        if (std.mem.eql(u8, form_id, "monster_form")) {
            handleMonsterFormCheckbox(game, field_id, info.checked);
        } else if (std.mem.eql(u8, form_id, "wizard_form")) {
            handleWizardFormCheckbox(game, field_id, info.checked);
        }
    }
    
    pub fn button_clicked(payload: GuiHookPayload) void {
        const info = payload.button_clicked;
        const game = game_instance.?;
        
        // Handle form submission buttons
        if (std.mem.eql(u8, info.element.id, "monster_form.submit")) {
            handleMonsterFormSubmit(game);
        } else if (std.mem.eql(u8, info.element.id, "monster_form.cancel")) {
            handleMonsterFormCancel(game);
        } else if (std.mem.eql(u8, info.element.id, "wizard_form.save")) {
            handleWizardFormSave(game);
        }
    }
};

// MonsterForm handlers
fn handleMonsterFormTextInput(game: *Game, field_id: []const u8, text: []const u8) void {
    const entity = game.getEntityByTag("monster_form") orelse return;
    var form_state = game.getComponentMut(entity, MonsterFormState) orelse return;
    
    if (std.mem.eql(u8, field_id, "name_field")) {
        form_state.setName(text);
        _ = form_state.validate();
    }
}

fn handleMonsterFormSlider(game: *Game, field_id: []const u8, value: f32) void {
    const entity = game.getEntityByTag("monster_form") orelse return;
    var form_state = game.getComponentMut(entity, MonsterFormState) orelse return;
    
    if (std.mem.eql(u8, field_id, "health_slider")) {
        form_state.health = value;
        _ = form_state.validate();
    } else if (std.mem.eql(u8, field_id, "attack_slider")) {
        form_state.attack = value;
        _ = form_state.validate();
    }
}

fn handleMonsterFormCheckbox(game: *Game, field_id: []const u8, checked: bool) void {
    const entity = game.getEntityByTag("monster_form") orelse return;
    var form_state = game.getComponentMut(entity, MonsterFormState) orelse return;
    
    if (std.mem.eql(u8, field_id, "is_boss")) {
        form_state.is_boss = checked;
        _ = form_state.validate();
    }
}

fn handleMonsterFormSubmit(game: *Game) void {
    const entity = game.getEntityByTag("monster_form") orelse return;
    const form_state = game.getComponent(entity, MonsterFormState) orelse return;
    
    if (!form_state.is_valid) {
        std.log.warn("Monster form is invalid!", .{});
        return;
    }
    
    // Create the monster!
    const monster_data = form_state.toMonsterData();
    const monster_entity = createMonster(game, monster_data);
    std.log.info("Created monster '{s}' with entity ID {d}", .{
        monster_data.name, 
        monster_entity,
    });
    
    // Close and reset form
    var mutable_state = game.getComponentMut(entity, MonsterFormState) orelse return;
    mutable_state.is_open = false;
    mutable_state.reset();
}

fn handleMonsterFormCancel(game: *Game) void {
    const entity = game.getEntityByTag("monster_form") orelse return;
    var form_state = game.getComponentMut(entity, MonsterFormState) orelse return;
    
    form_state.is_open = false;
    form_state.reset();
}

// WizardForm handlers
fn handleWizardFormTextInput(game: *Game, field_id: []const u8, text: []const u8) void {
    const entity = game.getEntityByTag("wizard_form") orelse return;
    var form_state = game.getComponentMut(entity, WizardFormState) orelse return;
    
    if (std.mem.eql(u8, field_id, "name_field")) {
        form_state.setWizardName(text);
        _ = form_state.validate();
    } else if (std.mem.eql(u8, field_id, "familiar_field")) {
        form_state.setFamiliarType(text);
        _ = form_state.validate();
    }
}

fn handleWizardFormSlider(game: *Game, field_id: []const u8, value: f32) void {
    const entity = game.getEntityByTag("wizard_form") orelse return;
    var form_state = game.getComponentMut(entity, WizardFormState) orelse return;
    
    if (std.mem.eql(u8, field_id, "spell_slots")) {
        form_state.spell_slots = value;
        _ = form_state.validate();
    }
}

fn handleWizardFormCheckbox(game: *Game, field_id: []const u8, checked: bool) void {
    const entity = game.getEntityByTag("wizard_form") orelse return;
    var form_state = game.getComponentMut(entity, WizardFormState) orelse return;
    
    if (std.mem.eql(u8, field_id, "has_familiar")) {
        form_state.has_familiar = checked;
        
        // If unchecking, clear familiar type
        if (!checked) {
            form_state.familiar_type = std.mem.zeroes([64:0]u8);
        }
        
        _ = form_state.validate();
    }
}

fn handleWizardFormSave(game: *Game) void {
    const entity = game.getEntityByTag("wizard_form") orelse return;
    const form_state = game.getComponent(entity, WizardFormState) orelse return;
    
    if (!form_state.is_valid) {
        std.log.warn("Wizard form is invalid!", .{});
        return;
    }
    
    // Save wizard configuration
    saveWizardConfig(form_state);
    std.log.info("Wizard '{s}' configuration saved!", .{form_state.getWizardName()});
    
    // Close form
    var mutable_state = game.getComponentMut(entity, WizardFormState) orelse return;
    mutable_state.is_open = false;
}
```

### 4. ECS System Integration (Optional)

You can create ECS systems that react to form state changes:

```zig
// In your systems.zig

/// System that auto-saves forms when they become dirty
pub fn FormAutoSaveSystem(game: *Game) void {
    // Query all entities with MonsterFormState
    var monster_iter = game.query(.{MonsterFormState});
    while (monster_iter.next()) |entity| {
        var form = game.getComponentMut(entity, MonsterFormState) orelse continue;
        
        if (form.is_dirty) {
            // Save to local storage or cache
            saveFormStateToLocalStorage("monster_form", form);
            form.is_dirty = false;
            std.log.debug("Auto-saved monster form", .{});
        }
    }
    
    // Query all entities with WizardFormState
    var wizard_iter = game.query(.{WizardFormState});
    while (wizard_iter.next()) |entity| {
        var form = game.getComponentMut(entity, WizardFormState) orelse continue;
        
        if (form.is_dirty) {
            saveFormStateToLocalStorage("wizard_form", form);
            form.is_dirty = false;
            std.log.debug("Auto-saved wizard form", .{});
        }
    }
}

/// System that validates forms on every frame
pub fn FormValidationSystem(game: *Game) void {
    var monster_iter = game.query(.{MonsterFormState});
    while (monster_iter.next()) |entity| {
        var form = game.getComponentMut(entity, MonsterFormState) orelse continue;
        if (form.is_open) {
            _ = form.validate();
        }
    }
    
    var wizard_iter = game.query(.{WizardFormState});
    while (wizard_iter.next()) |entity| {
        var form = game.getComponentMut(entity, WizardFormState) orelse continue;
        if (form.is_open) {
            _ = form.validate();
        }
    }
}
```

## Pros

✅ **Type-Safe**: Compile-time validation of field types and names  
✅ **ECS Integration**: Forms are queryable by systems, can react to state changes  
✅ **Entity Binding**: Natural for forms that configure/create entities  
✅ **Component Lifecycle**: Benefit from component callbacks (onAdd, onRemove, onSet)  
✅ **Visible State**: Form state is visible in ECS debuggers/inspectors  
✅ **Validation Built-In**: Each form defines its own validation logic  
✅ **Serialization Ready**: Forms can be serialized with scenes  

## Cons

❌ **Manual Wiring**: Each form needs dedicated handler functions  
❌ **Verbose**: Lots of string comparisons for field routing  
❌ **Scaling Overhead**: More forms = more boilerplate handlers  
❌ **Entity Overhead**: Each form requires an entity (minimal cost but conceptually odd)  
❌ **No Auto-Binding**: Fields must be manually mapped in handlers  

## Best Use Cases

1. **Character Creation Forms**: Creating player/NPC entities
2. **Building Configuration**: Configuring game buildings/structures
3. **Item Crafting UI**: Forms that result in item entities
4. **Entity Editors**: Runtime editing of entity properties
5. **Settings Forms**: Game settings that persist as components

## Example: Complete MonsterForm Flow

```zig
// 1. User opens form
const entity = game.getEntityByTag("monster_form").?;
var form = game.getComponentMut(entity, MonsterFormState).?;
form.is_open = true;
form.reset();

// 2. User types name → text_input_changed hook fired
// Handler updates form.name via form.setName()
// form.validate() runs automatically

// 3. User adjusts health slider → slider_changed hook fired
// Handler updates form.health
// form.validate() runs automatically

// 4. User clicks submit → button_clicked hook fired
// Handler checks form.is_valid
// If valid: creates monster entity, closes form, resets state

// 5. Optional: ECS systems can react to form changes
// FormAutoSaveSystem saves dirty forms to local storage
// FormValidationSystem re-validates open forms each frame
```

## Comparison with Other Approaches

| Feature | ECS Components | FormManager | Form Context | FormBinder |
|---------|---------------|-------------|--------------|------------|
| Type Safety | ✅ High | ⚠️ Medium | ✅ High | ✅ High |
| Boilerplate | ❌ High | ✅ Low | ⚠️ Medium | ✅ Low |
| ECS Integration | ✅ Native | ❌ None | ⚠️ Manual | ⚠️ Manual |
| Auto-Binding | ❌ No | ❌ No | ⚠️ Partial | ✅ Yes |
| Scalability | ⚠️ Manual per form | ✅ Automatic | ✅ Automatic | ✅ Automatic |
| Debug Visibility | ✅ ECS inspector | ❌ Hidden | ⚠️ Depends | ⚠️ Depends |

## Migration Path

If starting with this approach and later wanting to switch:

**To FormManager**: Extract component data to hash maps
**To FormBinder**: Keep components, add automatic binding layer
**To Form Context**: Add form registry, pass pointers in payloads

## Recommendation

**Use ECS Components when:**
- Forms create/edit game entities
- You want ECS systems to react to form changes
- Form state needs to be visible in debug tools
- You have a small number of forms (< 10)
- You value type safety over boilerplate reduction

**Consider alternatives when:**
- You have many similar forms (> 20)
- Forms are purely UI configuration (not entity-related)
- You want minimal boilerplate
- You need runtime form generation
