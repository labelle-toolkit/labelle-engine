# RFC 002: Plugin Branch References

**Status**: Draft
**Created**: 2025-12-25
**Issue**: #76

## Summary

Allow plugins in `project.labelle` to reference git branches, commits, or custom refs instead of only version tags.

## Motivation

Currently, plugins in `project.labelle` only support version-based references:

```zig
.plugins = .{
    .{ .name = "labelle-tasks", .version = "0.5.0" },
},
```

This limitation makes it difficult to:
1. Test plugin changes during development before releasing
2. Use latest `main` branch in CI pipelines
3. Test unreleased plugin features
4. Work with forked repositories

## Design

### Current Plugin Schema

```zig
const Plugin = struct {
    name: []const u8,
    version: []const u8,
    url: ?[]const u8 = null,      // Custom URL (optional)
    module: ?[]const u8 = null,   // Module name override (optional)
    components: ?[]const u8 = null,
};
```

### Proposed Plugin Schema

```zig
const Plugin = struct {
    name: []const u8,

    // Reference type (mutually exclusive, one required)
    version: ?[]const u8 = null,  // Tag reference: v{version}
    branch: ?[]const u8 = null,   // Branch reference
    commit: ?[]const u8 = null,   // Commit SHA reference

    // Optional overrides
    url: ?[]const u8 = null,      // Custom base URL
    module: ?[]const u8 = null,   // Module name override
    components: ?[]const u8 = null,
};
```

### Usage Examples

#### Version Tag (existing behavior)
```zig
.plugins = .{
    .{ .name = "labelle-tasks", .version = "0.5.0" },
},
```
Generates: `git+https://github.com/labelle-toolkit/labelle-tasks#v0.5.0`

#### Branch Reference
```zig
.plugins = .{
    .{ .name = "labelle-tasks", .branch = "main" },
    .{ .name = "labelle-gui", .branch = "feature/new-widgets" },
},
```
Generates: `git+https://github.com/labelle-toolkit/labelle-tasks#main`

#### Commit Reference
```zig
.plugins = .{
    .{ .name = "labelle-tasks", .commit = "abc123def456" },
},
```
Generates: `git+https://github.com/labelle-toolkit/labelle-tasks#abc123def456`

#### Custom URL with Branch
```zig
.plugins = .{
    .{
        .name = "labelle-tasks",
        .url = "github.com/myuser/labelle-tasks-fork",
        .branch = "my-feature",
    },
},
```
Generates: `git+https://github.com/myuser/labelle-tasks-fork#my-feature`

#### GitLab/Other Providers
```zig
.plugins = .{
    .{
        .name = "my-plugin",
        .url = "gitlab.com/myorg/my-plugin",
        .branch = "develop",
    },
},
```
Generates: `git+https://gitlab.com/myorg/my-plugin#develop`

## Implementation Plan

### Phase 1: Schema Update
1. Update `ProjectConfig` in `src/project_config.zig`:
   - Add `branch` and `commit` fields to Plugin struct
   - Add validation: exactly one of `version`, `branch`, or `commit` must be set

### Phase 2: Generator Update
2. Update `src/generator.zig`:
   - Modify `generateBuildZon` to handle branch/commit refs
   - For `version`: use `#v{version}` suffix
   - For `branch`: use `#{branch}` suffix
   - For `commit`: use `#{commit}` suffix

### Phase 3: CLI Update
3. Update CLI if needed for `labelle init` templates

### Phase 4: Documentation
4. Update CLAUDE.md with new plugin reference options
5. Add examples to usage/ directory

## Files to Modify

| File | Changes |
|------|---------|
| `src/project_config.zig` | Add `branch` and `commit` fields, validation |
| `src/generator.zig` | Handle new ref types in URL generation |
| `CLAUDE.md` | Document new plugin options |

## Backwards Compatibility

- Existing `project.labelle` files continue to work unchanged
- `version` field remains the default/recommended for stable dependencies
- No breaking changes to existing API

## Alternatives Considered

### 1. Unified `ref` Field
```zig
.{ .name = "plugin", .ref = "v0.5.0" },
.{ .name = "plugin", .ref = "main" },
```
**Rejected**: Ambiguous whether ref is a tag, branch, or commit.

### 2. URL-Only Approach
Require users to specify full URLs for non-version refs.
**Rejected**: Too verbose for common use cases.

## Open Questions

1. Should we warn when using `branch` in production builds?
2. Should `commit` require full SHA or allow short refs?
3. Default behavior when neither version/branch/commit specified?

## References

- Zig package manager documentation
- Current generator implementation: `src/generator.zig`
- Project config parser: `src/project_config.zig`
