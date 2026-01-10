# Folder Structure for Projects Using GUI Interaction System

This guide shows the recommended folder structure for labelle-engine projects that use the GUI interaction system with forms (especially with FormBinder).

## Minimal Project Structure (Existing)

A basic labelle-engine project already has this structure:

```
my-game/
├── build.zig              # Build configuration
├── build.zig.zon          # Dependencies
├── main.zig               # Entry point
├── project.labelle        # Project configuration
│
├── scenes/                # Game scenes (.zon files)
│   └── game_scene.zon
│
├── prefabs/               # Reusable entity templates (.zon files)
│   ├── player.zon
│   └── enemy.zon
│
├── components/            # Custom ECS components
│   ├── velocity.zig
│   ├── gravity.zig
│   └── health.zig
│
├── scripts/               # Entity behavior scripts
│   ├── player_input.zig
│   └── movement.zig
│
├── resources/             # Sprites, sounds, etc.
│   ├── characters.png
│   └── characters_animations.zon
│
└── .labelle/              # Generated build files (don't edit)
    ├── build.zig
    └── build.zig.zon
```

## Extended Structure for GUI Forms (New)

When using the GUI interaction system with forms, you add these folders:

```
my-game/
├── build.zig
├── build.zig.zon
├── main.zig
├── project.labelle
│
├── scenes/
│   └── game_scene.zon
│
├── prefabs/
│   ├── player.zon
│   └── enemy.zon
│
├── components/
│   ├── velocity.zig
│   ├── gravity.zig
│   └── health.zig
│
├── scripts/
│   ├── player_input.zig
│   └── movement.zig
│
├── resources/
│   ├── characters.png
│   └── characters_animations.zon
│
├── gui/                   # ← NEW: GUI view definitions
│   ├── hud.zon           # HUD elements (health bars, score, etc.)
│   ├── main_menu.zon     # Main menu
│   ├── pause_menu.zon    # Pause menu
│   └── monster_form.zon  # Monster creation form
│
├── forms/                 # ← NEW: Form state structs (optional)
│   ├── monster_form.zig  # MonsterFormState struct
│   └── wizard_form.zig   # WizardFormState struct
│
├── gui_handlers/          # ← NEW: GUI event handlers (optional)
│   ├── mod.zig           # Re-exports all handlers
│   ├── monster_form.zig  # Handlers for monster form
│   └── wizard_form.zig   # Handlers for wizard form
│
└── .labelle/
    ├── build.zig
    └── build.zig.zon
```

## Alternative Structures

Depending on your project size and preferences, you have several options:

### Option A: Single File (Small Projects)

For small projects with 1-3 simple forms:

```
my-game/
├── main.zig              # Contains forms, handlers, and game logic
├── gui/
│   ├── hud.zon
│   └── monster_form.zon
└── ... (other folders)
```

**In main.zig:**
```zig
const Forms = struct {
    pub const MonsterFormState = struct { ... };
    pub const WizardFormState = struct { ... };
};

const GuiHandlers = struct {
    pub fn text_input_changed(payload: GuiHookPayload) void { ... }
    pub fn slider_changed(payload: GuiHookPayload) void { ... }
};
```

### Option B: Separate Folders (Medium Projects)

For medium projects with 5-20 forms:

```
my-game/
├── forms/                # Form state structs
│   ├── monster_form.zig
│   ├── wizard_form.zig
│   └── settings_form.zig
│
├── gui_handlers/         # GUI event handlers
│   ├── mod.zig          # Exports all handlers
│   ├── forms.zig        # Form-related handlers
│   └── menus.zig        # Menu-related handlers
│
└── gui/                  # GUI view definitions
    ├── hud.zon
    ├── monster_form.zon
    ├── wizard_form.zon
    └── settings_menu.zon
```

### Option C: Feature-Based (Large Projects)

For large projects with many features:

```
my-game/
├── features/
│   ├── character_creator/
│   │   ├── forms.zig              # CharacterFormState
│   │   ├── handlers.zig           # Character form handlers
│   │   └── views/
│   │       ├── appearance.zon     # Appearance selection
│   │       └── attributes.zon     # Attribute allocation
│   │
│   ├── crafting/
│   │   ├── forms.zig              # CraftingFormState
│   │   ├── handlers.zig           # Crafting handlers
│   │   └── views/
│   │       └── crafting_ui.zon
│   │
│   └── inventory/
│       ├── forms.zig              # InventoryFormState
│       ├── handlers.zig           # Inventory handlers
│       └── views/
│           ├── inventory.zon
│           └── item_detail.zon
│
├── gui/                           # Shared/global GUI
│   ├── hud.zon
│   └── main_menu.zon
│
└── ... (other folders)
```

## Recommended Structure by Project Size

### Small Projects (< 5 forms)

**Recommended**: Option A (Single File)

```
my-game/
├── main.zig              # Everything here
├── gui/
│   └── *.zon            # Just GUI definitions
└── ... (standard folders)
```

**Pros:**
- Simple, no extra folders
- Easy to navigate
- Quick to prototype

**Cons:**
- Can get large if forms are complex

### Medium Projects (5-20 forms)

**Recommended**: Option B (Separate Folders)

```
my-game/
├── main.zig
├── forms/                # Form states
│   └── *.zig
├── gui_handlers/         # Handlers
│   └── *.zig
├── gui/                  # View definitions
│   └── *.zon
└── ... (standard folders)
```

**Pros:**
- Clear separation of concerns
- Easy to find forms/handlers
- Scales well

**Cons:**
- More folders to manage
- Need to update imports when adding forms

### Large Projects (20+ forms, Multiple Features)

**Recommended**: Option C (Feature-Based)

```
my-game/
├── features/
│   ├── character_creator/
│   ├── crafting/
│   └── inventory/
└── ... (standard folders)
```

**Pros:**
- Features are self-contained
- Easy to add/remove features
- Team-friendly (different devs can own features)

**Cons:**
- More complex structure
- Need careful planning

## File Naming Conventions

### GUI View Files (.zon)

```
gui/
├── hud.zon                # Lowercase, descriptive
├── main_menu.zon          # Snake_case for multi-word
├── pause_menu.zon
├── monster_form.zon       # "form" suffix for forms
└── settings_panel.zon     # "panel" suffix for panels
```

### Form State Files (.zig)

```
forms/
├── monster_form.zig       # Contains MonsterFormState struct
├── wizard_form.zig        # Contains WizardFormState struct
└── settings_form.zig      # Contains SettingsFormState struct
```

**Convention**: File name matches the form ID used in GUI.

### Handler Files (.zig)

```
gui_handlers/
├── mod.zig               # Re-exports all handlers
├── forms.zig             # Generic form handlers (uses FormBinder)
├── monster_handlers.zig  # Monster-specific button handlers
└── wizard_handlers.zig   # Wizard-specific button handlers
```

## Example: Complete Monster Form Project

Here's a complete example showing all files for a project with a monster creation form:

```
my-game/
├── build.zig
├── build.zig.zon
├── main.zig
├── project.labelle
│
├── gui/
│   ├── hud.zon
│   └── monster_form.zon          # ← Form definition
│
├── forms/
│   └── monster_form.zig          # ← Form state struct
│
├── gui_handlers/
│   ├── mod.zig                   # ← Exports handlers
│   └── forms.zig                 # ← Generic handlers (FormBinder)
│
├── scenes/
│   └── game_scene.zon
│
├── components/
│   ├── monster_stats.zig         # ← Monster component
│   └── ...
│
└── scripts/
    └── monster_ai.zig
```

### File Contents

**gui/monster_form.zon:**
```zig
.{
    .name = "monster_form",
    .elements = .{
        .{ .Label = .{ .text = "Create Monster", .position = .{ .x = 100, .y = 50 } } },
        .{ .TextField = .{ .id = "monster_form.name", .position = .{ .x = 100, .y = 80 } } },
        .{ .Slider = .{ .id = "monster_form.health", .position = .{ .x = 100, .y = 120 }, .min = 1, .max = 1000, .value = 100 } },
        .{ .Slider = .{ .id = "monster_form.attack", .position = .{ .x = 100, .y = 160 }, .min = 1, .max = 100, .value = 10 } },
        .{ .Checkbox = .{ .id = "monster_form.is_boss", .position = .{ .x = 100, .y = 200 }, .text = "Is Boss" } },
        .{ .Button = .{ .id = "monster_form.submit", .position = .{ .x = 100, .y = 240 }, .text = "Create" } },
    },
}
```

**forms/monster_form.zig:**
```zig
const std = @import("std");

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
    
    pub fn validate(self: *MonsterFormState) bool {
        const name_len = std.mem.len(&self.name);
        self.is_valid = name_len > 0 and self.health >= 1 and self.attack >= 1;
        return self.is_valid;
    }
};
```

**gui_handlers/forms.zig:**
```zig
const std = @import("std");
const labelle = @import("labelle-engine");
const GuiHookPayload = labelle.GuiHookPayload;
const FormBinder = labelle.FormBinder;
const MonsterFormState = @import("../forms/monster_form.zig").MonsterFormState;

const MonsterBinder = FormBinder(MonsterFormState, "monster_form");
var monster_binder: ?MonsterBinder = null;

pub fn setMonsterBinder(binder: MonsterBinder) void {
    monster_binder = binder;
}

pub const FormHandlers = struct {
    pub fn text_input_changed(payload: GuiHookPayload) void {
        if (monster_binder) |binder| {
            binder.handleEvent(payload);
        }
    }
    
    pub fn slider_changed(payload: GuiHookPayload) void {
        if (monster_binder) |binder| {
            binder.handleEvent(payload);
        }
    }
    
    pub fn checkbox_toggled(payload: GuiHookPayload) void {
        if (monster_binder) |binder| {
            binder.handleEvent(payload);
        }
    }
    
    pub fn button_clicked(payload: GuiHookPayload) void {
        const info = payload.button_clicked;
        
        if (std.mem.eql(u8, info.element.id, "monster_form.submit")) {
            if (monster_binder) |binder| {
                if (binder.form_state.is_valid) {
                    createMonster(binder.form_state);
                    binder.form_state.* = MonsterFormState{};
                }
            }
        }
    }
};

fn createMonster(form: *MonsterFormState) void {
    std.log.info("Creating monster: {s}, HP={d}, ATK={d}, Boss={}", .{
        std.mem.sliceTo(&form.name, 0),
        form.health,
        form.attack,
        form.is_boss,
    });
}
```

**gui_handlers/mod.zig:**
```zig
pub const FormHandlers = @import("forms.zig").FormHandlers;

// Re-export for convenience
pub const setMonsterBinder = @import("forms.zig").setMonsterBinder;
```

**main.zig:**
```zig
const std = @import("std");
const labelle = @import("labelle-engine");
const MonsterFormState = @import("forms/monster_form.zig").MonsterFormState;
const gui_handlers = @import("gui_handlers/mod.zig");

// Use compile-time generics for GUI hooks (zero runtime overhead)
const Game = labelle.GameWith(gui_handlers.FormHandlers);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize game with hooks baked in at compile time
    var game = try Game.init(allocator, .{
        .window = .{ .width = 800, .height = 600, .title = "Monster Creator" },
    });
    defer game.deinit();

    // Create form state and binder
    var monster_form = MonsterFormState{};
    const MonsterBinder = labelle.FormBinder(MonsterFormState, "monster_form");
    const monster_binder = MonsterBinder.init(&monster_form);

    // Set up binder reference for handlers
    gui_handlers.setMonsterBinder(monster_binder);

    // Load scenes and GUI views
    const Views = labelle.ViewRegistry(.{
        .monster_form = @import("gui/monster_form.zon"),
    });

    // Game loop - hooks are called automatically via compile-time dispatch
    while (game.isRunning()) {
        game.renderGui(Views);
    }
}
```

## Key Points

1. **You don't NEED extra folders** - start with everything in `main.zig`
2. **Add folders as you grow** - refactor when `main.zig` gets too large
3. **Follow naming conventions** - `form_id.field_name` pattern
4. **Keep GUI definitions in `gui/`** - `.zon` files for all views
5. **Optional separation** - `forms/` and `gui_handlers/` are optional for organization

## Migration Path

**Start Simple:**
```
my-game/main.zig           # Everything here
my-game/gui/hud.zon        # Just GUI definitions
```

**Grow as Needed:**
```
my-game/main.zig           # Game logic only
my-game/forms/*.zig        # Form states
my-game/gui_handlers/*.zig # Handlers
my-game/gui/*.zon          # GUI definitions
```

**Scale for Teams:**
```
my-game/features/*/        # Feature modules
my-game/gui/*.zon          # Shared GUI
```

The folder structure is flexible and grows with your project!
