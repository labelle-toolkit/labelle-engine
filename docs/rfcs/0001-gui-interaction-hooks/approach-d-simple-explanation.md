# Approach D: FormBinder - Simple Explanation

**The Big Idea**: Use Zig's compile-time reflection to automatically connect form fields to GUI events, eliminating boilerplate code.

## The Problem It Solves

Without FormBinder, you write lots of repetitive code:

```zig
// ❌ Without FormBinder: Lots of manual wiring (50+ lines per form)
pub fn text_input_changed(payload: GuiHookPayload) void {
    var parts = std.mem.split(u8, payload.element.id, ".");
    const form_id = parts.next() orelse return;
    const field_id = parts.next() orelse return;
    
    if (std.mem.eql(u8, form_id, "monster_form")) {
        if (std.mem.eql(u8, field_id, "name_field")) {
            handleMonsterName(payload.text);
        }
    } else if (std.mem.eql(u8, form_id, "wizard_form")) {
        if (std.mem.eql(u8, field_id, "wizard_name")) {
            handleWizardName(payload.text);
        }
    }
    // ... more if/else chains for every field ...
}
```

With FormBinder, you write one line:

```zig
// ✅ With FormBinder: One line handles ALL forms!
pub fn text_input_changed(payload: GuiHookPayload) void {
    monster_binder.handleEvent(payload);
    wizard_binder.handleEvent(payload);
}
```

## How It Works: Step-by-Step

### Step 1: Define Your Form Data

Just create a regular struct with your form fields:

```zig
pub const MonsterFormState = struct {
    // Your form fields
    name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,
    
    // Optional: Custom setter (FormBinder will find and use this)
    pub fn setName(self: *MonsterFormState, text: []const u8) void {
        const len = @min(text.len, self.name.len - 1);
        @memcpy(self.name[0..len], text[0..len]);
        self.name[len] = 0;
    }
    
    // Optional: Validation (FormBinder will call this automatically)
    pub fn validate(self: *MonsterFormState) bool {
        const name_len = std.mem.len(&self.name);
        self.is_valid = name_len > 0 and self.health >= 1 and self.attack >= 1;
        return self.is_valid;
    }
};
```

### Step 2: Create a FormBinder

FormBinder is a **generic function** that creates a custom type for your form:

```zig
// Create a binder type for MonsterFormState
const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
//                                ^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^
//                                Your struct type  Form ID prefix

// Create an instance with a pointer to your form state
var monster_form = MonsterFormState{};
const monster_binder = MonsterBinder.init(&monster_form);
```

### Step 3: Define Your GUI (in .zon or code)

Use a naming convention: `form_id.field_name`

```zig
// The element IDs match your struct field names!
gui.textField(.{ .id = "monster_form.name" });         // ← matches .name field
gui.slider(.{ .id = "monster_form.health", ... });     // ← matches .health field
gui.slider(.{ .id = "monster_form.attack", ... });     // ← matches .attack field
gui.checkbox(.{ .id = "monster_form.is_boss", ... });  // ← matches .is_boss field
gui.button(.{ .id = "monster_form.submit", ... });
```

### Step 4: Write Minimal Handlers

Just pass events to the binder - it does the rest:

```zig
pub const MyGuiHandlers = struct {
    pub fn text_input_changed(payload: GuiHookPayload) void {
        monster_binder.handleEvent(payload);  // ← That's it!
    }
    
    pub fn slider_changed(payload: GuiHookPayload) void {
        monster_binder.handleEvent(payload);  // ← That's it!
    }
    
    pub fn checkbox_toggled(payload: GuiHookPayload) void {
        monster_binder.handleEvent(payload);  // ← That's it!
    }
};
```

## The "Magic": How FormBinder Works Internally

FormBinder uses **comptime reflection** - it inspects your struct at compile time and generates custom code for each field.

### What Happens at Compile Time

When you create `FormBinder(MonsterFormState, "monster_form")`, Zig:

1. **Inspects MonsterFormState** using `@typeInfo()`
2. **Finds all fields**: `name`, `health`, `attack`, `is_boss`
3. **Generates code** for each field type:
   - String fields (`[N:0]u8`) → Look for `setName()` or copy directly
   - Float fields (`f32`) → Direct assignment
   - Bool fields (`bool`) → Direct assignment
4. **Creates routing logic**: Match element IDs to field names

### Generated Code (Conceptual)

This is roughly what FormBinder generates at compile time:

```zig
// FormBinder generates something like this internally:
pub fn handleEvent(payload: GuiHookPayload) void {
    switch (payload) {
        .text_input_changed => |info| {
            // Check if "monster_form.xxx"
            if (startsWith(info.element.id, "monster_form.")) {
                const field = info.element.id["monster_form.".len..];
                
                // Compare against each field at compile time
                if (eql(field, "name")) {
                    // Found setName() method? Use it!
                    form_state.setName(info.text);
                    form_state.validate();
                }
            }
        },
        .slider_changed => |info| {
            if (startsWith(info.element.id, "monster_form.")) {
                const field = info.element.id["monster_form.".len..];
                
                if (eql(field, "health")) {
                    form_state.health = info.value;
                    form_state.validate();
                } else if (eql(field, "attack")) {
                    form_state.attack = info.value;
                    form_state.validate();
                }
            }
        },
        .checkbox_toggled => |info| {
            if (startsWith(info.element.id, "monster_form.")) {
                const field = info.element.id["monster_form.".len..];
                
                if (eql(field, "is_boss")) {
                    form_state.is_boss = info.checked;
                    form_state.validate();
                }
            }
        },
    }
}
```

**But you don't write any of this!** FormBinder generates it automatically by reflecting on your struct.

## Real-World Example: Monster Creation Form

Let's see a complete, realistic example:

### Your Form Struct

```zig
pub const MonsterFormState = struct {
    name: [128:0]u8 = std.mem.zeroes([128:0]u8),
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,
    is_valid: bool = false,
    
    pub fn setName(self: *MonsterFormState, text: []const u8) void {
        const len = @min(text.len, 127);
        @memcpy(self.name[0..len], text[0..len]);
        self.name[len] = 0;
    }
    
    pub fn getName(self: MonsterFormState) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    
    pub fn validate(self: *MonsterFormState) bool {
        const name_len = self.getName().len;
        self.is_valid = name_len > 0 and self.health >= 1 and self.attack >= 1;
        return self.is_valid;
    }
};
```

### Setup (One Time)

```zig
// In your game initialization
var monster_form = MonsterFormState{};
const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
const monster_binder = MonsterBinder.init(&monster_form);

// Store binder globally or in game state
gui_handlers.setMonsterBinder(monster_binder);
```

### Your GUI Rendering Code

```zig
pub fn renderMonsterForm(gui: *Gui) void {
    gui.beginPanel(.{ .position = .{ .x = 100, .y = 100 }, .size = .{ .width = 400, .height = 300 } });
    
    gui.label(.{ .text = "Create Monster", .position = .{ .x = 120, .y = 120 } });
    
    gui.textField(.{ 
        .id = "monster_form.name",  // ← Matches .name field
        .position = .{ .x = 120, .y = 150 },
        .text = monster_form.getName(),
    });
    
    gui.label(.{ .text = "Health:", .position = .{ .x = 120, .y = 190 } });
    monster_form.health = gui.slider(.{ 
        .id = "monster_form.health",  // ← Matches .health field
        .position = .{ .x = 200, .y = 190 },
        .value = monster_form.health,
        .min = 1,
        .max = 1000,
    });
    
    gui.label(.{ .text = "Attack:", .position = .{ .x = 120, .y = 230 } });
    monster_form.attack = gui.slider(.{ 
        .id = "monster_form.attack",  // ← Matches .attack field
        .position = .{ .x = 200, .y = 230 },
        .value = monster_form.attack,
        .min = 1,
        .max = 100,
    });
    
    if (gui.checkbox(.{ 
        .id = "monster_form.is_boss",  // ← Matches .is_boss field
        .position = .{ .x = 120, .y = 270 },
        .checked = monster_form.is_boss,
        .text = "Is Boss",
    })) {
        monster_form.is_boss = !monster_form.is_boss;
    }
    
    gui.button(.{ 
        .id = "monster_form.submit",
        .position = .{ .x = 120, .y = 310 },
        .text = "Create Monster",
    });
    
    gui.endPanel();
}
```

### Your Handlers (Minimal!)

```zig
pub const MyGuiHandlers = struct {
    pub fn text_input_changed(payload: GuiHookPayload) void {
        monster_binder.handleEvent(payload);  // Automatically updates monster_form.name!
    }
    
    pub fn slider_changed(payload: GuiHookPayload) void {
        monster_binder.handleEvent(payload);  // Automatically updates health/attack!
    }
    
    pub fn checkbox_toggled(payload: GuiHookPayload) void {
        monster_binder.handleEvent(payload);  // Automatically updates is_boss!
    }
    
    pub fn button_clicked(payload: GuiHookPayload) void {
        const info = payload.button_clicked;
        
        if (std.mem.eql(u8, info.element.id, "monster_form.submit")) {
            if (monster_form.is_valid) {
                createMonster(monster_form);
                monster_form = MonsterFormState{};  // Reset
            } else {
                std.log.warn("Form is invalid!", .{});
            }
        }
    }
};
```

## What You Get For Free

When you use FormBinder, you automatically get:

✅ **Automatic Field Routing**: `"monster_form.name"` → `monster_form.name`  
✅ **Type Checking**: Compiler errors if field types don't match  
✅ **Automatic Validation**: Calls `validate()` after every change  
✅ **Custom Setters**: Uses `setName()` if you define it  
✅ **Zero Boilerplate**: One handler per event type for ALL forms  
✅ **Zero Runtime Cost**: All routing resolved at compile time  

## Scaling to Multiple Forms

Adding a second form (e.g., WizardForm) is trivial:

```zig
// 1. Define wizard form
var wizard_form = WizardFormState{};
const WizardBinder = FormBinder(WizardFormState, "wizard_form");
const wizard_binder = WizardBinder.init(&wizard_form);

// 2. Update handlers - just add one line each!
pub fn text_input_changed(payload: GuiHookPayload) void {
    monster_binder.handleEvent(payload);
    wizard_binder.handleEvent(payload);  // ← Added!
}

pub fn slider_changed(payload: GuiHookPayload) void {
    monster_binder.handleEvent(payload);
    wizard_binder.handleEvent(payload);  // ← Added!
}

// That's it! No additional routing logic needed.
```

## When NOT to Use FormBinder

FormBinder is overkill for:

❌ **Simple buttons** - Just use immediate-mode:
```zig
if (gui.button(.{ .text = "Pause" })) {
    game.pause();
}
```

❌ **Very few forms** (< 5) - Manual routing might be clearer

❌ **Heavy custom logic per field** - Use Form Context instead

❌ **Runtime form generation** - Use FormManager instead

## Summary: The Three-Step Pattern

1. **Define struct** with your form fields
2. **Create binder**: `FormBinder(YourStruct, "form_id")`
3. **Call handleEvent()** in your handlers

That's it! FormBinder does the rest through compile-time reflection.

## Key Insight

FormBinder leverages **Zig's comptime system** to generate repetitive code automatically. You write the "what" (form structure), and FormBinder generates the "how" (routing logic) at compile time with zero runtime overhead.

Think of it like a macro that writes boilerplate code for you, except it's type-safe and integrated into Zig's type system.
