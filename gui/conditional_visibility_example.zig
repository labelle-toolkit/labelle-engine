//! Conditional Visibility Example
//!
//! This example demonstrates how to use FormBinder's conditional visibility
//! feature to show/hide form fields based on other field values.
//!
//! Run tests with: zig build unit-test

const std = @import("std");
const FormBinder = @import("form_binder.zig").FormBinder;

// ============================================================================
// Example 1: Boss Monster Form
// ============================================================================

/// Monster creation form with boss-specific fields
pub const MonsterFormState = struct {
    name: [32:0]u8 = std.mem.zeroes([32:0]u8),
    health: f32 = 100,
    attack: f32 = 10,
    is_boss: bool = false,

    // Boss-only fields
    boss_title: [32:0]u8 = std.mem.zeroes([32:0]u8),
    boss_phase_count: u32 = 1,
    enrage_threshold: f32 = 0.3,

    /// Define which elements are conditional
    pub const VisibilityRules = struct {
        boss_title_label: void = {},
        boss_title_field: void = {},
        boss_phase_label: void = {},
        boss_phase_slider: void = {},
        enrage_label: void = {},
        enrage_slider: void = {},
    };

    /// Evaluate visibility based on is_boss checkbox
    pub fn isVisible(self: MonsterFormState, element_id: []const u8) bool {
        // Boss-specific fields only visible when is_boss = true
        if (std.mem.startsWith(u8, element_id, "boss_") or
            std.mem.startsWith(u8, element_id, "enrage_"))
        {
            return self.is_boss;
        }
        return true;
    }
};

// Usage in game code:
// ```
// const GuiHooks = struct {
//     pub fn checkbox_changed(payload: gui.GuiHookPayload) void {
//         const binder = MonsterBinder.init(&monster_form);
//         if (binder.handleEvent(payload)) {
//             // Update visibility when is_boss changes
//             binder.updateVisibilityWith(updateElement);
//         }
//     }
// };
//
// fn updateElement(element_id: []const u8, visible: bool) void {
//     game.setElementVisible(element_id, visible);
// }
// ```

// ============================================================================
// Example 2: Character Creation Wizard
// ============================================================================

/// Multi-step character creation with class-specific options
pub const CharacterFormState = struct {
    // Step 1: Basic Info
    name: [32:0]u8 = std.mem.zeroes([32:0]u8),
    class: enum { Warrior, Mage, Rogue } = .Warrior,

    // Step 2: Class-specific options
    // Warrior
    weapon_type: enum { Sword, Axe, Mace } = .Sword,
    shield_enabled: bool = true,

    // Mage
    spell_school: enum { Fire, Ice, Lightning } = .Fire,
    mana_bonus: f32 = 10,

    // Rogue
    stealth_bonus: f32 = 0,
    dual_wield: bool = false,

    // Step 3: Confirmation
    current_step: u32 = 1,

    /// Visibility rules for multi-step + class-specific form
    pub const VisibilityRules = struct {
        // Warrior fields
        weapon_dropdown: void = {},
        shield_checkbox: void = {},

        // Mage fields
        spell_dropdown: void = {},
        mana_slider: void = {},

        // Rogue fields
        stealth_slider: void = {},
        dual_wield_checkbox: void = {},

        // Step navigation
        step2_panel: void = {},
        step3_panel: void = {},
        back_button: void = {},
        next_button: void = {},
        finish_button: void = {},
    };

    pub fn isVisible(self: CharacterFormState, element_id: []const u8) bool {
        // Class-specific fields
        if (std.mem.eql(u8, element_id, "weapon_dropdown") or
            std.mem.eql(u8, element_id, "shield_checkbox"))
        {
            return self.class == .Warrior;
        }

        if (std.mem.eql(u8, element_id, "spell_dropdown") or
            std.mem.eql(u8, element_id, "mana_slider"))
        {
            return self.class == .Mage;
        }

        if (std.mem.eql(u8, element_id, "stealth_slider") or
            std.mem.eql(u8, element_id, "dual_wield_checkbox"))
        {
            return self.class == .Rogue;
        }

        // Step-based visibility
        if (std.mem.eql(u8, element_id, "step2_panel")) {
            return self.current_step >= 2;
        }

        if (std.mem.eql(u8, element_id, "step3_panel")) {
            return self.current_step == 3;
        }

        if (std.mem.eql(u8, element_id, "back_button")) {
            return self.current_step > 1;
        }

        if (std.mem.eql(u8, element_id, "next_button")) {
            return self.current_step < 3;
        }

        if (std.mem.eql(u8, element_id, "finish_button")) {
            return self.current_step == 3;
        }

        return true;
    }
};

// ============================================================================
// Example 3: Advanced Settings Toggle
// ============================================================================

/// Settings form with advanced options panel
pub const SettingsFormState = struct {
    // Basic settings
    volume: f32 = 0.5,
    fullscreen: bool = false,
    show_advanced: bool = false,

    // Advanced settings
    vsync: bool = true,
    max_fps: u32 = 60,
    texture_quality: enum { Low, Medium, High, Ultra } = .High,
    shadow_distance: f32 = 100,

    pub const VisibilityRules = struct {
        advanced_panel: void = {},
        vsync_checkbox: void = {},
        fps_slider: void = {},
        texture_dropdown: void = {},
        shadow_slider: void = {},
    };

    pub fn isVisible(self: SettingsFormState, element_id: []const u8) bool {
        // All advanced_ prefixed elements depend on show_advanced
        if (std.mem.startsWith(u8, element_id, "advanced_") or
            std.mem.eql(u8, element_id, "vsync_checkbox") or
            std.mem.eql(u8, element_id, "fps_slider") or
            std.mem.eql(u8, element_id, "texture_dropdown") or
            std.mem.eql(u8, element_id, "shadow_slider"))
        {
            return self.show_advanced;
        }
        return true;
    }
};

// ============================================================================
// Example 4: Complex Conditional Logic
// ============================================================================

/// Form with complex visibility rules based on multiple conditions
pub const ItemCraftingFormState = struct {
    item_type: enum { Weapon, Armor, Potion } = .Weapon,
    quality: enum { Common, Rare, Epic, Legendary } = .Common,
    enable_enchantments: bool = false,

    // Weapon-specific
    weapon_damage: f32 = 10,
    weapon_speed: f32 = 1.0,

    // Armor-specific
    armor_defense: f32 = 5,
    armor_weight: f32 = 10,

    // Potion-specific
    potion_duration: f32 = 60,
    potion_effect: enum { Healing, Mana, Strength } = .Healing,

    // Enchantment options (only for Rare+ quality)
    enchantment_slots: u32 = 1,
    enchantment_power: f32 = 10,

    pub const VisibilityRules = struct {
        weapon_damage_slider: void = {},
        weapon_speed_slider: void = {},
        armor_defense_slider: void = {},
        armor_weight_slider: void = {},
        potion_duration_slider: void = {},
        potion_effect_dropdown: void = {},
        enchantments_panel: void = {},
        enchantment_slots_slider: void = {},
        enchantment_power_slider: void = {},
    };

    pub fn isVisible(self: ItemCraftingFormState, element_id: []const u8) bool {
        // Weapon fields
        if (std.mem.startsWith(u8, element_id, "weapon_")) {
            return self.item_type == .Weapon;
        }

        // Armor fields
        if (std.mem.startsWith(u8, element_id, "armor_")) {
            return self.item_type == .Armor;
        }

        // Potion fields
        if (std.mem.startsWith(u8, element_id, "potion_")) {
            return self.item_type == .Potion;
        }

        // Enchantments: must be enabled AND quality must be Rare or higher
        if (std.mem.startsWith(u8, element_id, "enchant")) {
            const rare_or_higher = @intFromEnum(self.quality) >= @intFromEnum(@as(@TypeOf(self.quality), .Rare));
            return self.enable_enchantments and rare_or_higher;
        }

        return true;
    }
};

// ============================================================================
// Usage Patterns
// ============================================================================

/// Pattern 1: Update visibility in event handlers
pub fn pattern1_event_handler() void {
    // In your GUI event handlers, update visibility after field changes
    //
    // const binder = MonsterBinder.init(&monster_form);
    // if (binder.handleEvent(payload)) {
    //     // Field changed - update visibility
    //     binder.updateVisibilityWith(updateElementCallback);
    // }
}

/// Pattern 2: Batch visibility update
pub fn pattern2_batch_update() void {
    // Get a visibility map and update all elements at once
    //
    // var visibility = try binder.updateVisibility(allocator);
    // defer visibility.deinit();
    //
    // var iter = visibility.iterator();
    // while (iter.next()) |entry| {
    //     game.setElementVisible(entry.key_ptr.*, entry.value_ptr.*);
    // }
}

/// Pattern 3: On-demand visibility check
pub fn pattern3_check_visibility() void {
    // Check visibility before rendering individual elements
    //
    // if (binder.evaluateVisibility("boss_title_label")) {
    //     gui.label(.{ .text = "Boss Title:" });
    // }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Boss monster conditional visibility" {
    var form = MonsterFormState{};
    const Binder = FormBinder(MonsterFormState, "monster_form");
    const binder = Binder.init(&form);

    // Boss fields hidden initially
    try testing.expect(!binder.evaluateVisibility("boss_title_label"));
    try testing.expect(!binder.evaluateVisibility("boss_phase_slider"));

    // Enable boss mode
    form.is_boss = true;

    // Boss fields now visible
    try testing.expect(binder.evaluateVisibility("boss_title_label"));
    try testing.expect(binder.evaluateVisibility("boss_phase_slider"));

    // Regular fields always visible
    try testing.expect(binder.evaluateVisibility("name_field"));
}

test "Character wizard multi-class visibility" {
    var form = CharacterFormState{};
    const Binder = FormBinder(CharacterFormState, "char_form");
    const binder = Binder.init(&form);

    // Initially Warrior - only warrior fields visible
    try testing.expect(binder.evaluateVisibility("weapon_dropdown"));
    try testing.expect(!binder.evaluateVisibility("spell_dropdown"));
    try testing.expect(!binder.evaluateVisibility("stealth_slider"));

    // Switch to Mage
    form.class = .Mage;
    try testing.expect(!binder.evaluateVisibility("weapon_dropdown"));
    try testing.expect(binder.evaluateVisibility("spell_dropdown"));
    try testing.expect(!binder.evaluateVisibility("stealth_slider"));

    // Switch to Rogue
    form.class = .Rogue;
    try testing.expect(!binder.evaluateVisibility("weapon_dropdown"));
    try testing.expect(!binder.evaluateVisibility("spell_dropdown"));
    try testing.expect(binder.evaluateVisibility("stealth_slider"));
}

test "Item crafting complex conditions" {
    var form = ItemCraftingFormState{};
    const Binder = FormBinder(ItemCraftingFormState, "crafting_form");
    const binder = Binder.init(&form);

    // Common weapon - no enchantments
    form.item_type = .Weapon;
    form.quality = .Common;
    form.enable_enchantments = true;

    try testing.expect(binder.evaluateVisibility("weapon_damage_slider"));
    try testing.expect(!binder.evaluateVisibility("enchantments_panel")); // Too low quality

    // Rare weapon with enchantments enabled - should show
    form.quality = .Rare;
    try testing.expect(binder.evaluateVisibility("enchantments_panel"));

    // Disable enchantments - should hide even though quality is Rare
    form.enable_enchantments = false;
    try testing.expect(!binder.evaluateVisibility("enchantments_panel"));
}
