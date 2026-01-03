const std = @import("std");
const engine = @import("labelle-engine");
const ecs = @import("ecs");

const Entity = engine.Entity;

/// Storage component demonstrates parent reference convention (RFC #169).
/// When this component is created as a nested entity inside a Workstation component,
/// the engine automatically populates the `workstation` field with the parent entity.
pub const Storage = struct {
    /// Storage role: internal input/output or external input/output
    role: Role = .ios,

    /// Parent reference - automatically populated when nested inside Workstation.
    /// Convention: field name matches parent component type (lowercased).
    /// Default value will be overwritten by the loader.
    workstation: Entity = if (@hasDecl(Entity, "invalid")) Entity.invalid else @bitCast(@as(ecs.EntityBits, 0)),

    pub const Role = enum {
        eis, // External Input Storage (from outside world)
        iis, // Internal Input Storage (feeds into workstation)
        ios, // Internal Output Storage (workstation produces here)
        eos, // External Output Storage (to outside world)
    };

    /// onReady is called AFTER the entire entity hierarchy is complete.
    /// At this point:
    /// - `workstation` field IS populated with parent entity
    /// - All sibling Storage entities exist
    /// - Parent Workstation.storages array is fully populated
    pub fn onReady(payload: engine.ComponentPayload) void {
        _ = payload;
        std.log.info("[Storage.onReady] Storage is ready! Parent workstation is set.", .{});

        // Example: You could access the parent workstation here
        // const game = payload.getGame(main.Game);
        // if (game.tryGet(main.Workstation, storage.workstation)) |ws| {
        //     std.log.info("This storage belongs to workstation with {} storages", .{ws.storages.len});
        // }
    }

    /// onAdd is called immediately when the component is added.
    /// The parent reference IS set at this point, but the parent's entity list
    /// may not be fully populated yet (siblings may not all exist).
    pub fn onAdd(payload: engine.ComponentPayload) void {
        _ = payload;
        std.log.info("[Storage.onAdd] Storage component added.", .{});
    }
};
