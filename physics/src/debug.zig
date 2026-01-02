//! Physics Debug Rendering
//!
//! Provides debug visualization for physics bodies and collision shapes.
//! Useful during development to see collision boundaries.

const std = @import("std");
const PhysicsWorld = @import("world.zig").PhysicsWorld;
const components = @import("components.zig");

/// Debug draw configuration
pub const DebugDrawConfig = struct {
    /// Draw collision shapes
    draw_shapes: bool = true,
    /// Draw shape outlines only (vs filled)
    draw_wireframe: bool = true,
    /// Draw center of mass
    draw_center_of_mass: bool = false,
    /// Draw velocity vectors
    draw_velocities: bool = false,
    /// Draw AABB bounding boxes
    draw_aabbs: bool = false,
    /// Draw contact points
    draw_contacts: bool = true,
    /// Draw sensors
    draw_sensors: bool = true,

    // Colors (RGBA)
    static_color: [4]u8 = .{ 100, 100, 100, 200 },
    kinematic_color: [4]u8 = .{ 100, 100, 200, 200 },
    dynamic_color: [4]u8 = .{ 100, 200, 100, 200 },
    sensor_color: [4]u8 = .{ 200, 200, 100, 150 },
    contact_color: [4]u8 = .{ 255, 0, 0, 255 },
    velocity_color: [4]u8 = .{ 0, 100, 255, 255 },
};

/// Debug draw interface
///
/// Implement this interface to render debug shapes with your graphics backend.
pub const DebugDrawInterface = struct {
    /// Draw a filled circle
    drawCircleFn: *const fn (ctx: *anyopaque, center: [2]f32, radius: f32, color: [4]u8) void,
    /// Draw a circle outline
    drawCircleOutlineFn: *const fn (ctx: *anyopaque, center: [2]f32, radius: f32, color: [4]u8) void,
    /// Draw a filled polygon
    drawPolygonFn: *const fn (ctx: *anyopaque, vertices: [][2]f32, color: [4]u8) void,
    /// Draw a polygon outline
    drawPolygonOutlineFn: *const fn (ctx: *anyopaque, vertices: [][2]f32, color: [4]u8) void,
    /// Draw a line segment
    drawLineFn: *const fn (ctx: *anyopaque, start: [2]f32, end: [2]f32, color: [4]u8) void,
    /// Draw a point
    drawPointFn: *const fn (ctx: *anyopaque, point: [2]f32, size: f32, color: [4]u8) void,
    /// Context pointer passed to all draw functions
    ctx: *anyopaque,

    pub fn drawCircle(self: *const DebugDrawInterface, center: [2]f32, radius: f32, color: [4]u8) void {
        self.drawCircleFn(self.ctx, center, radius, color);
    }

    pub fn drawCircleOutline(self: *const DebugDrawInterface, center: [2]f32, radius: f32, color: [4]u8) void {
        self.drawCircleOutlineFn(self.ctx, center, radius, color);
    }

    pub fn drawPolygon(self: *const DebugDrawInterface, vertices: [][2]f32, color: [4]u8) void {
        self.drawPolygonFn(self.ctx, vertices, color);
    }

    pub fn drawPolygonOutline(self: *const DebugDrawInterface, vertices: [][2]f32, color: [4]u8) void {
        self.drawPolygonOutlineFn(self.ctx, vertices, color);
    }

    pub fn drawLine(self: *const DebugDrawInterface, start: [2]f32, end: [2]f32, color: [4]u8) void {
        self.drawLineFn(self.ctx, start, end, color);
    }

    pub fn drawPoint(self: *const DebugDrawInterface, point: [2]f32, size: f32, color: [4]u8) void {
        self.drawPointFn(self.ctx, point, size, color);
    }
};

/// Draw physics debug visualization
pub fn draw(
    world: *PhysicsWorld,
    registry: anytype,
    draw_interface: *const DebugDrawInterface,
    config: DebugDrawConfig,
) void {
    if (config.draw_shapes) {
        drawShapes(world, registry, draw_interface, config);
    }

    if (config.draw_velocities) {
        drawVelocities(world, registry, draw_interface, config);
    }

    if (config.draw_contacts) {
        drawContacts(world, draw_interface, config);
    }
}

fn drawShapes(
    world: *PhysicsWorld,
    registry: anytype,
    draw_interface: *const DebugDrawInterface,
    config: DebugDrawConfig,
) void {
    const Position = @TypeOf(registry).Position;

    var query = registry.query(.{ components.RigidBody, components.Collider, Position });
    while (query.next()) |item| {
        const rb = item.get(components.RigidBody);
        const collider = item.get(components.Collider);
        const pos = item.get(Position);

        // Choose color based on body type and sensor state
        const color = if (collider.is_sensor)
            config.sensor_color
        else switch (rb.body_type) {
            .static => config.static_color,
            .kinematic => config.kinematic_color,
            .dynamic => config.dynamic_color,
        };

        // Get actual physics position if available
        const entity = entityToU64(item.entity);
        const draw_pos = if (world.getPosition(entity)) |p| p else .{ pos.x, pos.y };

        drawShape(draw_interface, collider.shape, draw_pos, collider.offset, color, config.draw_wireframe, world.pixels_per_meter);
    }
}

fn drawShape(
    draw_interface: *const DebugDrawInterface,
    shape: components.Shape,
    position: [2]f32,
    offset: [2]f32,
    color: [4]u8,
    wireframe: bool,
    _: f32,
) void {
    const center: [2]f32 = .{
        position[0] + offset[0],
        position[1] + offset[1],
    };

    switch (shape) {
        .box => |box| {
            const hw = box.width / 2;
            const hh = box.height / 2;
            var vertices = [_][2]f32{
                .{ center[0] - hw, center[1] - hh },
                .{ center[0] + hw, center[1] - hh },
                .{ center[0] + hw, center[1] + hh },
                .{ center[0] - hw, center[1] + hh },
            };
            if (wireframe) {
                draw_interface.drawPolygonOutline(&vertices, color);
            } else {
                draw_interface.drawPolygon(&vertices, color);
            }
        },
        .circle => |circle| {
            if (wireframe) {
                draw_interface.drawCircleOutline(center, circle.radius, color);
            } else {
                draw_interface.drawCircle(center, circle.radius, color);
            }
        },
        .edge => |edge| {
            draw_interface.drawLine(
                .{ center[0] + edge.start[0], center[1] + edge.start[1] },
                .{ center[0] + edge.end[0], center[1] + edge.end[1] },
                color,
            );
        },
        .polygon => |poly| {
            if (poly.vertices.len < 3) return;

            // Transform vertices to world space
            var transformed: [8][2]f32 = undefined;
            const count = @min(poly.vertices.len, 8);
            for (0..count) |i| {
                transformed[i] = .{
                    center[0] + poly.vertices[i][0],
                    center[1] + poly.vertices[i][1],
                };
            }

            if (wireframe) {
                draw_interface.drawPolygonOutline(transformed[0..count], color);
            } else {
                draw_interface.drawPolygon(transformed[0..count], color);
            }
        },
        .chain => {
            // TODO: Draw chain shapes
        },
    }
}

fn drawVelocities(
    world: *PhysicsWorld,
    registry: anytype,
    draw_interface: *const DebugDrawInterface,
    config: DebugDrawConfig,
) void {
    const Position = @TypeOf(registry).Position;

    var query = registry.query(.{ components.RigidBody, Position });
    while (query.next()) |item| {
        const entity = entityToU64(item.entity);
        const pos = world.getPosition(entity) orelse continue;
        const vel = world.getLinearVelocity(entity) orelse continue;

        // Scale velocity for visualization
        const scale: f32 = 0.1;
        const end: [2]f32 = .{
            pos[0] + vel[0] * scale,
            pos[1] + vel[1] * scale,
        };

        draw_interface.drawLine(pos, end, config.velocity_color);
    }
}

fn drawContacts(
    world: *PhysicsWorld,
    draw_interface: *const DebugDrawInterface,
    config: DebugDrawConfig,
) void {
    // Draw collision contact points
    for (world.getCollisionBeginEvents()) |event| {
        draw_interface.drawPoint(event.contact_point, 5, config.contact_color);

        // Draw normal
        const normal_end: [2]f32 = .{
            event.contact_point[0] + event.normal[0] * 10,
            event.contact_point[1] + event.normal[1] * 10,
        };
        draw_interface.drawLine(event.contact_point, normal_end, config.contact_color);
    }
}

fn entityToU64(entity: anytype) u64 {
    const T = @TypeOf(entity);
    if (@hasField(T, "id")) {
        return @intCast(entity.id);
    } else if (@typeInfo(T) == .int) {
        return @intCast(entity);
    } else {
        return @bitCast(entity);
    }
}
