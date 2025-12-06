const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");

test {
    zspec.runAll(@This());
}

// Note: Scene and SceneContext have circular dependency with script.UpdateFn
// so we can only test the module exports without triggering the dependency loop

pub const MODULE_EXPORTS = struct {
    pub const PREFAB_EXPORTS = struct {
        test "exports Prefab type" {
            try expect.toBeTrue(@hasDecl(engine, "Prefab"));
        }

        test "exports SpriteConfig type" {
            try expect.toBeTrue(@hasDecl(engine, "SpriteConfig"));
        }

        test "exports PrefabRegistry function" {
            try expect.toBeTrue(@hasDecl(engine, "PrefabRegistry"));
        }
    };

    pub const LOADER_EXPORTS = struct {
        test "exports SceneLoader function" {
            try expect.toBeTrue(@hasDecl(engine, "SceneLoader"));
        }
    };

    pub const COMPONENT_EXPORTS = struct {
        test "exports ComponentRegistry function" {
            try expect.toBeTrue(@hasDecl(engine, "ComponentRegistry"));
        }
    };

    pub const SCRIPT_EXPORTS = struct {
        test "exports ScriptRegistry function" {
            try expect.toBeTrue(@hasDecl(engine, "ScriptRegistry"));
        }
    };

    pub const SCENE_EXPORTS = struct {
        test "exports Scene type" {
            try expect.toBeTrue(@hasDecl(engine, "Scene"));
        }

        test "exports SceneContext type" {
            try expect.toBeTrue(@hasDecl(engine, "SceneContext"));
        }

        test "exports EntityInstance type" {
            try expect.toBeTrue(@hasDecl(engine, "EntityInstance"));
        }
    };

    pub const EXTERNAL_EXPORTS = struct {
        test "exports VisualEngine type" {
            try expect.toBeTrue(@hasDecl(engine, "VisualEngine"));
        }

        test "exports SpriteId type" {
            try expect.toBeTrue(@hasDecl(engine, "SpriteId"));
        }

        test "exports ZIndex type" {
            try expect.toBeTrue(@hasDecl(engine, "ZIndex"));
        }

        test "exports Registry type" {
            try expect.toBeTrue(@hasDecl(engine, "Registry"));
        }

        test "exports Entity type" {
            try expect.toBeTrue(@hasDecl(engine, "Entity"));
        }
    };

    pub const SUBMODULE_EXPORTS = struct {
        test "exports prefab submodule" {
            try expect.toBeTrue(@hasDecl(engine, "prefab"));
        }

        test "exports loader submodule" {
            try expect.toBeTrue(@hasDecl(engine, "loader"));
        }

        test "exports component submodule" {
            try expect.toBeTrue(@hasDecl(engine, "component"));
        }

        test "exports script submodule" {
            try expect.toBeTrue(@hasDecl(engine, "script"));
        }
    };
};
