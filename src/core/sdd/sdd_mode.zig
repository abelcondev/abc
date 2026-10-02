//! SDD mode: whether fx runs its spec-driven development process in a
//! workspace.
//!
//! Read only from the profile `~/.fx/settings.json`; a project `.fx.json`
//! cannot turn the process on. Precedence, highest first: `FX_SDD` (on/off),
//! `workspaces["<root>"].sdd.enabled`, top-level `sdd.enabled`, then off.
//!
//! ```json
//! "sdd": { "enabled": false },
//! "workspaces": { "/path/to/repo": { "sdd": { "enabled": true, "tdd": "on", "test": "bun test" } } }
//! ```
//!
//! `tdd` (`off`, `auto`, `on` or `strict`; `off` by default; under `auto` Jev
//! decides per request whether a change is test-first) and `test` (the project's test command,
//! used besides the common runners fx recognizes) resolve the same way,
//! workspace first, without the environment override.
//!
//! While SDD is off, fx does not check decision records after a turn;
//! `fx jev drift` still runs on demand.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const env_name = "FX_SDD";

const max_settings_bytes = 4 * 1024 * 1024;

pub const Source = enum {
    default,
    profile,
    workspace,
    environment,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .default => "default",
            .profile => "profile setting",
            .workspace => "workspace setting",
            .environment => env_name,
        };
    }
};

pub const Tdd = enum { off, auto, on, strict };

pub const max_test_command_bytes = 256;

pub const Mode = struct {
    enabled: bool = false,
    source: Source = .default,
    tdd: Tdd = .off,
    test_command_buf: [max_test_command_bytes]u8 = undefined,
    test_command_len: usize = 0,

    /// The configured test command, if any.
    pub fn testCommand(self: *const Mode) ?[]const u8 {
        return if (self.test_command_len == 0) null else self.test_command_buf[0..self.test_command_len];
    }
};

/// Resolves the mode from parsed profile settings (null when absent or
/// unreadable) and the raw `FX_SDD` value.
pub fn resolve(settings: ?std.json.Value, workspace_root: []const u8, env: ?[]const u8) Mode {
    var mode = Mode{};
    const root: ?std.json.Value = if (settings) |value| (if (value == .object) value else null) else null;
    const workspace: ?std.json.Value = blk: {
        const value = root orelse break :blk null;
        const workspaces = value.object.get("workspaces") orelse break :blk null;
        if (workspaces != .object) break :blk null;
        break :blk workspaces.object.get(trimTrailingSlashes(workspace_root));
    };
    if (workspace) |value| {
        if (enabledField(value)) |enabled| {
            mode.enabled = enabled;
            mode.source = .workspace;
        }
    }
    if (mode.source == .default) {
        if (root) |value| {
            if (enabledField(value)) |enabled| {
                mode.enabled = enabled;
                mode.source = .profile;
            }
        }
    }
    if (env) |raw| {
        if (parseSwitch(std.mem.trim(u8, raw, " \t\r\n"))) |enabled| {
            mode.enabled = enabled;
            mode.source = .environment;
        }
    }
    const tdd = (if (workspace) |value| sddString(value, "tdd") else null) orelse
        (if (root) |value| sddString(value, "tdd") else null);
    if (tdd) |text| mode.tdd = std.meta.stringToEnum(Tdd, text) orelse .off;
    const command = (if (workspace) |value| sddString(value, "test") else null) orelse
        (if (root) |value| sddString(value, "test") else null);
    if (command) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len != 0 and trimmed.len <= max_test_command_bytes) {
            @memcpy(mode.test_command_buf[0..trimmed.len], trimmed);
            mode.test_command_len = trimmed.len;
        }
    }
    return mode;
}

fn sddString(container: std.json.Value, name: []const u8) ?[]const u8 {
    if (container != .object) return null;
    const sdd = container.object.get("sdd") orelse return null;
    if (sdd != .object) return null;
    const value = sdd.object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

/// Loads the mode for `workspace_root`. Missing or unreadable settings mean
/// off unless `FX_SDD` says otherwise.
pub fn load(alloc: Allocator, workspace_root: []const u8) Mode {
    const env = io_mod.getenv(env_name);
    const home = io_mod.getenv("HOME") orelse return resolve(null, workspace_root, env);
    const path = profile_paths.settingsPath(alloc, home) catch return resolve(null, workspace_root, env);
    defer alloc.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(max_settings_bytes)) catch
        return resolve(null, workspace_root, env);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return resolve(null, workspace_root, env);
    defer parsed.deinit();
    return resolve(parsed.value, workspace_root, env);
}

fn enabledField(container: std.json.Value) ?bool {
    if (container != .object) return null;
    const sdd = container.object.get("sdd") orelse return null;
    if (sdd != .object) return null;
    const enabled = sdd.object.get("enabled") orelse return null;
    return if (enabled == .bool) enabled.bool else null;
}

fn parseSwitch(value: []const u8) ?bool {
    inline for (.{ "1", "on", "true" }) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return true;
    }
    inline for (.{ "0", "off", "false" }) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return false;
    }
    return null;
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn parseForTest(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
}

test "sdd is off without settings or environment" {
    const mode = resolve(null, "/repo", null);
    try std.testing.expect(!mode.enabled);
    try std.testing.expectEqual(Source.default, mode.source);
}

test "workspace setting overrides the profile default" {
    var parsed = try parseForTest(
        \\{"sdd":{"enabled":true},"workspaces":{"/repo":{"sdd":{"enabled":false}},"/other":{"model":"x"}}}
    );
    defer parsed.deinit();
    const repo = resolve(parsed.value, "/repo/", null);
    try std.testing.expect(!repo.enabled);
    try std.testing.expectEqual(Source.workspace, repo.source);
    const other = resolve(parsed.value, "/other", null);
    try std.testing.expect(other.enabled);
    try std.testing.expectEqual(Source.profile, other.source);
}

test "FX_SDD overrides settings and ignores unknown values" {
    var parsed = try parseForTest(
        \\{"workspaces":{"/repo":{"sdd":{"enabled":true}}}}
    );
    defer parsed.deinit();
    const off = resolve(parsed.value, "/repo", " off\n");
    try std.testing.expect(!off.enabled);
    try std.testing.expectEqual(Source.environment, off.source);
    const unknown = resolve(parsed.value, "/repo", "maybe");
    try std.testing.expect(unknown.enabled);
    try std.testing.expectEqual(Source.workspace, unknown.source);
}

test "tdd mode and test command resolve workspace first" {
    var parsed = try parseForTest(
        \\{"sdd":{"tdd":"strict","test":"make test"},"workspaces":{"/repo":{"sdd":{"enabled":true,"tdd":"on"}},"/other":{"sdd":{"tdd":"sometimes"}}}}
    );
    defer parsed.deinit();
    const repo = resolve(parsed.value, "/repo", "off");
    try std.testing.expect(!repo.enabled);
    try std.testing.expectEqual(Tdd.on, repo.tdd);
    try std.testing.expectEqualStrings("make test", repo.testCommand().?);
    const other = resolve(parsed.value, "/other", null);
    try std.testing.expectEqual(Tdd.off, other.tdd);
    try std.testing.expect(resolve(null, "/repo", null).testCommand() == null);
    try std.testing.expectEqual(Tdd.off, resolve(null, "/repo", null).tdd);
}

test "mistyped sdd settings fall back to the next layer" {
    var parsed = try parseForTest(
        \\{"sdd":{"enabled":"yes"},"workspaces":{"/repo":{"sdd":true}}}
    );
    defer parsed.deinit();
    const mode = resolve(parsed.value, "/repo", null);
    try std.testing.expect(!mode.enabled);
    try std.testing.expectEqual(Source.default, mode.source);
}
