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

## Important Note: Zig dependency hashes

Zig dependencies in `build.zig.zon` typically include a **content hash** (`.hash`) for reproducible builds. The generator currently computes this hash via `zig fetch`.

This means:

- **`version`/tags**: stable, reproducible, recommended default.
- **`commit`**: stable and reproducible (best for CI pinning without a release tag).
- **`branch`**: convenient for development, but **does not automatically "track latest"** unless you **regenerate** (or otherwise refresh) `build.zig.zon` so the hash is updated when the branch tip moves.

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

### Validation Rules

After parsing `project.labelle`, validate that for each plugin:

- **Exactly one** of `version`, `branch`, or `commit` is set.
- **`name`** must be non-empty.
- **`commit`** must look like a git SHA (recommended: hex string length 7–40).

If invalid, return a clear error that identifies the plugin by name and the offending fields.

> Note: `std.zon.parse.fromSlice` does not enforce mutual exclusivity; validation must happen **after** parsing (e.g., in `ProjectConfig.load` or immediately after `load` in the generator/CLI).

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

### URL Handling

Current generator behavior assumes `url` is a host/path like `github.com/org/repo` and will build:

- `git+https://{url}#{ref}`

This RFC keeps that behavior for compatibility. If a full URL with scheme is provided (e.g. `https://…`), the implementation should either:

- **Reject** it with a clear error ("url must be host/path, omit scheme"), **or**
- **Normalize** it (strip `https://` / `http://` and `git+https://`) before generation.

Pick one and document it in `CLAUDE.md` / generator help text.

## Implementation Plan

### Phase 1: Schema Update
1. Update `ProjectConfig` in `src/project_config.zig`:
   - Add `branch` and `commit` fields to Plugin struct
   - Add post-parse validation: exactly one of `version`, `branch`, or `commit` must be set
   - Validate `commit` format (recommended: hex length 7–40)
   - Decide and enforce URL normalization/rejection rules for `url` with scheme

### Phase 2: Generator Update
2. Update `src/generator.zig`:
   - Modify `generateBuildZon` to handle branch/commit refs
   - For `version`: use `#v{version}` suffix
   - For `branch`: use `#{branch}` suffix
   - For `commit`: use `#{commit}` suffix
   - Continue to fetch `.hash` via `zig fetch` when enabled
   - Clarify in docs/help that `branch` requires regeneration to pick up new commits (hash changes)

### Phase 3: CLI Update
3. Update CLI if needed for `labelle init` templates

### Phase 4: Documentation
4. Update CLAUDE.md with new plugin reference options
5. Add examples to usage/ directory

### Phase 5: Tests
6. Add/extend tests to cover:
   - Backcompat: `version`-only plugin parses and generates identical URLs as today
   - Validation errors: none set, two set, empty name
   - Ref generation: `#v{version}` vs `#{branch}` vs `#{commit}`
   - `commit` format validation (accept 7–40 hex, reject other strings)

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

1. Should we warn when using `branch` in production builds (since it encourages non-repro workflows unless regenerated)?
2. Should `commit` require full SHA or allow short refs? (Recommendation: allow 7–40 hex.)
3. Default behavior when neither version/branch/commit specified? (Recommendation: treat as error; require explicit ref.)
4. Should `url` accept full URLs with scheme or be restricted to host/path? (Pick one and enforce it.)

## References

- Zig package manager documentation
- Current generator implementation: `src/generator.zig`
- Project config parser: `src/project_config.zig`
