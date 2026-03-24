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
            self.active_world.renderer.trackEntity(entity, .sprite);
        }

        pub fn addShape(self: *Game, entity: Entity, shape: Shape) void {
            self.ecs_backend.addComponent(entity, shape);
            self.active_world.renderer.trackEntity(entity, .shape);
        }

        pub fn addText(self: *Game, entity: Entity, text: Text) void {
            self.ecs_backend.addComponent(entity, text);
            self.active_world.renderer.trackEntity(entity, .text);
        }

        pub fn addIcon(self: *Game, entity: Entity, icon: Icon) void {
            self.ecs_backend.addComponent(entity, icon);
            self.active_world.renderer.trackEntity(entity, .sprite);
        }

        /// Create a gizmo entity attached to a parent. The gizmo follows
        /// the parent's position automatically via GizmoComponent.
        pub fn addGizmo(self: *Game, parent: Entity, shape: Shape, offset_x: f32, offset_y: f32) Entity {
            const gizmo_entity = self.createEntity();
            const parent_pos = self.getPosition(parent);

            self.ecs_backend.addComponent(gizmo_entity, Gizmo{
                .parent_entity = parent,
                .offset_x = offset_x,
                .offset_y = offset_y,
            });
            self.setPosition(gizmo_entity, .{
                .x = parent_pos.x + offset_x,
                .y = parent_pos.y + offset_y,
            });
            self.addShape(gizmo_entity, shape);

            return gizmo_entity;
        }

        pub fn removeSprite(self: *Game, entity: Entity) void {
            self.active_world.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Sprite);
        }

        pub fn removeShape(self: *Game, entity: Entity) void {
            self.active_world.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Shape);
        }

        pub fn removeText(self: *Game, entity: Entity) void {
            self.active_world.renderer.untrackEntity(entity);
            self.ecs_backend.removeComponent(entity, Text);
        }

        pub fn setZIndex(self: *Game, entity: Entity, z_index: i16) void {
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
                self.active_world.renderer.markVisualDirty(entity);
            }
        }
    };
}
