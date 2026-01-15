//! Graphics Interface
//!
//! Provides a unified graphics API with compile-time backend selection.
//! The backend is chosen at build time based on the `backend` build option.
//!
//! This interface abstracts the graphics types from labelle-gfx, allowing
//! plugins to depend on labelle-engine without pulling in specific backend
//! modules (SDL, raylib, etc.), which avoids module collision issues.
//!
//! Usage:
//!   const graphics = @import("graphics");
//!   const engine: *graphics.RetainedEngine = ...;
//!   engine.createSprite(entity_id, visual, pos);

const build_options = @import("build_options");

/// Graphics backend selection (enum type)
pub const Backend = build_options.@"build.Backend";

/// The current graphics backend (enum value)
pub const backend: Backend = build_options.backend;

/// Creates a validated graphics interface from an implementation type.
/// The implementation must provide all required types.
pub fn GraphicsInterface(comptime Impl: type) type {
    // Compile-time validation: ensure Impl has all required types
    comptime {
        // Core engine type
        if (!@hasDecl(Impl, "RetainedEngine")) {
            @compileError("Graphics backend must declare RetainedEngine type");
        }

        // ID types
        if (!@hasDecl(Impl, "EntityId")) {
            @compileError("Graphics backend must declare EntityId type");
        }
        if (!@hasDecl(Impl, "TextureId")) {
            @compileError("Graphics backend must declare TextureId type");
        }
        if (!@hasDecl(Impl, "FontId")) {
            @compileError("Graphics backend must declare FontId type");
        }

        // Visual types
        if (!@hasDecl(Impl, "SpriteVisual")) {
            @compileError("Graphics backend must declare SpriteVisual type");
        }
        if (!@hasDecl(Impl, "ShapeVisual")) {
            @compileError("Graphics backend must declare ShapeVisual type");
        }
        if (!@hasDecl(Impl, "TextVisual")) {
            @compileError("Graphics backend must declare TextVisual type");
        }

        // Common types
        if (!@hasDecl(Impl, "Color")) {
            @compileError("Graphics backend must declare Color type");
        }
        if (!@hasDecl(Impl, "ShapeType")) {
            @compileError("Graphics backend must declare ShapeType type");
        }
        if (!@hasDecl(Impl, "Position")) {
            @compileError("Graphics backend must declare Position type");
        }

        // Layer system
        if (!@hasDecl(Impl, "Layer")) {
            @compileError("Graphics backend must declare Layer type");
        }
        if (!@hasDecl(Impl, "LayerConfig")) {
            @compileError("Graphics backend must declare LayerConfig type");
        }
        if (!@hasDecl(Impl, "LayerSpace")) {
            @compileError("Graphics backend must declare LayerSpace type");
        }

        // Sizing system
        if (!@hasDecl(Impl, "SizeMode")) {
            @compileError("Graphics backend must declare SizeMode type");
        }
        if (!@hasDecl(Impl, "Container")) {
            @compileError("Graphics backend must declare Container type");
        }

        // Pivot system
        if (!@hasDecl(Impl, "Pivot")) {
            @compileError("Graphics backend must declare Pivot type");
        }
    }

    return struct {
        pub const RetainedEngine = Impl.RetainedEngine;
        pub const EntityId = Impl.EntityId;
        pub const TextureId = Impl.TextureId;
        pub const FontId = Impl.FontId;
        pub const SpriteVisual = Impl.SpriteVisual;
        pub const ShapeVisual = Impl.ShapeVisual;
        pub const TextVisual = Impl.TextVisual;
        pub const Color = Impl.Color;
        pub const ShapeType = Impl.ShapeType;
        pub const Position = Impl.Position;
        pub const Layer = Impl.Layer;
        pub const LayerConfig = Impl.LayerConfig;
        pub const LayerSpace = Impl.LayerSpace;
        pub const SizeMode = Impl.SizeMode;
        pub const Container = Impl.Container;
        pub const Pivot = Impl.Pivot;
    };
}

// Select and validate graphics backend based on build option
const BackendImpl = switch (backend) {
    .raylib => @import("raylib_graphics.zig"),
    .sokol => @import("sokol_graphics.zig"),
    .sdl => @import("sdl_graphics.zig"),
    .bgfx => @import("bgfx_graphics.zig"),
    .wgpu_native => @import("wgpu_native_graphics.zig"),
};

// Apply the interface to verify the backend at compile time
const Interface = GraphicsInterface(BackendImpl);

// ============================================
// Public Type Exports
// ============================================

/// The retained-mode graphics engine for the selected backend.
/// Manages sprites, shapes, and text rendering with dirty tracking.
pub const RetainedEngine = Interface.RetainedEngine;

/// Entity identifier for graphics operations.
/// Maps ECS entities to graphics layer entities.
pub const EntityId = Interface.EntityId;

/// Texture/sprite sheet identifier.
pub const TextureId = Interface.TextureId;

/// Font identifier for text rendering.
pub const FontId = Interface.FontId;

/// Visual configuration for sprites.
pub const SpriteVisual = Interface.SpriteVisual;

/// Visual configuration for shapes.
pub const ShapeVisual = Interface.ShapeVisual;

/// Visual configuration for text.
pub const TextVisual = Interface.TextVisual;

/// RGBA color type.
pub const Color = Interface.Color;

/// Shape primitives (circle, rectangle, line, etc.).
pub const ShapeType = Interface.ShapeType;

/// Position for graphics operations.
pub const Position = Interface.Position;

/// Rendering layer (background, world, ui).
pub const Layer = Interface.Layer;

/// Layer configuration settings.
pub const LayerConfig = Interface.LayerConfig;

/// Layer coordinate space (screen or world).
pub const LayerSpace = Interface.LayerSpace;

/// Sizing mode for sprites (stretch, cover, contain, etc.).
pub const SizeMode = Interface.SizeMode;

/// Container specification for sized sprites.
pub const Container = Interface.Container;

/// Pivot point for positioning and rotation.
pub const Pivot = Interface.Pivot;

// ============================================
// Tests
// ============================================

test "graphics interface types available" {
    // Verify all types are accessible at comptime
    _ = RetainedEngine;
    _ = EntityId;
    _ = TextureId;
    _ = FontId;
    _ = SpriteVisual;
    _ = ShapeVisual;
    _ = TextVisual;
    _ = Color;
    _ = ShapeType;
    _ = Position;
    _ = Layer;
    _ = LayerConfig;
    _ = LayerSpace;
    _ = SizeMode;
    _ = Container;
    _ = Pivot;
}
