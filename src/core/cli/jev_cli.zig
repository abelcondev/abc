//! `fx jev`: inspect and configure Jev decisions.
//!
//! `fx jev` prints the status, `on`/`off` persist `jev.enabled` in the
//! profile settings, `key` saves the TypeSafe API key, `forget` removes it,
//! and `check` makes one live call to confirm the key and endpoint work.

const std = @import("std");
const jev_config = @import("../decisions/jev_config.zig");
const jev_contract = @import("../decisions/jev_contract.zig");
const typesafe = @import("../../gateway/typesafe.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum { status, on, off, key, forget, check };

pub const usage = "usage: fx jev [on|off|key|forget|check]\n";

pub fn parseAction(rest: []const [:0]const u8) ?Action {
    if (rest.len == 0) return .status;
    if (rest.len != 1) return null;
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        if (std.mem.eql(u8, rest[0], field.name)) return @field(Action, field.name);
    }
    return null;
}

pub const KeyStatus = union(enum) {
    missing,
    environment,
    saved: []const u8,
};

/// Caller owns the returned text.
/// `enable_command` is how the reader turns Jev on (`fx jev on` or `/jev on`).
pub fn renderStatus(alloc: Allocator, config: jev_config.Config, key: KeyStatus, enable_command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("Jev decisions: {s}\n", .{if (config.enabled) "on" else "off"});
    try w.print("  model     {s}\n", .{config.model});
    try w.print("  endpoint  {s}\n", .{config.base_url});
    switch (key) {
        .missing => try w.writeAll("  key       missing (run `fx jev key` or export " ++ jev_config.key_env ++ ")\n"),
        .environment => try w.writeAll("  key       " ++ jev_config.key_env ++ "\n"),
        .saved => |backend| try w.print("  key       saved in the {s}\n", .{backend}),
    }
    if (!config.plan_gate and !config.stop_gate) try w.writeAll("  gates     none\n");
    if (config.plan_gate) try w.print("  gates     plan before changes (threshold {d:.2})\n", .{config.plan_threshold});
    if (config.stop_gate) {
        try w.print("  {s}completion check (threshold {d:.2})\n", .{ if (config.plan_gate) "          " else "gates     ", config.stop_threshold });
    }
    try w.writeAll("  log       ~/.fx/sessions/<id>/decisions.jsonl\n");
    if (!config.enabled) try w.print("\nTurn it on with `{s}`.\n", .{enable_command});
    return out.toOwnedSlice();
}

const check_questions = [_]jev_contract.Question{.{
    .id = "greeting",
    .instructions = "`message` is a greeting",
    .kind = .noul,
}};

/// One live call with a fixed question. Caller owns the returned summary.
pub fn check(alloc: Allocator, config: jev_config.Config, api_key: []const u8) ![]u8 {
    var response = try typesafe.systemOne(alloc, .{
        .base_url = config.base_url,
        .api_key = api_key,
        .model = config.model,
        .state_json = "{\"message\":\"hello there\"}",
        .questions = &check_questions,
    });
    defer response.deinit();
    const answer = response.noul("greeting") orelse return error.IncompleteJevAnswer;
    return std.fmt.allocPrint(alloc, "Jev answered ({s}, {d} input tokens, greeting={d:.2}).\n", .{ response.model, response.input_tokens, answer });
}

test "parseAction accepts the documented subcommands" {
    try std.testing.expectEqual(Action.status, parseAction(&.{}).?);
    try std.testing.expectEqual(Action.on, parseAction(&.{"on"}).?);
    try std.testing.expectEqual(Action.check, parseAction(&.{"check"}).?);
    try std.testing.expect(parseAction(&.{"enable"}) == null);
    try std.testing.expect(parseAction(&.{ "on", "now" }) == null);
}

test "renderStatus reports configuration without the key value" {
    const alloc = std.testing.allocator;
    const off = try renderStatus(alloc, .{}, .missing, "fx jev on");
    defer alloc.free(off);
    try std.testing.expect(std.mem.startsWith(u8, off, "Jev decisions: off\n"));
    try std.testing.expect(std.mem.find(u8, off, "fx jev key") != null);
    try std.testing.expect(std.mem.find(u8, off, "fx jev on") != null);

    const on = try renderStatus(alloc, .{ .enabled = true, .stop_threshold = 0.6 }, .{ .saved = "macOS Keychain" }, "fx jev on");
    defer alloc.free(on);
    try std.testing.expect(std.mem.find(u8, on, "saved in the macOS Keychain") != null);
    try std.testing.expect(std.mem.find(u8, on, "plan before changes (threshold 0.50)") != null);
    try std.testing.expect(std.mem.find(u8, on, "completion check (threshold 0.60)") != null);
    try std.testing.expect(std.mem.find(u8, on, "fx jev on") == null);
}
