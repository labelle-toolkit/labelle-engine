//! Engine Module - High-level game facade
//!
//! This module provides the top-level Game facade that orchestrates:
//! - Window initialization and game loop
//! - ECS registry management
//! - Render pipeline coordination
//! - Input and audio systems
//! - Scene management and transitions

const game = @import("game.zig");

// Game facade
pub const Game = game.Game;
pub const GameWith = game.GameWith;

// Configuration types
pub const GameConfig = game.GameConfig;
pub const WindowConfig = game.WindowConfig;
pub const ScreenSize = game.ScreenSize;

// Re-export render pipeline types from game
pub const RenderPipeline = game.RenderPipeline;
pub const Position = game.Position;
pub const Sprite = game.Sprite;
pub const Shape = game.Shape;
pub const Text = game.Text;
pub const VisualType = game.VisualType;
pub const Color = game.Color;
pub const TextureId = game.TextureId;
pub const FontId = game.FontId;
