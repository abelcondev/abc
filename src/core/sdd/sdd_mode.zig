//! SDD mode: whether fx runs its spec-driven development process in a
//! workspace.
//!
//! Read only from the profile `~/.fx/settings.json`; a project `.fx.json`
//! cannot turn the process on. Precedence, highest first: `FX_SDD` (on/off),
//! `workspaces["<root>"].sdd.enabled`, top-level `sdd.enabled`, then off.
//!
//! ```json
//! "sdd": { "enabled": false },
//! "workspaces": { "/path/to/repo": { "sdd": { "enabled": true } } }
//! ```
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

pub const Mode = struct {
    enabled: bool = false,
    source: Source = .default,
};

/// Resolves the mode from parsed profile settings (null when absent or
/// unreadable) and the raw `FX_SDD` value.
pub fn resolve(settings: ?std.json.Value, workspace_root: []const u8, env: ?[]const u8) Mode {
    if (env) |raw| {
        if (parseSwitch(std.mem.trim(u8, raw, " \t\r\n"))) |enabled| return .{ .enabled = enabled, .source = .environment };
    }
    const root = settings orelse return .{};
    if (root != .object) return .{};
    if (root.object.get("workspaces")) |workspaces| {
        if (workspaces == .object) {
            if (workspaces.object.get(trimTrailingSlashes(workspace_root))) |workspace| {
                if (enabledField(workspace)) |enabled| return .{ .enabled = enabled, .source = .workspace };
            }
        }
    }
    if (enabledField(root)) |enabled| return .{ .enabled = enabled, .source = .profile };
    return .{};
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

test "mistyped sdd settings fall back to the next layer" {
    var parsed = try parseForTest(
        \\{"sdd":{"enabled":"yes"},"workspaces":{"/repo":{"sdd":true}}}
    );
    defer parsed.deinit();
    const mode = resolve(parsed.value, "/repo", null);
    try std.testing.expect(!mode.enabled);
    try std.testing.expectEqual(Source.default, mode.source);
}
