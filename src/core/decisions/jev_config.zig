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
//!   "gates": { "plan": true, "stop": true, "ask": true, "drift": true, "sdd": true, "action": false },
//!   "thresholds": { "plan": 0.5, "stop": 0.5, "ask": 0.8, "action": 0.6 },
//!   "routing": {
//!     "light": { "model": "deepseek-flash", "effort": "low" },
//!     "heavy": { "model": "qwen3.8-max", "description": "hard reasoning or design" }
//!   }
//! }
//! ```

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const provider_keys = @import("../auth/provider_keys.zig");
const typesafe = @import("../../gateway/typesafe.zig");
const routing = @import("routing.zig");

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
    /// Require a plan before the first file change of a substantial request.
    plan_gate: bool = true,
    /// Minimum probability the plan checks must reach.
    plan_threshold: f64 = 0.5,
    /// Verify that a turn's claimed work is backed by evidence before it ends.
    stop_gate: bool = true,
    /// Minimum probability each completion check must reach.
    stop_threshold: f64 = 0.5,
    /// Let Jev answer the agent's multiple-choice questions it can settle.
    ask_gate: bool = true,
    /// Minimum confidence and grounding for answering on the user's behalf.
    ask_threshold: f64 = 0.8,
    /// After a turn that changed files, flag decision records the uncommitted
    /// changes contradict (only in workspaces with a decisions directory and
    /// SDD on).
    drift_gate: bool = true,
    /// With SDD on, route the first file change of a turn to fix, spec or
    /// change (`sdd_gate.zig`).
    sdd_gate: bool = true,
    /// Commit uncommitted, verified work from earlier turns before a new
    /// request starts separate work (`checkpoint.zig`).
    checkpoint_gate: bool = true,
    /// Before the agent opens a pull request, rate the branch's risk and
    /// ask for a review when it is high or large (`pr_review.zig`).
    review_gate: bool = true,
    /// After a turn that changed how a UI looks, ask for an Iris screenshot
    /// (`visual_check.zig`).
    visual_gate: bool = true,
    /// Vision model for a subagent that reads the screenshot when the
    /// session's model cannot (`jev.visual.model`).
    visual_model: ?[]const u8 = null,
    /// Check file changes and shell commands against the request.
    action_gate: bool = false,
    /// Probability of unrequested damage at which an action is held.
    action_threshold: f64 = 0.6,
    /// Subagent model routes; empty disables routing. Owned.
    routes: []routing.Route = &.{},
    owned_model: ?[]u8 = null,
    owned_base_url: ?[]u8 = null,
    owned_visual_model: ?[]u8 = null,

    pub fn deinit(self: *Config, alloc: Allocator) void {
        if (self.owned_visual_model) |value| alloc.free(value);
        if (self.owned_model) |value| alloc.free(value);
        if (self.owned_base_url) |value| alloc.free(value);
        freeRoutes(alloc, self.routes);
        self.* = .{};
    }

    /// Whether any gate needs the PreToolUse hook.
    pub fn usesPreToolUse(self: Config) bool {
        return self.plan_gate or self.ask_gate or self.action_gate or self.sdd_gate or self.checkpoint_gate or self.review_gate or self.routes.len != 0;
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
            if (gates.object.get("plan")) |plan| {
                if (plan == .bool) config.plan_gate = plan.bool;
            }
            if (gates.object.get("ask")) |ask| {
                if (ask == .bool) config.ask_gate = ask.bool;
            }
            if (gates.object.get("action")) |action| {
                if (action == .bool) config.action_gate = action.bool;
            }
            if (gates.object.get("drift")) |drift| {
                if (drift == .bool) config.drift_gate = drift.bool;
            }
            if (gates.object.get("sdd")) |sdd| {
                if (sdd == .bool) config.sdd_gate = sdd.bool;
            }
            if (gates.object.get("checkpoint")) |checkpoint_value| {
                if (checkpoint_value == .bool) config.checkpoint_gate = checkpoint_value.bool;
            }
            if (gates.object.get("review")) |review| {
                if (review == .bool) config.review_gate = review.bool;
            }
            if (gates.object.get("visual")) |visual| {
                if (visual == .bool) config.visual_gate = visual.bool;
            }
        }
    }
    if (object.get("thresholds")) |thresholds| {
        if (thresholds == .object) {
            if (thresholds.object.get("stop")) |stop| {
                if (threshold(stop)) |parsed| config.stop_threshold = parsed;
            }
            if (thresholds.object.get("plan")) |plan| {
                if (threshold(plan)) |parsed| config.plan_threshold = parsed;
            }
            if (thresholds.object.get("ask")) |ask| {
                if (threshold(ask)) |parsed| config.ask_threshold = parsed;
            }
            if (thresholds.object.get("action")) |action| {
                if (threshold(action)) |parsed| config.action_threshold = parsed;
            }
        }
    }
    if (object.get("visual")) |visual| {
        if (visual == .object) {
            if (visual.object.get("model")) |model| {
                if (model == .string and validText(model.string)) {
                    const owned = try alloc.dupe(u8, model.string);
                    if (config.owned_visual_model) |old| alloc.free(old);
                    config.owned_visual_model = owned;
                    config.visual_model = owned;
                }
            }
        }
    }
    if (object.get("routing")) |routes_value| {
        const routes = try parseRoutes(alloc, routes_value);
        freeRoutes(alloc, config.routes);
        config.routes = routes;
    }
}

fn freeRouteStrings(alloc: Allocator, route: routing.Route) void {
    alloc.free(route.name);
    alloc.free(route.model);
    if (route.effort) |effort| alloc.free(effort);
    alloc.free(route.description);
}

/// Frees a slice returned by `parseRoutes`.
fn freeRoutes(alloc: Allocator, routes: []routing.Route) void {
    for (routes) |route| freeRouteStrings(alloc, route);
    if (routes.len != 0) alloc.free(routes);
}

fn freeRouteList(alloc: Allocator, list: *std.ArrayList(routing.Route)) void {
    for (list.items) |route| freeRouteStrings(alloc, route);
    list.deinit(alloc);
}

/// Parses `routing`; entries without a model, or without a description for
/// a non-standard name, are skipped.
fn parseRoutes(alloc: Allocator, value: std.json.Value) ![]routing.Route {
    if (value != .object) return &.{};
    var list: std.ArrayList(routing.Route) = .empty;
    errdefer freeRouteList(alloc, &list);
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (list.items.len == routing.max_routes) break;
        const name = entry.key_ptr.*;
        if (!validText(name) or entry.value_ptr.* != .object) continue;
        const object = entry.value_ptr.object;
        const model = stringField(object, "model") orelse continue;
        if (!validText(model)) continue;
        const effort = stringField(object, "effort");
        if (effort) |text| if (!validText(text)) continue;
        const description = stringField(object, "description") orelse routing.defaultDescription(name) orelse continue;
        if (description.len == 0 or description.len > 512) continue;
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const owned_model = try alloc.dupe(u8, model);
        errdefer alloc.free(owned_model);
        const owned_effort = if (effort) |text| try alloc.dupe(u8, text) else null;
        errdefer if (owned_effort) |text| alloc.free(text);
        const owned_description = try alloc.dupe(u8, description);
        errdefer alloc.free(owned_description);
        try list.append(alloc, .{ .name = owned_name, .model = owned_model, .effort = owned_effort, .description = owned_description });
    }
    // A single route leaves Jev nothing to choose.
    if (list.items.len < 2) {
        freeRouteList(alloc, &list);
        return &.{};
    }
    return list.toOwnedSlice(alloc);
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
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
        \\{"enabled":true,"model":"jev-1.13.0","base_url":"http://insecure","gates":{"stop":false,"plan":false},"thresholds":{"stop":0.7,"plan":0.6}}
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
    try std.testing.expect(!config.plan_gate);
    try std.testing.expectEqual(@as(f64, 0.6), config.plan_threshold);

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

test "applyJson reads routes and the ask and action gates" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"gates":{"ask":false,"action":true,"drift":false},"thresholds":{"ask":0.9,"action":0.7},"routing":{"light":{"model":"deepseek-flash","effort":"low"},"heavy":{"model":"qwen3.8-max"},"odd":{"model":"x"},"broken":{"effort":"low"}}}
    , .{});
    defer parsed.deinit();
    var config = Config{};
    defer config.deinit(alloc);
    try applyJson(alloc, &config, parsed.value);
    try std.testing.expect(!config.ask_gate and config.action_gate and !config.drift_gate);
    try std.testing.expectEqual(@as(f64, 0.9), config.ask_threshold);
    try std.testing.expectEqual(@as(f64, 0.7), config.action_threshold);
    try std.testing.expectEqual(@as(usize, 2), config.routes.len);
    try std.testing.expectEqualStrings("light", config.routes[0].name);
    try std.testing.expectEqualStrings("low", config.routes[0].effort.?);
    try std.testing.expect(std.mem.find(u8, config.routes[1].description, "reasoning") != null);
    try std.testing.expect(config.usesPreToolUse());

    var single = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"routing":{"light":{"model":"deepseek-flash"}}}
    , .{});
    defer single.deinit();
    var one = Config{};
    defer one.deinit(alloc);
    try applyJson(alloc, &one, single.value);
    try std.testing.expectEqual(@as(usize, 0), one.routes.len);
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
