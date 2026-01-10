const std = @import("std");
const labelle = @import("labelle-engine");

// Import GUI view definitions
const Views = labelle.ViewRegistry(.{
    .monster_form = @import("gui/monster_form.zon"),
});

// Form state struct for monster creation
const MonsterFormState = struct {
    health: f32 = 100,
    attack: f32 = 10,
    defense: f32 = 5,
    is_boss: bool = false,
    boss_phase_count: u8 = 1,
    enrage_threshold: f32 = 0.3,

    // Visibility rules for conditional fields
    pub const VisibilityRules = struct {
        boss_phase_label: void = {},
        @"monster_form.boss_phase_count": void = {},
        phase_value: void = {},
        enrage_label: void = {},
        @"monster_form.enrage_threshold": void = {},
        enrage_value: void = {},
    };

    // Determine visibility based on is_boss field
    pub fn isVisible(self: @This(), element_id: []const u8) bool {
        // Boss-only fields
        if (std.mem.eql(u8, element_id, "boss_phase_label") or
            std.mem.eql(u8, element_id, "monster_form.boss_phase_count") or
            std.mem.eql(u8, element_id, "phase_value") or
            std.mem.eql(u8, element_id, "enrage_label") or
            std.mem.eql(u8, element_id, "monster_form.enrage_threshold") or
            std.mem.eql(u8, element_id, "enrage_value"))
        {
            return self.is_boss;
        }
        return true;
    }
};

// FormBinder for automatic form state management
const MonsterBinder = labelle.FormBinder(MonsterFormState, "monster_form");

// Script callbacks for GUI buttons
const Scripts = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
};

// Minimal components and prefabs for scene loading
const Components = labelle.ComponentRegistry(struct {
    pub const Position = labelle.Position;
});

const Prefabs = labelle.PrefabRegistry(.{});

const Loader = labelle.SceneLoader(Prefabs, Components, Scripts);

pub fn main() !void {
    const ci_test = std.posix.getenv("CI_TEST") != null;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var game = try labelle.Game.init(allocator, .{
        .window = .{
            .width = 700,
            .height = 560,
            .title = "Conditional Form Example - FormBinder Demo",
            .hidden = ci_test,
        },
        .clear_color = .{ .r = 30, .g = 30, .b = 40 },
    });
    game.fixPointers();
    defer game.deinit();

    // Load scene with GUI views
    var scene = try Loader.load(@import("scenes/main.zon"), labelle.SceneContext.init(&game));
    defer scene.deinit();

    // Initialize form state and binder
    var form_state = MonsterFormState{};
    const binder = MonsterBinder.init(&form_state);

    // Initialize visibility state for conditional rendering
    var visibility_state = labelle.VisibilityState.init(allocator);
    defer visibility_state.deinit();

    // Initialize value state for runtime value updates
    var value_state = labelle.ValueState.init(allocator);
    defer value_state.deinit();

    if (ci_test) return;

    while (game.isRunning()) {
        const re = game.getRetainedEngine();
        re.beginFrame();
        re.render();

        // Update visibility based on form state (is_boss toggle)
        var visibility = try binder.updateVisibility(allocator);
        defer visibility.deinit();

        // Apply visibility to runtime state
        var iter = visibility.iterator();
        while (iter.next()) |entry| {
            visibility_state.setVisible(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }

        // Update value labels to reflect current slider values
        var buf: [32]u8 = undefined;
        const health_str = std.fmt.bufPrintZ(&buf, "{d:.0}", .{form_state.health}) catch "?";
        value_state.setText("health_value", health_str) catch {};

        const attack_str = std.fmt.bufPrintZ(&buf, "{d:.0}", .{form_state.attack}) catch "?";
        value_state.setText("attack_value", attack_str) catch {};

        const defense_str = std.fmt.bufPrintZ(&buf, "{d:.0}", .{form_state.defense}) catch "?";
        value_state.setText("defense_value", defense_str) catch {};

        const phase_str = std.fmt.bufPrintZ(&buf, "{d}", .{form_state.boss_phase_count}) catch "?";
        value_state.setText("phase_value", phase_str) catch {};

        const enrage_str = std.fmt.bufPrintZ(&buf, "{d:.0}%", .{form_state.enrage_threshold * 100}) catch "?";
        value_state.setText("enrage_value", enrage_str) catch {};

        // Render GUI with visibility and value state
        game.renderSceneGuiWithState(&scene, Views, Scripts, &visibility_state, &value_state);

        re.endFrame();
    }
}
