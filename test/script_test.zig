const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const script = engine.script;

test {
    zspec.runAll(@This());
}

// Note: ScriptRegistry requires functions with specific signatures that reference Scene,
// which creates a circular dependency. We can only test the registry structure here.

pub const SCRIPT_REGISTRY = struct {
    pub const HAS_COMPTIME = struct {
        test "has function exists on registry type" {
            // Verify the ScriptRegistry function type exists
            const ScriptRegistryFn = @TypeOf(script.ScriptRegistry);
            _ = ScriptRegistryFn;
            try expect.toBeTrue(true);
        }
    };
};

pub const UPDATE_FN = struct {
    test "UpdateFn type is defined" {
        // Verify UpdateFn type exists in the script module
        try expect.toBeTrue(@hasDecl(script, "UpdateFn"));
    }
};

pub const MODULE_STRUCTURE = struct {
    test "script module exports ScriptRegistry" {
        try expect.toBeTrue(@hasDecl(script, "ScriptRegistry"));
    }

    test "script module exports UpdateFn" {
        try expect.toBeTrue(@hasDecl(script, "UpdateFn"));
    }

    test "script module exports InitFn" {
        try expect.toBeTrue(@hasDecl(script, "InitFn"));
    }

    test "script module exports DeinitFn" {
        try expect.toBeTrue(@hasDecl(script, "DeinitFn"));
    }

    test "script module exports ScriptFns" {
        try expect.toBeTrue(@hasDecl(script, "ScriptFns"));
    }

    // Game and Scene are imported from engine and scene modules respectively
    test "Game available from engine module" {
        try expect.toBeTrue(@hasDecl(engine.engine, "Game"));
    }

    test "Scene available from scene module" {
        try expect.toBeTrue(@hasDecl(engine.scene_mod, "Scene"));
    }
};
