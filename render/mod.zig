//! Render Module - Visual rendering pipeline
//!
//! This module provides the rendering layer that bridges ECS components
//! to the graphics backend (labelle-gfx RetainedEngine).
//!
//! Contents:
//! - Position, Sprite, Shape, Text components
//! - RenderPipeline for syncing ECS state to graphics
//! - Layer, sizing, and visual type definitions

const pipeline = @import("pipeline.zig");

// Backend and engine types
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

// Visual components
pub const Position = pipeline.Position;
pub const Pivot = pipeline.Pivot;
pub const Sprite = pipeline.Sprite;
pub const Shape = pipeline.Shape;
pub const Text = pipeline.Text;
pub const VisualType = pipeline.VisualType;

// Render pipeline
pub const RenderPipeline = pipeline.RenderPipeline;
