// Scene Module — re-exports from the scene submodule (engine/scene/).
const scene = @import("scene");

// Submodules
pub const types = scene.types;
pub const core = scene.core;
pub const loader = scene.loader;
pub const prefab = scene.prefab;
pub const component = scene.component;
pub const script = scene.script;
pub const gizmo = scene.gizmo;

// ── Types ──
pub const RefInfo = scene.RefInfo;
pub const isReference = scene.isReference;
pub const extractRefInfo = scene.extractRefInfo;
pub const generateAutoId = scene.generateAutoId;
pub const getEntityId = scene.getEntityId;
pub const ReferenceContext = scene.ReferenceContext;
pub const PendingReference = scene.PendingReference;
pub const PendingParentRef = scene.PendingParentRef;

// ── Core ──
pub const Scene = scene.Scene;
pub const VisualType = scene.VisualType;
pub const ParentComponent = scene.ParentComponent;
pub const ChildrenComponent = scene.ChildrenComponent;

// ── Script ──
pub const InitFn = scene.InitFn;
pub const UpdateFn = scene.UpdateFn;
pub const DeinitFn = scene.DeinitFn;
pub const ScriptFns = scene.ScriptFns;
pub const ScriptRegistry = scene.ScriptRegistry;
pub const NoScripts = scene.NoScripts;

// ── Prefab ──
pub const PrefabRegistry = scene.PrefabRegistry;

// ── Component ──
pub const ComponentRegistry = scene.ComponentRegistry;
pub const ComponentRegistryMulti = scene.ComponentRegistryMulti;
pub const ComponentRegistryWithPlugins = scene.ComponentRegistryWithPlugins;

// ── System ──
pub const SystemRegistry = scene.SystemRegistry;

// ── Gizmo ──
pub const GizmoComponent = scene.GizmoComponent;
pub const GizmoRegistry = scene.GizmoRegistry;
pub const NoGizmos = scene.NoGizmos;

// ── Loader ──
pub const SceneLoader = scene.SceneLoader;
pub const SceneLoaderWithGizmos = scene.SceneLoaderWithGizmos;
pub const SimpleSceneLoader = scene.SimpleSceneLoader;
