//! `fx sdd`: show or switch the spec-driven development process for the
//! current workspace.
//!
//! `fx sdd` prints the status; `on`/`off` persist
//! `workspaces["<root>"].sdd.enabled` in the profile settings. `/sdd` in a
//! session renders the same status and saves the same setting.

const std = @import("std");
const sdd_mode = @import("../sdd/sdd_mode.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum { status, on, off };

pub const usage = "usage: fx sdd [on|off]\n";

pub fn parseAction(rest: []const [:0]const u8) ?Action {
    if (rest.len == 0) return .status;
    if (rest.len != 1) return null;
    const action = std.meta.stringToEnum(Action, rest[0]) orelse return null;
    return if (action == .status) null else action;
}

/// What the status reports next to the mode.
pub const StatusContext = struct {
    workspace_root: []const u8,
    /// Decisions directory found in the workspace, if any.
    records_dir: ?[]const u8,
    jev_enabled: bool,
    drift_gate: bool,
    /// How the reader turns SDD on (`fx sdd on` or `/sdd on`).
    enable_command: []const u8,
};

/// Caller owns the returned text.
pub fn renderStatus(alloc: Allocator, mode: sdd_mode.Mode, context: StatusContext) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("SDD: {s} ({s})\n", .{ if (mode.enabled) "on" else "off", mode.source.label() });
    try w.print("  workspace  {s}\n", .{context.workspace_root});
    if (context.records_dir) |dir| {
        try w.print("  records    {s}\n", .{dir});
    } else {
        try w.writeAll("  records    none found (sdd/decisions, docs/decisions, docs/adr, decisions)\n");
    }
    const checks: []const u8 = if (!mode.enabled)
        "none while SDD is off"
    else if (!context.jev_enabled)
        "none; Jev is off (run `fx jev on`)"
    else if (!context.drift_gate)
        "none; the Jev drift gate is off"
    else if (context.records_dir == null)
        "none until the workspace has decision records"
    else
        "decision records after file changes";
    try w.print("  checks     {s}\n", .{checks});
    if (mode.source == .environment) {
        try w.writeAll("\n" ++ sdd_mode.env_name ++ " overrides the saved setting in this shell.\n");
    } else if (!mode.enabled) {
        try w.print("\nTurn it on with `{s}`.\n", .{context.enable_command});
    }
    return out.toOwnedSlice();
}

/// Confirmation after saving the workspace setting. `effective` is the mode
/// once the setting is saved, which `FX_SDD` may still override.
pub fn savedMessage(enabled: bool, effective: sdd_mode.Mode) []const u8 {
    if (effective.source == .environment and effective.enabled != enabled) {
        return if (enabled)
            "SDD is on for this workspace, but " ++ sdd_mode.env_name ++ " keeps it off in this shell.\n"
        else
            "SDD is off for this workspace, but " ++ sdd_mode.env_name ++ " keeps it on in this shell.\n";
    }
    return if (enabled) "SDD is on for this workspace.\n" else "SDD is off for this workspace.\n";
}

test "parseAction accepts status, on and off" {
    try std.testing.expectEqual(Action.status, parseAction(&.{}).?);
    try std.testing.expectEqual(Action.on, parseAction(&.{"on"}).?);
    try std.testing.expectEqual(Action.off, parseAction(&.{"off"}).?);
    try std.testing.expect(parseAction(&.{"status"}) == null);
    try std.testing.expect(parseAction(&.{"enable"}) == null);
    try std.testing.expect(parseAction(&.{ "on", "now" }) == null);
}

test "renderStatus explains why no checks run" {
    const alloc = std.testing.allocator;
    const context = StatusContext{
        .workspace_root = "/repo",
        .records_dir = "sdd/decisions",
        .jev_enabled = false,
        .drift_gate = true,
        .enable_command = "fx sdd on",
    };
    const off = try renderStatus(alloc, .{}, context);
    defer alloc.free(off);
    try std.testing.expect(std.mem.startsWith(u8, off, "SDD: off (default)\n"));
    try std.testing.expect(std.mem.find(u8, off, "none while SDD is off") != null);
    try std.testing.expect(std.mem.find(u8, off, "Turn it on with `fx sdd on`.") != null);

    const no_jev = try renderStatus(alloc, .{ .enabled = true, .source = .workspace }, context);
    defer alloc.free(no_jev);
    try std.testing.expect(std.mem.find(u8, no_jev, "Jev is off") != null);
    try std.testing.expect(std.mem.find(u8, no_jev, "Turn it on") == null);

    var live = context;
    live.jev_enabled = true;
    const on = try renderStatus(alloc, .{ .enabled = true, .source = .environment }, live);
    defer alloc.free(on);
    try std.testing.expect(std.mem.find(u8, on, "decision records after file changes") != null);
    try std.testing.expect(std.mem.find(u8, on, "FX_SDD overrides") != null);
}

test "savedMessage warns when FX_SDD disagrees" {
    try std.testing.expectEqualStrings("SDD is on for this workspace.\n", savedMessage(true, .{ .enabled = true, .source = .workspace }));
    try std.testing.expect(std.mem.find(u8, savedMessage(true, .{ .enabled = false, .source = .environment }), "keeps it off") != null);
}
