//! Render Module - Visual rendering pipeline
//!
//! This module provides the rendering layer that bridges ECS components
//! to the graphics backend (labelle-gfx RetainedEngine).
//!
//! ## Components
//! - `Position` - Entity location (x, y coordinates)
//! - `Sprite` - Texture/sprite for rendering with pivot, layer, sizing options
//! - `Shape` - Geometric primitives (circle, rectangle, line)
//! - `Text` - Text rendering with font
//!
//! ## Automatic Tracking
//! Visual components (Sprite, Shape, Text) have lifecycle callbacks that
//! automatically track/untrack entities with the RenderPipeline when
//! added/removed from the ECS.
//!
//! ## Usage
//! ```zig
//! const render = @import("labelle-engine").render;
//!
//! // Add components - tracking happens automatically via onAdd callback
//! registry.add(entity, render.Position{ .x = 100, .y = 200 });
//! registry.add(entity, render.Sprite{ .sprite_name = "player.png" });
//!
//! // In game loop - sync dirty state to graphics
//! pipeline.sync(&registry);
//! ```

const std = @import("std");

// Components
pub const components = @import("src/components.zig");
pub const Position = components.Position;
pub const Sprite = components.Sprite;
pub const Shape = components.Shape;
pub const Text = components.Text;
pub const VisualType = components.VisualType;
pub const Pivot = components.Pivot;
pub const Components = components.Components;

// Backend and engine types
const pipeline = @import("src/pipeline.zig");
pub const RetainedEngine = pipeline.RetainedEngine;
pub const EntityId = pipeline.EntityId;
pub const TextureId = pipeline.TextureId;
pub const FontId = pipeline.FontId;
pub const SpriteVisual = pipeline.SpriteVisual;
pub const ShapeVisual = pipeline.ShapeVisual;
pub const TextVisual = pipeline.TextVisual;
pub const Color = pipeline.Color;
pub const ShapeType = pipeline.ShapeType;

// Layer system
pub const Layer = pipeline.Layer;
pub const LayerConfig = pipeline.LayerConfig;
pub const LayerSpace = pipeline.LayerSpace;

// Sizing system
pub const SizeMode = pipeline.SizeMode;
pub const Container = pipeline.Container;

// ECS types
pub const Registry = pipeline.Registry;
pub const Entity = pipeline.Entity;

// Render pipeline
pub const RenderPipeline = pipeline.RenderPipeline;

// Global pipeline access (for component callbacks)
pub const getGlobalPipeline = pipeline.getGlobalPipeline;
pub const setGlobalPipeline = pipeline.setGlobalPipeline;

test {
    std.testing.refAllDecls(@This());
}
