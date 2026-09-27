//! Profile configuration for Jev decisions.
//!
//! Read only from `~/.fx/settings.json` (the `jev` object); project `.fx.json`
//! files cannot enable or redirect Jev. Environment overrides: `FX_JEV`
//! (on/off), `FX_JEV_MODEL`, `FX_JEV_BASE_URL`. The API key comes from
//! `TYPESAFE_API_KEY` or the key saved with `fx jev key`.
//!
//! ```json
//! "jev": {
//!   "enabled": true,
//!   "model": "jev-latest",
//!   "gates": { "stop": true },
//!   "thresholds": { "stop": 0.5 }
//! }
//! ```

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const provider_keys = @import("../auth/provider_keys.zig");
const typesafe = @import("../../gateway/typesafe.zig");

const Allocator = std.mem.Allocator;

/// Saved-key id for `provider_keys` (Keychain service `FX_PROVIDER_KEY_typesafe`).
pub const key_id = "typesafe";
pub const key_env = "TYPESAFE_API_KEY";
pub const default_model = "jev-latest";

const max_settings_bytes = 4 * 1024 * 1024;

pub const Config = struct {
    enabled: bool = false,
    model: []const u8 = default_model,
    base_url: []const u8 = typesafe.default_base_url,
    /// Verify that a turn's claimed work is backed by evidence before it ends.
    stop_gate: bool = true,
    /// Minimum probability each completion check must reach.
    stop_threshold: f64 = 0.5,
    owned_model: ?[]u8 = null,
    owned_base_url: ?[]u8 = null,

    pub fn deinit(self: *Config, alloc: Allocator) void {
        if (self.owned_model) |value| alloc.free(value);
        if (self.owned_base_url) |value| alloc.free(value);
        self.* = .{};
    }

    fn setModel(self: *Config, alloc: Allocator, value: []const u8) !void {
        const owned = try alloc.dupe(u8, value);
        if (self.owned_model) |old| alloc.free(old);
        self.owned_model = owned;
        self.model = owned;
    }

    fn setBaseUrl(self: *Config, alloc: Allocator, value: []const u8) !void {
        const owned = try alloc.dupe(u8, value);
        if (self.owned_base_url) |old| alloc.free(old);
        self.owned_base_url = owned;
        self.base_url = owned;
    }
};

/// Applies a `jev` settings object. Unknown or mistyped fields keep defaults.
pub fn applyJson(alloc: Allocator, config: *Config, value: std.json.Value) !void {
    if (value != .object) return;
    const object = value.object;
    if (object.get("enabled")) |enabled| {
        if (enabled == .bool) config.enabled = enabled.bool;
    }
    if (object.get("model")) |model| {
        if (model == .string and validText(model.string)) try config.setModel(alloc, model.string);
    }
    if (object.get("base_url")) |base_url| {
        if (base_url == .string and validBaseUrl(base_url.string)) try config.setBaseUrl(alloc, base_url.string);
    }
    if (object.get("gates")) |gates| {
        if (gates == .object) {
            if (gates.object.get("stop")) |stop| {
                if (stop == .bool) config.stop_gate = stop.bool;
            }
        }
    }
    if (object.get("thresholds")) |thresholds| {
        if (thresholds == .object) {
            if (thresholds.object.get("stop")) |stop| {
                if (threshold(stop)) |parsed| config.stop_threshold = parsed;
            }
        }
    }
}

fn threshold(value: std.json.Value) ?f64 {
    const parsed: f64 = switch (value) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => return null,
    };
    return if (parsed > 0 and parsed < 1) parsed else null;
}

fn validText(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return false;
    return true;
}

/// HTTPS only, except plain HTTP to the local machine for tests and proxies.
fn validBaseUrl(value: []const u8) bool {
    if (!validText(value)) return false;
    if (std.mem.startsWith(u8, value, "https://")) return true;
    inline for (.{ "http://127.0.0.1:", "http://localhost:", "http://[::1]:" }) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) return true;
    }
    return false;
}

/// Applies `FX_JEV`, `FX_JEV_MODEL` and `FX_JEV_BASE_URL`.
pub fn applyEnvironment(alloc: Allocator, config: *Config, getenv: *const fn ([]const u8) ?[]const u8) !void {
    if (getenv("FX_JEV")) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (isOn(value)) config.enabled = true else if (isOff(value)) config.enabled = false;
    }
    if (getenv("FX_JEV_MODEL")) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (validText(value)) try config.setModel(alloc, value);
    }
    if (getenv("FX_JEV_BASE_URL")) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (validBaseUrl(value)) try config.setBaseUrl(alloc, value);
    }
}

fn isOn(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "on") or std.ascii.eqlIgnoreCase(value, "true");
}

fn isOff(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "0") or std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "false");
}

/// Loads the profile `jev` settings plus environment overrides. A missing or
/// unreadable settings file yields defaults (Jev disabled).
pub fn load(alloc: Allocator) !Config {
    var config = Config{};
    errdefer config.deinit(alloc);
    if (io_mod.getenv("HOME")) |home| {
        if (readSettings(alloc, home)) |bytes| {
            defer alloc.free(bytes);
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch null;
            if (parsed) |*document| {
                defer document.deinit();
                if (document.value == .object) {
                    if (document.value.object.get("jev")) |value| try applyJson(alloc, &config, value);
                }
            }
        }
    }
    try applyEnvironment(alloc, &config, io_mod.getenv);
    return config;
}

fn readSettings(alloc: Allocator, home: []const u8) ?[]u8 {
    const path = profile_paths.settingsPath(alloc, home) catch return null;
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(max_settings_bytes)) catch null;
}

pub const KeySource = enum { environment, saved };

pub const ApiKey = struct {
    value: []u8,
    source: KeySource,

    pub fn deinit(self: *ApiKey, alloc: Allocator) void {
        std.crypto.secureZero(u8, self.value);
        alloc.free(self.value);
        self.* = undefined;
    }
};

/// The Jev API key, or null when none is exported or saved.
pub fn loadApiKey(alloc: Allocator) !?ApiKey {
    if (io_mod.getenv(key_env)) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len != 0) return .{ .value = try alloc.dupe(u8, value), .source = .environment };
    }
    const saved = provider_keys.load(alloc, key_id) catch return null;
    return if (saved) |value| .{ .value = value, .source = .saved } else null;
}

test "applyJson reads the jev settings object and ignores invalid fields" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"enabled":true,"model":"jev-1.13.0","base_url":"http://insecure","gates":{"stop":false},"thresholds":{"stop":0.7}}
    , .{});
    defer parsed.deinit();
    var config = Config{};
    defer config.deinit(alloc);
    try applyJson(alloc, &config, parsed.value);
    try std.testing.expect(config.enabled);
    try std.testing.expectEqualStrings("jev-1.13.0", config.model);
    try std.testing.expectEqualStrings(typesafe.default_base_url, config.base_url);
    try std.testing.expect(!config.stop_gate);
    try std.testing.expectEqual(@as(f64, 0.7), config.stop_threshold);

    var bad = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"enabled":"yes","model":"has space","thresholds":{"stop":1.5}}
    , .{});
    defer bad.deinit();
    var defaults = Config{};
    defer defaults.deinit(alloc);
    try applyJson(alloc, &defaults, bad.value);
    try std.testing.expect(!defaults.enabled);
    try std.testing.expectEqualStrings(default_model, defaults.model);
    try std.testing.expectEqual(@as(f64, 0.5), defaults.stop_threshold);
}

test "applyEnvironment overrides enabled, model and base url" {
    const alloc = std.testing.allocator;
    const Env = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "FX_JEV")) return " on ";
            if (std.mem.eql(u8, key, "FX_JEV_MODEL")) return "jev-preview";
            if (std.mem.eql(u8, key, "FX_JEV_BASE_URL")) return "https://jev.example";
            return null;
        }
    };
    var config = Config{};
    defer config.deinit(alloc);
    try applyEnvironment(alloc, &config, Env.get);
    try std.testing.expect(config.enabled);
    try std.testing.expectEqualStrings("jev-preview", config.model);
    try std.testing.expectEqualStrings("https://jev.example", config.base_url);
}

test "validBaseUrl accepts HTTPS and local HTTP only" {
    try std.testing.expect(validBaseUrl("https://api.typesafe.ai"));
    try std.testing.expect(validBaseUrl("http://127.0.0.1:8787"));
    try std.testing.expect(!validBaseUrl("http://api.typesafe.ai"));
    try std.testing.expect(!validBaseUrl("http://127.0.0.1.evil.com"));
}
