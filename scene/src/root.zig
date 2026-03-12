//! Scene Module — Declarative scene and prefab system for v2
//!
//! Ported from v1 labelle-engine/scene, adapted to v2's comptime-parameterized architecture:
//! - No hardcoded ECS module — uses GameType.EcsBackend comptime slot
//! - No concrete Game type — GameType is fully parameterized via GameConfig(...)
//! - Deep .zon coercion built-in (handles structs, unions, enums recursively)

// Submodules
pub const types = @import("types.zig");
pub const core = @import("core.zig");
pub const loader = @import("loader.zig");
pub const entity_writer = @import("entity_writer.zig");
pub const prefab = @import("prefab.zig");
pub const component = @import("component.zig");
pub const script = @import("script.zig");
pub const gizmo = @import("gizmo.zig");

// ── Types ──
pub const RefInfo = types.RefInfo;
pub const isReference = types.isReference;
pub const extractRefInfo = types.extractRefInfo;
pub const generateAutoId = types.generateAutoId;
pub const getEntityId = types.getEntityId;
pub const ReferenceContext = types.ReferenceContext;
pub const PendingReference = types.PendingReference;
pub const PendingParentRef = types.PendingParentRef;

// ── Core ──
pub const Scene = core.Scene;
pub const VisualType = core.VisualType;
pub const ParentComponent = core.ParentComponent;
pub const ChildrenComponent = core.ChildrenComponent;

// ── Script ──
pub const InitFn = script.InitFn;
pub const UpdateFn = script.UpdateFn;
pub const DeinitFn = script.DeinitFn;
pub const ScriptFns = script.ScriptFns;
pub const ScriptRegistry = script.ScriptRegistry;
pub const NoScripts = script.NoScripts;

// ── Prefab ──
pub const PrefabRegistry = prefab.PrefabRegistry;

// ── Component ──
pub const ComponentRegistry = component.ComponentRegistry;
pub const ComponentRegistryMulti = component.ComponentRegistryMulti;

// ── Gizmo ──
pub const GizmoComponent = gizmo.GizmoComponent;
pub const GizmoRegistry = gizmo.GizmoRegistry;
pub const NoGizmos = gizmo.NoGizmos;

// ── Entity Writer ──
pub const EntityWriter = entity_writer.EntityWriter;

// ── Loader ──
pub const SceneLoader = loader.SceneLoader;
pub const SceneLoaderWithGizmos = loader.SceneLoaderWithGizmos;
pub const SimpleSceneLoader = loader.SimpleSceneLoader;
