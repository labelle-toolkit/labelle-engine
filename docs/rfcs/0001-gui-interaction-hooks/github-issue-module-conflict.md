# Module Conflict: gui/hooks.zig breaks all builds on poc/formbinder

## Summary

The `poc/formbinder` branch introduces a critical module conflict that prevents ANY project from building. The issue stems from `gui/hooks.zig` importing `../hooks/mod.zig`, which violates Zig's module system rules.

## Error Message

```
error: file exists in modules 'labelle-engine' and 'gui'
gui/hooks.zig:1:1: note: files must belong to only one module
root.zig:22:27: note: file is imported here by the root of module 'labelle-engine'
pub const hooks = @import("hooks/mod.zig");
                          ^~~~~~~~~~~~~~~
gui/hooks.zig:43:23: note: file is imported here
const hooks = @import("../hooks/mod.zig");
                      ^~~~~~~~~~~~~~~~~~
gui/mod.zig:52:27: note: which is imported here by the root of module 'gui'
pub const hooks = @import("hooks.zig");
                          ^~~~~~~~~~~
```

## Root Cause

**File**: `gui/hooks.zig:43`

```zig
const hooks = @import("../hooks/mod.zig");
```

This import creates a module conflict because:
1. `root.zig` exports `hooks/mod.zig` as part of the `labelle-engine` module
2. `gui/mod.zig` (separate module) imports `gui/hooks.zig`
3. `gui/hooks.zig` imports `hooks/mod.zig` from parent directory
4. **Result**: `hooks/mod.zig` appears in two different modules → Zig error

## Impact

**CRITICAL**: Blocks ALL builds on `poc/formbinder` branch
- ❌ `usage/example_gui/` - BROKEN
- ❌ `usage/example_conditional_form/` - BROKEN
- ❌ Any project using labelle-engine from this branch
- ❌ Cannot test FormBinder POC implementation
- ❌ Cannot demonstrate conditional visibility

## Why This Happened

`gui/hooks.zig` imports the engine's hook system to reuse `HookDispatcher`, `MergeHooks`, and `EmptyDispatcher`:

```zig
pub fn GuiHookDispatcher(comptime HookMap: type) type {
    return hooks.HookDispatcher(GuiHook, GuiHookPayload, HookMap);
}
```

While this seemed like good code reuse, it violates Zig's module boundaries.

## Proposed Solution

**Make GUI hooks standalone** by implementing a lightweight dispatcher directly in `gui/hooks.zig`.

### Implementation

Remove the problematic import and add:

```zig
/// Standalone GUI hook dispatcher (no dependency on engine hooks)
pub fn GuiHookDispatcher(comptime HookMap: type) type {
    return struct {
        pub fn emit(payload: GuiHookPayload) void {
            switch (payload) {
                inline else => |info, tag| {
                    const hook_name = @tagName(tag);
                    if (@hasDecl(HookMap, hook_name)) {
                        const handler = @field(HookMap, hook_name);
                        handler(payload);
                    }
                },
            }
        }
    };
}

/// Merge multiple GUI hook handler structs
pub fn MergeGuiHooks(comptime handler_structs: anytype) type {
    var merged = struct {};
    inline for (handler_structs) |HandlerStruct| {
        const fields = @typeInfo(HandlerStruct).Struct.decls;
        inline for (fields) |decl| {
            if (@hasDecl(merged, decl.name)) continue;
            @field(merged, decl.name) = @field(HandlerStruct, decl.name);
        }
    }
    return merged;
}

/// Empty GUI dispatcher (no-op)
pub const EmptyGuiDispatcher = struct {
    pub fn emit(_: GuiHookPayload) void {}
};
```

### Why This is Better

1. **Independence**: GUI hooks are domain-specific (clicks, sliders) vs engine hooks (lifecycle events)
2. **Clarity**: Clearer API boundaries between GUI and engine
3. **Simplicity**: Hook dispatcher logic is simple, no significant duplication
4. **Future-proof**: Prevents similar cross-module issues

## Files to Change

- `gui/hooks.zig` - Remove line 43, add standalone implementations
- `gui/form_binder.zig` - No changes needed (uses public API)
- `gui/conditional_visibility_example.zig` - No changes needed

## Testing Checklist

After fix:
- [ ] `zig build test` passes in `labelle-engine/`
- [ ] `zig build` succeeds in `usage/example_gui/`
- [ ] `zig build` succeeds in `usage/example_conditional_form/`
- [ ] FormBinder unit tests still pass (9 tests)
- [ ] No module conflict errors

## Documentation

Comprehensive analysis available in:
- `docs/rfcs/0001-gui-interaction-hooks/module-conflict-issue.md`
- `docs/rfcs/0001-gui-interaction-hooks/SESSION_SUMMARY.md`

## Priority

**HIGH** - This blocks completion of the FormBinder POC and prevents testing of GUI interaction hooks RFC implementation.

## Related

- RFC: docs/rfcs/0001-gui-interaction-hooks.md
- Branch: `poc/formbinder`
- Original issue: #210 (GUI interaction system)
