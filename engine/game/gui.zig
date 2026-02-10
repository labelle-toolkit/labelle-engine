// GUI rendering — view rendering, visibility state, value state overrides.
//
// This is a zero-bit field mixin for GameWith(Hooks). Methods access the parent
// Game struct via @fieldParentPtr("gui_rendering", self).

const std = @import("std");
const gui_mod = @import("gui");

pub fn GuiMixin(comptime GameType: type) type {
    return struct {
        const Self = @This();

        fn game(self: *Self) *GameType {
            return @alignCast(@fieldParentPtr("gui_rendering", self));
        }

        fn gameConst(self: *const Self) *const GameType {
            return @alignCast(@fieldParentPtr("gui_rendering", self));
        }

        /// Enable or disable GUI rendering.
        pub fn setEnabled(self: *Self, enabled: bool) void {
            const g = self.game();
            g.gui_enabled = enabled;
        }

        /// Check if GUI is currently enabled.
        pub fn isEnabled(self: *const Self) bool {
            const g = self.gameConst();
            return g.gui_enabled;
        }

        /// Render GUI from a ViewRegistry.
        /// Call this after re.render() in your main loop:
        /// ```zig
        /// re.beginFrame();
        /// re.render();
        /// game.gui_rendering.renderGui(Views, Scripts, view_names);
        /// re.endFrame();
        /// ```
        pub fn renderGui(self: *Self, comptime Views: type, comptime Scripts: type, comptime view_names: []const []const u8) void {
            const g = self.game();
            if (!g.gui_enabled) return;

            g.gui.beginFrame();

            inline for (view_names) |view_name| {
                if (Views.has(view_name)) {
                    const view_def = Views.get(view_name);
                    self.renderGuiElements(g, view_def.elements, Scripts);
                }
            }

            g.gui.endFrame();
        }

        /// Render a single GUI view by name.
        pub fn renderGuiView(self: *Self, comptime Views: type, comptime Scripts: type, comptime view_name: []const u8) void {
            const g = self.game();
            if (!g.gui_enabled) return;
            if (!Views.has(view_name)) return;

            g.gui.beginFrame();
            const view_def = Views.get(view_name);
            self.renderGuiElements(g, view_def.elements, Scripts);
            g.gui.endFrame();
        }

        /// Internal: Render a list of GUI elements.
        fn renderGuiElements(self: *Self, g: *GameType, elements: []const gui_mod.GuiElement, comptime Scripts: type) void {
            for (elements) |element| {
                self.renderGuiElement(g, element, Scripts);
            }
        }

        /// Internal: Render a single GUI element.
        fn renderGuiElement(self: *Self, g: *GameType, element: gui_mod.GuiElement, comptime Scripts: type) void {
            // Check element visibility before rendering
            if (!element.isVisible()) return;

            switch (element) {
                .Label => |lbl| g.gui.label(lbl),
                .Button => |btn| {
                    if (g.gui.button(btn)) {
                        // Button was clicked - call script callback if defined
                        if (btn.on_click) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .ProgressBar => |bar| g.gui.progressBar(bar),
                .Panel => |panel| {
                    g.gui.beginPanel(panel);
                    self.renderGuiElements(g, panel.children, Scripts);
                    g.gui.endPanel();
                },
                .Image => |img| g.gui.image(img),
                .Checkbox => |cb| {
                    if (g.gui.checkbox(cb)) {
                        // Checkbox was toggled - call script callback if defined
                        if (cb.on_change) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .Slider => |sl| {
                    const new_value = g.gui.slider(sl);
                    if (new_value != sl.value) {
                        // Slider value changed - call script callback if defined
                        if (sl.on_change) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
            }
        }

        /// Internal: Invoke a GUI callback by name from the Scripts registry.
        fn invokeGuiCallback(comptime Scripts: type, callback_name: []const u8) void {
            // Scripts registry is comptime, so we can't dynamically lookup by runtime string.
            // For now, callbacks are just logged. A full implementation would require
            // a different approach (e.g., callback function pointers in elements).
            _ = Scripts;
            std.log.debug("GUI callback: {s}", .{callback_name});
        }

        /// Render GUI views associated with a scene.
        ///
        /// Renders all views specified in the scene's .gui_views field.
        /// Call this after re.render() in your main loop:
        /// ```zig
        /// re.beginFrame();
        /// re.render();
        /// game.gui_rendering.renderSceneGui(&scene, Views, Scripts);
        /// re.endFrame();
        /// ```
        pub fn renderSceneGui(self: *Self, scene: anytype, comptime Views: type, comptime Scripts: type) void {
            const g = self.game();
            if (!g.gui_enabled) return;

            // Check if scene has gui_view_names field
            const SceneType = @TypeOf(scene.*);
            if (!@hasField(SceneType, "gui_view_names")) return;

            const view_names = scene.gui_view_names;
            if (view_names.len == 0) return;

            g.gui.beginFrame();

            // For each view name in the scene, check if it exists in Views registry
            for (view_names) |active_name| {
                self.renderViewByName(g, Views, Scripts, active_name);
            }

            g.gui.endFrame();
        }

        /// Internal: Render a view by runtime name using comptime Views lookup.
        fn renderViewByName(self: *Self, g: *GameType, comptime Views: type, comptime Scripts: type, name: []const u8) void {
            // Use comptime iteration over Views to match the runtime name
            inline for (comptime Views.names()) |view_name| {
                if (std.mem.eql(u8, view_name, name)) {
                    const view_def = Views.get(view_name);
                    self.renderGuiElements(g, view_def.elements, Scripts);
                    return;
                }
            }
        }

        /// Render GUI views associated with a scene, with runtime visibility overrides.
        ///
        /// Same as renderSceneGui but allows dynamic element visibility control.
        pub fn renderSceneGuiWithVisibility(
            self: *Self,
            scene: anytype,
            comptime Views: type,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
        ) void {
            const g = self.game();
            if (!g.gui_enabled) return;

            // Check if scene has gui_view_names field
            const SceneType = @TypeOf(scene.*);
            if (!@hasField(SceneType, "gui_view_names")) return;

            const view_names = scene.gui_view_names;
            if (view_names.len == 0) return;

            g.gui.beginFrame();

            // For each view name in the scene, check if it exists in Views registry
            for (view_names) |active_name| {
                self.renderViewByNameWithVisibility(g, Views, Scripts, active_name, visibility_state);
            }

            g.gui.endFrame();
        }

        /// Internal: Render a view by runtime name with visibility overrides.
        fn renderViewByNameWithVisibility(
            self: *Self,
            g: *GameType,
            comptime Views: type,
            comptime Scripts: type,
            name: []const u8,
            visibility_state: *const gui_mod.VisibilityState,
        ) void {
            // Use comptime iteration over Views to match the runtime name
            inline for (comptime Views.names()) |view_name| {
                if (std.mem.eql(u8, view_name, name)) {
                    const view_def = Views.get(view_name);
                    self.renderGuiElementsWithVisibility(g, view_def.elements, Scripts, visibility_state);
                    return;
                }
            }
        }

        /// Internal: Render GUI elements with visibility overrides.
        fn renderGuiElementsWithVisibility(
            self: *Self,
            g: *GameType,
            elements: []const gui_mod.GuiElement,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
        ) void {
            for (elements) |element| {
                self.renderGuiElementWithVisibility(g, element, Scripts, visibility_state);
            }
        }

        /// Internal: Render a single GUI element with visibility override.
        fn renderGuiElementWithVisibility(
            self: *Self,
            g: *GameType,
            element: gui_mod.GuiElement,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
        ) void {
            // Check visibility: use override if element has an ID, otherwise use default
            const element_id = element.getId();
            const is_visible = if (element_id.len > 0)
                visibility_state.isVisible(element_id, element.isVisible())
            else
                element.isVisible();

            if (!is_visible) return;

            switch (element) {
                .Label => |lbl| g.gui.label(lbl),
                .Button => |btn| {
                    if (g.gui.button(btn)) {
                        if (btn.on_click) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .ProgressBar => |bar| g.gui.progressBar(bar),
                .Panel => |panel| {
                    g.gui.beginPanel(panel);
                    self.renderGuiElementsWithVisibility(g, panel.children, Scripts, visibility_state);
                    g.gui.endPanel();
                },
                .Image => |img| g.gui.image(img),
                .Checkbox => |cb| {
                    if (g.gui.checkbox(cb)) {
                        if (cb.on_change) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .Slider => |sl| {
                    const new_value = g.gui.slider(sl);
                    if (new_value != sl.value) {
                        if (sl.on_change) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
            }
        }

        /// Render GUI views with both visibility and value state overrides.
        ///
        /// Allows full runtime control over element visibility AND values (checkboxes, sliders).
        /// Updates value_state when user interacts with elements.
        pub fn renderSceneGuiWithState(
            self: *Self,
            scene: anytype,
            comptime Views: type,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
            value_state: *gui_mod.ValueState,
        ) void {
            const g = self.game();
            if (!g.gui_enabled) return;

            const SceneType = @TypeOf(scene.*);
            if (!@hasField(SceneType, "gui_view_names")) return;

            const view_names = scene.gui_view_names;
            if (view_names.len == 0) return;

            g.gui.beginFrame();

            for (view_names) |active_name| {
                self.renderViewByNameWithState(g, Views, Scripts, active_name, visibility_state, value_state);
            }

            g.gui.endFrame();
        }

        /// Internal: Render view with full state overrides.
        fn renderViewByNameWithState(
            self: *Self,
            g: *GameType,
            comptime Views: type,
            comptime Scripts: type,
            name: []const u8,
            visibility_state: *const gui_mod.VisibilityState,
            value_state: *gui_mod.ValueState,
        ) void {
            inline for (comptime Views.names()) |view_name| {
                if (std.mem.eql(u8, view_name, name)) {
                    const view_def = Views.get(view_name);
                    self.renderGuiElementsWithState(g, view_def.elements, Scripts, visibility_state, value_state);
                    return;
                }
            }
        }

        /// Internal: Render elements with full state overrides.
        fn renderGuiElementsWithState(
            self: *Self,
            g: *GameType,
            elements: []const gui_mod.GuiElement,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
            value_state: *gui_mod.ValueState,
        ) void {
            for (elements) |element| {
                self.renderGuiElementWithState(g, element, Scripts, visibility_state, value_state);
            }
        }

        /// Internal: Render single element with full state overrides.
        /// Updates value_state when user interacts with elements.
        fn renderGuiElementWithState(
            self: *Self,
            g: *GameType,
            element: gui_mod.GuiElement,
            comptime Scripts: type,
            visibility_state: *const gui_mod.VisibilityState,
            value_state: *gui_mod.ValueState,
        ) void {
            const element_id = element.getId();
            const is_visible = if (element_id.len > 0)
                visibility_state.isVisible(element_id, element.isVisible())
            else
                element.isVisible();

            if (!is_visible) return;

            switch (element) {
                .Label => |lbl| g.gui.label(lbl),
                .Button => |btn| {
                    if (g.gui.button(btn)) {
                        if (btn.on_click) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .ProgressBar => |bar| g.gui.progressBar(bar),
                .Panel => |panel| {
                    g.gui.beginPanel(panel);
                    self.renderGuiElementsWithState(g, panel.children, Scripts, visibility_state, value_state);
                    g.gui.endPanel();
                },
                .Image => |img| g.gui.image(img),
                .Checkbox => |cb| {
                    // Apply value state override
                    var modified_cb = cb;
                    if (element_id.len > 0) {
                        modified_cb.checked = value_state.getCheckbox(element_id, cb.checked);
                    }

                    if (g.gui.checkbox(modified_cb)) {
                        // User toggled checkbox - update value state
                        if (element_id.len > 0) {
                            const new_value = !modified_cb.checked;
                            value_state.setCheckbox(element_id, new_value) catch |err| {
                                std.log.warn("Failed to set checkbox state for '{s}': {}", .{ element_id, err });
                            };
                        }

                        // Invoke callback if defined
                        if (cb.on_change) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
                .Slider => |sl| {
                    // Apply value state override
                    var modified_sl = sl;
                    if (element_id.len > 0) {
                        modified_sl.value = value_state.getSlider(element_id, sl.value);
                    }

                    const new_value = g.gui.slider(modified_sl);
                    if (new_value != modified_sl.value) {
                        // User changed slider - update value state
                        if (element_id.len > 0) {
                            value_state.setSlider(element_id, new_value) catch |err| {
                                std.log.warn("Failed to set slider state for '{s}': {}", .{ element_id, err });
                            };
                        }

                        // Invoke callback if defined
                        if (sl.on_change) |callback_name| {
                            invokeGuiCallback(Scripts, callback_name);
                        }
                    }
                },
            }
        }
    };
}
