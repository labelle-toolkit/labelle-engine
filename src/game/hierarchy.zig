/// Hierarchy — parent-child relationships, world position, cycle detection.
const core = @import("labelle-core");
const Position = core.Position;

/// Compute world position by walking parent chain (x/y only, no rotation/scale).
pub fn computeWorldPos(
    comptime EcsImpl: type,
    comptime Parent: type,
    ecs: *EcsImpl,
    entity: EcsImpl.Entity,
    depth: u8,
) Position {
    if (depth > 32) return Position{};
    const local = if (ecs.getComponent(entity, Position)) |p| p.* else Position{};
    if (ecs.getComponent(entity, Parent)) |parent_comp| {
        const parent_pos = computeWorldPos(EcsImpl, Parent, ecs, parent_comp.entity, depth + 1);
        return .{ .x = parent_pos.x + local.x, .y = parent_pos.y + local.y };
    }
    return local;
}

/// Check if setting child's parent to parent_entity would create a cycle.
pub fn wouldCreateCycle(
    comptime EcsImpl: type,
    comptime Parent: type,
    ecs: *EcsImpl,
    child: EcsImpl.Entity,
    parent_entity: EcsImpl.Entity,
) bool {
    var current = parent_entity;
    var depth: u8 = 0;
    while (depth < 33) : (depth += 1) {
        if (current == child) return true;
        if (ecs.getComponent(current, Parent)) |p| {
            current = p.entity;
        } else {
            return false;
        }
    }
    return true; // exceeded depth limit, treat as cycle
}
