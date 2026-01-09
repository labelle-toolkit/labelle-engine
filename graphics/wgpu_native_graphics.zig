//! WGPU Native Graphics Backend
//!
//! Re-exports labelle-gfx types for the wgpu_native backend.

const labelle = @import("labelle");

// Core engine - use wgpu_native backend
const WgpuNativeGfx = labelle.withBackend(labelle.WgpuNativeBackend);
pub const RetainedEngine = WgpuNativeGfx.RetainedEngine;

// ID types
pub const EntityId = labelle.EntityId;
pub const TextureId = labelle.TextureId;
pub const FontId = labelle.FontId;

// Visual types (from RetainedEngine)
pub const SpriteVisual = RetainedEngine.SpriteVisual;
pub const ShapeVisual = RetainedEngine.ShapeVisual;
pub const TextVisual = RetainedEngine.TextVisual;

// Common types
pub const Color = labelle.retained_engine.Color;
pub const ShapeType = labelle.retained_engine.Shape;
pub const Position = labelle.retained_engine.Position;

// Layer system
pub const Layer = labelle.DefaultLayers;
pub const LayerConfig = labelle.LayerConfig;
pub const LayerSpace = labelle.LayerSpace;
