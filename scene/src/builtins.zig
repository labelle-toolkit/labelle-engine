//! Built-in scene components — the ONE source of truth (#881).
//!
//! A *built-in* is a component the engine itself owns: it is never
//! registered in a project's `ComponentRegistry`, so
//! `Components.has(name)` is `false` for it and every registry-driven
//! dispatch chain walks straight past it. Before this module each
//! dispatch site carried its own hand-written chain of name
//! comparisons, and a built-in missing from one of them was **silently
//! dropped** — the entity spawned, the component simply never existed
//! (`Camera` / `Image` / `Emitter` in the comptime `.zon` writer;
//! `Emitter` in the live prefab refresh).
//!
//! Every dispatch site now derives its set of built-ins from `Builtin`
//! below, and the sites that need a per-built-in branch pin that
//! requirement to an EXHAUSTIVE switch over this enum. Adding a tag
//! here therefore makes every such site fail to COMPILE until it is
//! handled — the trap is closed by construction rather than by
//! remembering.
//!
//! ## Shadowing
//!
//! `Sprite` / `Shape` are unconditional: they win over a same-named
//! registry entry everywhere (loader, script contract, refresh).
//! `Tilemap` / `Camera` / `Image` / `Emitter` are *shadowable* — a
//! project that registers its own component of that name takes
//! precedence and the built-in branch compiles out, mirroring the
//! `!Components.has(…)` gates in `jsonc/component_apply.zig` and
//! `game.zig`'s `camera_is_builtin` / `emitter_is_builtin`.

const std = @import("std");

/// The engine's built-in scene components. Each tag's component type
/// lives on the concrete Game type under `<tag>Comp`
/// (`SpriteComp`, `CameraComp`, …) — see `Type`.
pub const Builtin = enum {
    Sprite,
    Shape,
    Tilemap,
    Camera,
    Image,
    Emitter,

    /// `true` when a project-registered component of the same name
    /// takes precedence over the built-in.
    pub fn shadowable(comptime self: Builtin) bool {
        return switch (self) {
            .Sprite, .Shape => false,
            .Tilemap, .Camera, .Image, .Emitter => true,
        };
    }

    /// Name of the `GameType` decl carrying this built-in's type.
    pub fn compDecl(comptime self: Builtin) []const u8 {
        return @tagName(self) ++ "Comp";
    }

    /// This built-in's component type on a concrete Game type.
    /// Compile error (naming the built-in) when the Game exposes no
    /// such decl — loud beats silent.
    pub fn Type(comptime self: Builtin, comptime GameType: type) type {
        const decl = self.compDecl();
        if (!@hasDecl(GameType, decl)) {
            @compileError("built-in component '" ++ @tagName(self) ++ "' has no `" ++ decl ++
                "` decl on " ++ @typeName(GameType) ++
                " — the engine built-in is unavailable on this Game type");
        }
        return @field(GameType, decl);
    }
};

/// The built-in matching `name`, or `null` when `name` is not a
/// built-in at all (a project-registered component, `Position`, …).
pub fn lookup(comptime name: []const u8) ?Builtin {
    return std.meta.stringToEnum(Builtin, name);
}

/// `true` when `name` names an engine built-in.
pub fn has(comptime name: []const u8) bool {
    return lookup(name) != null;
}

/// Every built-in name, in declaration order.
pub const names: []const []const u8 = blk: {
    const tags = std.enums.values(Builtin);
    var out: [tags.len][]const u8 = undefined;
    for (tags, 0..) |t, i| out[i] = @tagName(t);
    const frozen = out;
    break :blk &frozen;
};

test "every built-in name round-trips through lookup" {
    inline for (names) |n| {
        try std.testing.expect(has(n));
        try std.testing.expectEqualStrings(n, @tagName(comptime lookup(n).?));
    }
    try std.testing.expect(!has("Position"));
    try std.testing.expect(comptime lookup("Health") == null);
}

test "shadowable mirrors the loader's registry-precedence gates" {
    try std.testing.expect(!comptime Builtin.shadowable(.Sprite));
    try std.testing.expect(!comptime Builtin.shadowable(.Shape));
    try std.testing.expect(comptime Builtin.shadowable(.Camera));
    try std.testing.expect(comptime Builtin.shadowable(.Image));
    try std.testing.expect(comptime Builtin.shadowable(.Emitter));
    try std.testing.expect(comptime Builtin.shadowable(.Tilemap));
}

test "compDecl names the Game decl carrying the component type" {
    try std.testing.expectEqualStrings("EmitterComp", comptime Builtin.compDecl(.Emitter));
    try std.testing.expectEqualStrings("SpriteComp", comptime Builtin.compDecl(.Sprite));
}
