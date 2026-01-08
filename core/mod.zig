//! Core module - Foundation types and utilities
//!
//! This module provides foundational types used throughout labelle-engine
//! with zero internal dependencies (only std and ecs).
//!
//! Contents:
//! - Entity utilities for lifecycle hooks (entityToU64, entityFromU64)
//! - ZON coercion utilities for comptime struct building
//! - SparseSet for O(1) lookup data structures

const entity_utils = @import("src/entity_utils.zig");
const zon_coercion = @import("src/zon_coercion.zig");
const sparse_set = @import("src/sparse_set.zig");

// Re-export entity utilities
pub const Entity = entity_utils.Entity;
pub const EntityBits = entity_utils.EntityBits;
pub const entityToU64 = entity_utils.entityToU64;
pub const entityFromU64 = entity_utils.entityFromU64;

// Re-export ZON coercion utilities
pub const zon = zon_coercion;
pub const buildStruct = zon_coercion.buildStruct;
pub const coerceValue = zon_coercion.coerceValue;
pub const tupleToSlice = zon_coercion.tupleToSlice;
pub const isEntity = zon_coercion.isEntity;
pub const isEntitySlice = zon_coercion.isEntitySlice;
pub const mergeStructs = zon_coercion.mergeStructs;
pub const hasFields = zon_coercion.hasFields;

// Re-export SparseSet
pub const SparseSet = sparse_set.SparseSet;
