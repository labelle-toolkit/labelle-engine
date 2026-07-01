/// Visuals mixin — sprite, shape, text, icon, and gizmo management + z-index.
const core = @import("labelle-core");
const Position = core.Position;

/// Returns the visual management mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;
    const Sprite = Game.SpriteComp;
    const Shape = Game.ShapeComp;
    const Text = Game.TextComp;
    const Icon = Game.IconComp;
    const Gizmo = core.GizmoComponent(Entity);

    return struct {
        pub fn addSprite(self: *Game, entity: Entity, sprite: Sprite) void {
            self.ecs_backend.addComponent(entity, sprite);
            self.bumpRoster(); // membership changed (#653)
            self.renderer.trackEntity(entity, .sprite);
        }

        pub fn addShape(self: *Game, entity: Entity, shape: Shape) void {
            self.ecs_backend.addComponent(entity, shape);
            self.bumpRoster(); // membership changed (#653)
            self.renderer.trackEntity(entity, .shape);
        }

        pub fn addText(self: *Game, entity: Entity, text: Text) void {
            self.ecs_backend.addComponent(entity, text);
            self.bumpRoster(); // membership changed (#653)
            self.renderer.trackEntity(entity, .text);
        }

        pub fn addIcon(self: *Game, entity: Entity, icon: Icon) void {
            self.ecs_backend.addComponent(entity, icon);
            self.bumpRoster(); // membership changed (#653)
            self.renderer.trackEntity(entity, .sprite);
        }

        /// Create a gizmo entity attached to a parent. The gizmo follows
        /// the parent's position automatically via GizmoComponent.
        pub fn addGizmo(self: *Game, parent: Entity, shape: Shape, offset_x: f32, offset_y: f32) Entity {
            self.assertEntityAlive(parent, "addGizmo (parent)");
            const gizmo_entity = self.createEntity();
            const parent_pos = self.getPosition(parent);

            self.ecs_backend.addComponent(gizmo_entity, Gizmo{
                .parent_entity = parent,
                .offset_x = offset_x,
                .offset_y = offset_y,
            });
            self.bumpRoster(); // Gizmo membership changed (#653)
            self.setPosition(gizmo_entity, .{
                .x = parent_pos.x + offset_x,
                .y = parent_pos.y + offset_y,
            });
            self.addShape(gizmo_entity, shape);

            return gizmo_entity;
        }

        pub fn removeSprite(self: *Game, entity: Entity) void {
            self.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Sprite);
            self.bumpRoster(); // membership changed (#653)
        }

        pub fn removeShape(self: *Game, entity: Entity) void {
            self.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Shape);
            self.bumpRoster(); // membership changed (#653)
        }

        pub fn removeText(self: *Game, entity: Entity) void {
            self.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Text);
            self.bumpRoster(); // membership changed (#653)
        }

        pub fn setZIndex(self: *Game, entity: Entity, z_index: i16) void {
            self.assertEntityAlive(entity, "setZIndex");
            var updated = false;
            if (self.ecs_backend.getComponent(entity, Sprite)) |sprite| {
                sprite.z_index = z_index;
                updated = true;
            }
            if (self.ecs_backend.getComponent(entity, Shape)) |shape| {
                shape.z_index = z_index;
                updated = true;
            }
            if (Text != void) {
                if (self.ecs_backend.getComponent(entity, Text)) |text| {
                    text.z_index = z_index;
                    updated = true;
                }
            }
            if (updated) {
                self.renderer.markVisualDirty(entity);
            }
        }

        /// Set the sprite's horizontal flip and mark the entity's visuals
        /// dirty so the renderer picks up the change on the next sync.
        ///
        /// Bundles the `sprite.flip_x = X` + `renderer.markVisualDirty(entity)`
        /// pair that callers previously had to write by hand — forgetting the
        /// dirty-mark was a silent bug (visual stayed stale).
        ///
        /// Returns silently if the entity has no `Sprite` component — callers
        /// that need to assert presence should `getComponent` themselves first.
        /// Short-circuits when the flip value already matches, avoiding a
        /// wasted dirty-mark.
        ///
        /// Comptime no-op on backends whose `Sprite` doesn't carry a `flip_x`
        /// field (`StubRender`, mock renderers in downstream tests). Keeps the
        /// helper safe to call uniformly across renderers without a wrapper.
        pub fn setSpriteFlip(self: *Game, entity: Entity, flip_x: bool) void {
            if (comptime !@hasField(Sprite, "flip_x")) return;
            self.assertEntityAlive(entity, "setSpriteFlip");
            const sprite = self.ecs_backend.getComponent(entity, Sprite) orelse return;
            if (sprite.flip_x == flip_x) return;
            sprite.flip_x = flip_x;
            self.renderer.markVisualDirty(entity);
        }
    };
}
