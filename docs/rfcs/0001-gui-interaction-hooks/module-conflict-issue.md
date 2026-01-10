# Module Conflict Issue - gui/hooks.zig

## Problem

When building any project that uses `labelle-engine`, compilation fails with:

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

The file `gui/hooks.zig` imports `../hooks/mod.zig` to use the generic `HookDispatcher`, `MergeHooks`, and `EmptyDispatcher` utilities:

```zig
// gui/hooks.zig line 43
const hooks = @import("../hooks/mod.zig");

// Then uses:
pub fn GuiHookDispatcher(comptime HookMap: type) type {
    return hooks.HookDispatcher(GuiHook, GuiHookPayload, HookMap);
}
```

This creates a module conflict because:
1. `root.zig` exports `hooks/mod.zig` as part of the `labelle-engine` module
2. `gui/mod.zig` (which is a separate module) imports `gui/hooks.zig`
3. `gui/hooks.zig` imports `hooks/mod.zig` from the parent directory
4. Zig's module system sees `hooks/mod.zig` being imported by two different modules → error

## Impact

**CRITICAL**: This breaks ALL builds on the `poc/formbinder` branch, including:
- `usage/example_gui/`
- `usage/example_conditional_form/`
- Any project using the engine

## Solution Options

### Option 1: Inline Hook Dispatcher Logic (Quick Fix)
Copy the necessary `HookDispatcher`, `MergeHooks`, and `EmptyDispatcher` code directly into `gui/hooks.zig`. This removes the dependency on `../hooks/mod.zig`.

**Pros**: Simple, fast fix
**Cons**: Code duplication

### Option 2: Re-export Through Root (Cleaner)
Have `gui/hooks.zig` NOT import `../hooks/mod.zig` directly. Instead:
1. `root.zig` passes the hook dispatcher types to `gui/mod.zig` as parameters
2. `gui/mod.zig` uses these passed-in types

**Pros**: No duplication, maintains module boundaries
**Cons**: More complex refactoring

### Option 3: Make GUI Hooks Standalone (Best Long-term)
GUI hooks don't need the full engine hook system. Create lightweight, standalone implementations:
- `GuiHookDispatcher` - simple comptime dispatcher
- `MergeGuiHooks` - merge multiple handler structs
- `EmptyGuiDispatcher` - no-op dispatcher

**Pros**: GUI system becomes more independent, clearer separation of concerns
**Cons**: Most code changes

## Recommended Solution

**Option 3** is recommended for the final implementation because:
1. GUI hooks are domain-specific (button clicks, sliders) vs engine hooks (lifecycle events)
2. GUI system should be usable independently
3. Clearer API boundaries
4. Prevents future cross-module issues

For the POC, **Option 1** can be used as a quick fix to unblock testing.

## Files Affected

- `gui/hooks.zig` (source of the issue)
- `gui/form_binder.zig` (uses GuiHookDispatcher)
- `gui/conditional_visibility_example.zig` (example code)
- All usage examples that import GUI

## Steps to Fix (Option 3)

1. Remove line 43 from `gui/hooks.zig`: `const hooks = @import("../hooks/mod.zig");`

2. Add standalone dispatcher implementation to `gui/hooks.zig`:

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
    // Implementation that combines handlers from multiple structs
    // ... (similar to hooks/dispatcher.zig MergeHooks)
}

/// Empty GUI dispatcher (no-op)
pub const EmptyGuiDispatcher = struct {
    pub fn emit(_: GuiHookPayload) void {}
};
```

3. Update tests to verify the standalone implementation works

4. Update examples to use the new API

## Testing Checklist

After fix:
- [ ] `zig build test` passes in `labelle-engine/`
- [ ] `zig build` passes in `usage/example_gui/`
- [ ] `zig build` passes in `usage/example_conditional_form/`
- [ ] FormBinder tests still pass
- [ ] No module conflict errors

## Branch Status

**Branch**: `poc/formbinder`  
**Status**: 🔴 BROKEN - All builds fail due to module conflict  
**Priority**: HIGH - Must be fixed before PR can be merged

---

Created: 2026-01-09  
Issue: TBD (create GitHub issue)  
Related Files:
- `gui/hooks.zig:43`
- `gui/form_binder.zig`
- `hooks/mod.zig`
- `root.zig:22`
