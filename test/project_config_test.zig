const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const project_config = @import("labelle-engine").project_config;
const Plugin = project_config.Plugin;
const PluginValidationError = project_config.PluginValidationError;

test {
    zspec.runAll(@This());
}

// ============================================
// Plugin Validation Tests
// ============================================

pub const PLUGIN_VALIDATION = struct {
    pub const VERSION_REF = struct {
        test "version only is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
            };
            try plugin.validate();
        }

        test "getRef returns version" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
            };
            try expect.toBeTrue(std.mem.eql(u8, plugin.getRef(), "0.5.0"));
        }

        test "isVersionRef returns true" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
            };
            try expect.toBeTrue(plugin.isVersionRef());
        }
    };

    pub const BRANCH_REF = struct {
        test "branch only is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .branch = "main",
            };
            try plugin.validate();
        }

        test "feature branch is valid" {
            const plugin = Plugin{
                .name = "labelle-gui",
                .branch = "feature/new-widgets",
            };
            try plugin.validate();
        }

        test "getRef returns branch" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .branch = "main",
            };
            try expect.toBeTrue(std.mem.eql(u8, plugin.getRef(), "main"));
        }

        test "isVersionRef returns false" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .branch = "main",
            };
            try expect.toBeFalse(plugin.isVersionRef());
        }
    };

    pub const COMMIT_REF = struct {
        test "short commit (7 chars) is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123f",
            };
            try plugin.validate();
        }

        test "full commit (40 chars) is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123def456789012345678901234567890abcd",
            };
            try plugin.validate();
        }

        test "medium commit (12 chars) is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123def456",
            };
            try plugin.validate();
        }

        test "getRef returns commit" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123def456",
            };
            try expect.toBeTrue(std.mem.eql(u8, plugin.getRef(), "abc123def456"));
        }

        test "isVersionRef returns false" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123def456",
            };
            try expect.toBeFalse(plugin.isVersionRef());
        }

        test "too short commit (6 chars) is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123",
            };
            try std.testing.expectError(PluginValidationError.InvalidCommitLength, plugin.validate());
        }

        test "too long commit (41 chars) is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123def456789012345678901234567890abcde",
            };
            try std.testing.expectError(PluginValidationError.InvalidCommitLength, plugin.validate());
        }

        test "non-hex commit is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123g",
            };
            try std.testing.expectError(PluginValidationError.InvalidCommitFormat, plugin.validate());
        }

        test "uppercase hex is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "ABC123DEF456",
            };
            try plugin.validate();
        }
    };

    pub const NO_REF = struct {
        test "no ref is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
            };
            try std.testing.expectError(PluginValidationError.NoRefSpecified, plugin.validate());
        }
    };

    pub const MULTIPLE_REFS = struct {
        test "version and branch is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .branch = "main",
            };
            try std.testing.expectError(PluginValidationError.MultipleRefsSpecified, plugin.validate());
        }

        test "version and commit is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .commit = "abc123f",
            };
            try std.testing.expectError(PluginValidationError.MultipleRefsSpecified, plugin.validate());
        }

        test "branch and commit is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .branch = "main",
                .commit = "abc123f",
            };
            try std.testing.expectError(PluginValidationError.MultipleRefsSpecified, plugin.validate());
        }

        test "all three refs is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .branch = "main",
                .commit = "abc123f",
            };
            try std.testing.expectError(PluginValidationError.MultipleRefsSpecified, plugin.validate());
        }
    };

    pub const EMPTY_NAME = struct {
        test "empty name is invalid" {
            const plugin = Plugin{
                .name = "",
                .version = "0.5.0",
            };
            try std.testing.expectError(PluginValidationError.EmptyName, plugin.validate());
        }
    };

    pub const URL_VALIDATION = struct {
        test "host/path url is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .url = "github.com/labelle-toolkit/labelle-tasks",
            };
            try plugin.validate();
        }

        test "gitlab url is valid" {
            const plugin = Plugin{
                .name = "my-plugin",
                .branch = "develop",
                .url = "gitlab.com/myorg/my-plugin",
            };
            try plugin.validate();
        }

        test "https url is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .url = "https://github.com/labelle-toolkit/labelle-tasks",
            };
            try std.testing.expectError(PluginValidationError.UrlContainsScheme, plugin.validate());
        }

        test "http url is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .url = "http://github.com/labelle-toolkit/labelle-tasks",
            };
            try std.testing.expectError(PluginValidationError.UrlContainsScheme, plugin.validate());
        }

        test "git+https url is invalid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .url = "git+https://github.com/labelle-toolkit/labelle-tasks",
            };
            try std.testing.expectError(PluginValidationError.UrlContainsScheme, plugin.validate());
        }
    };

    pub const CUSTOM_URL_WITH_REFS = struct {
        test "custom url with version is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .url = "github.com/myuser/labelle-tasks-fork",
            };
            try plugin.validate();
        }

        test "custom url with branch is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .branch = "my-feature",
                .url = "github.com/myuser/labelle-tasks-fork",
            };
            try plugin.validate();
        }

        test "custom url with commit is valid" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .commit = "abc123def456",
                .url = "github.com/myuser/labelle-tasks-fork",
            };
            try plugin.validate();
        }
    };

    pub const MODULE_AND_COMPONENTS = struct {
        test "module override is preserved" {
            const plugin = Plugin{
                .name = "labelle-pathfinding",
                .version = "2.5.0",
                .module = "pathfinding",
            };
            try plugin.validate();
            try expect.toBeTrue(std.mem.eql(u8, plugin.module.?, "pathfinding"));
        }

        test "components field is preserved" {
            const plugin = Plugin{
                .name = "labelle-tasks",
                .version = "0.5.0",
                .components = "Components",
            };
            try plugin.validate();
            try expect.toBeTrue(std.mem.eql(u8, plugin.components.?, "Components"));
        }
    };
};
