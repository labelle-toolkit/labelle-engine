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

    test "script module exports Game" {
        try expect.toBeTrue(@hasDecl(script, "Game"));
    }

    test "script module exports Scene" {
        try expect.toBeTrue(@hasDecl(script, "Scene"));
    }
};
