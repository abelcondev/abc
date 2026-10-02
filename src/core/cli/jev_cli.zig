//! `fx jev`: inspect and configure Jev decisions.
//!
//! `fx jev` prints the status, `on`/`off` persist `jev.enabled` in the
//! profile settings, `key` saves the TypeSafe API key, `forget` removes it,
//! and `check` makes one live call to confirm the key and endpoint work.

const std = @import("std");
const jev_config = @import("../decisions/jev_config.zig");
const jev_contract = @import("../decisions/jev_contract.zig");
const typesafe = @import("../../gateway/typesafe.zig");
const calibration = @import("../decisions/calibration.zig");
const drift_mod = @import("../decisions/drift.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum { status, on, off, key, forget, check, eval, drift };

pub const usage =
    \\usage: fx jev [on|off|key|forget|check]
    \\       fx jev eval [stop|plan|action|ask|routing|sdd|close|tdd|checkpoint|review]
    \\       fx jev drift [<git-range>] [--dir <decisions-dir>]
    \\
;

pub const Parsed = struct {
    action: Action,
    /// `eval` gate filter.
    gate: ?calibration.Gate = null,
};

pub const DriftOptions = struct {
    /// Passed to `git diff`; `HEAD` compares uncommitted changes.
    range: []const u8 = "HEAD",
    dir: ?[]const u8 = null,
};

/// Parses the arguments after `drift`.
pub fn parseDrift(rest: []const [:0]const u8) ?DriftOptions {
    var options = DriftOptions{};
    var range_set = false;
    var index: usize = 0;
    while (index < rest.len) : (index += 1) {
        const arg: []const u8 = rest[index];
        if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            if (index == rest.len) return null;
            options.dir = rest[index];
        } else if (std.mem.startsWith(u8, arg, "-") or range_set) {
            return null;
        } else {
            options.range = arg;
            range_set = true;
        }
    }
    return options;
}

/// Checks `git diff <range>` against the decision files and returns a
/// report. `flagged` receives the number of decisions that may be out of date.
/// Caller owns the text.
pub fn drift(alloc: Allocator, config: jev_config.Config, api_key: []const u8, options: DriftOptions, flagged: *usize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir_path = options.dir orelse drift_mod.findDir(std.Io.Dir.cwd()) orelse return error.NoDecisionsDirectory;
    const report = try drift_mod.check(arena, .{ .base_url = config.base_url, .api_key = api_key, .model = config.model }, ".", options.range, dir_path);
    if (report.decision_count == 0) return error.NoDecisions;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("Checked {d} decisions in {s} against `git diff {s}` ({d} bytes", .{ report.decision_count, report.dir, options.range, report.diff_bytes });
    if (report.diff_bytes > drift_mod.Limits.diff_bytes) try w.print(", first {d} sent", .{drift_mod.Limits.diff_bytes});
    try w.writeAll(").\n");
    if (report.diff_bytes == 0) {
        try w.writeAll("No code changes to check.\n");
        return out.toOwnedSlice();
    }
    if (report.findings.len == 0) {
        try w.writeAll("No decision covers the changed code.\n");
        return out.toOwnedSlice();
    }
    for (report.findings) |finding| {
        try w.print("  {s} {s} — {s}\n      {s} (contradicts p={d:.2}, touched p={d:.2})\n", .{
            if (finding.stale) "!" else "✓",
            finding.decision.file,
            finding.decision.title,
            if (finding.stale) "may be out of date" else "still matches",
            finding.contradiction,
            finding.touched,
        });
    }
    flagged.* = report.staleCount();
    if (flagged.* != 0) try w.print("\n{d} decision(s) may need updating.\n", .{flagged.*});
    return out.toOwnedSlice();
}

pub fn parseAction(rest: []const [:0]const u8) ?Parsed {
    if (rest.len == 0) return .{ .action = .status };
    const action = std.meta.stringToEnum(Action, rest[0]) orelse return null;
    if (action == .status or action == .drift) return null;
    if (action == .eval and rest.len == 2) {
        return .{ .action = .eval, .gate = calibration.parseGate(rest[1]) orelse return null };
    }
    if (rest.len != 1) return null;
    return .{ .action = action };
}

/// Runs the calibration cases and returns a report. Caller owns the text.
/// `failures` receives the number of cases that did not match.
pub fn evaluate(alloc: Allocator, config: jev_config.Config, api_key: []const u8, gate: ?calibration.Gate, failures: *usize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    var totals = std.EnumArray(calibration.Gate, [2]usize).initFill(.{ 0, 0 });
    var current: ?calibration.Gate = null;
    for (calibration.cases) |case| {
        if (gate) |only| if (case.gate != only) continue;
        if (current == null or current.? != case.gate) {
            current = case.gate;
            try w.print("\n{s}\n", .{@tagName(case.gate)});
        }
        const result = try calibration.run(arena, config, api_key, case);
        const total = totals.getPtr(case.gate);
        total[1] += 1;
        if (result.passed) total[0] += 1 else failures.* += 1;
        try w.print("  {s} {s}: {s}", .{ if (result.passed) "✓" else "✗", result.name, result.actual });
        if (!result.passed) try w.print(" (expected {s})", .{result.expect});
        if (result.answers.len != 0) try w.print("\n      {s}", .{result.answers});
        try w.writeByte('\n');
    }
    try w.writeAll("\nSummary:");
    inline for (@typeInfo(calibration.Gate).@"enum".fields) |field| {
        const total = totals.get(@field(calibration.Gate, field.name));
        if (total[1] != 0) try w.print(" {s} {d}/{d}", .{ field.name, total[0], total[1] });
    }
    try w.print(" (model {s})\n", .{config.model});
    return out.toOwnedSlice();
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
    var label: []const u8 = "gates     ";
    const indent = "          ";
    if (config.ask_gate) {
        try w.print("  {s}answer settled questions (threshold {d:.2})\n", .{ label, config.ask_threshold });
        label = indent;
    }
    if (config.plan_gate) {
        try w.print("  {s}plan before changes (threshold {d:.2})\n", .{ label, config.plan_threshold });
        label = indent;
    }
    if (config.sdd_gate) {
        try w.print("  {s}route file changes to fix, spec or change (with SDD on)\n", .{label});
        label = indent;
        try w.print("  {s}test-first behavior changes (with SDD on; Jev decides under `tdd auto`)\n", .{label});
    }
    if (config.checkpoint_gate) {
        try w.print("  {s}commit verified earlier work before separate new work (off the default branch)\n", .{label});
        label = indent;
    }
    if (config.review_gate) {
        try w.print("  {s}review before a risky or large pull request opens\n", .{label});
        label = indent;
    }
    if (config.drift_gate) {
        try w.print("  {s}spec rules after changes (with SDD on)\n", .{label});
        label = indent;
    }
    if (config.action_gate) {
        try w.print("  {s}action check (hold at damage {d:.2})\n", .{ label, config.action_threshold });
        label = indent;
    }
    if (config.stop_gate) {
        try w.print("  {s}completion check (threshold {d:.2})\n", .{ label, config.stop_threshold });
        label = indent;
    }
    if (label.ptr != indent.ptr) try w.writeAll("  gates     none\n");
    if (config.routes.len != 0) {
        try w.writeAll("  routing  ");
        for (config.routes, 0..) |route, index| {
            try w.print("{s} {s}={s}", .{ if (index == 0) "" else ",", route.name, route.model });
        }
        try w.writeByte('\n');
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
    try std.testing.expectEqual(Action.status, parseAction(&.{}).?.action);
    try std.testing.expectEqual(Action.on, parseAction(&.{"on"}).?.action);
    try std.testing.expectEqual(Action.check, parseAction(&.{"check"}).?.action);
    try std.testing.expectEqual(calibration.Gate.plan, parseAction(&.{ "eval", "plan" }).?.gate.?);
    try std.testing.expect(parseAction(&.{"eval"}).?.gate == null);
    try std.testing.expect(parseAction(&.{ "eval", "nope" }) == null);
    try std.testing.expect(parseAction(&.{"enable"}) == null);
    try std.testing.expect(parseAction(&.{"status"}) == null);
    try std.testing.expect(parseAction(&.{ "on", "now" }) == null);
}

test "parseDrift reads a range and a decisions directory" {
    const defaults = parseDrift(&.{}).?;
    try std.testing.expectEqualStrings("HEAD", defaults.range);
    try std.testing.expect(defaults.dir == null);
    const custom = parseDrift(&.{ "main...HEAD", "--dir", "docs/adr" }).?;
    try std.testing.expectEqualStrings("main...HEAD", custom.range);
    try std.testing.expectEqualStrings("docs/adr", custom.dir.?);
    try std.testing.expect(parseDrift(&.{"--dir"}) == null);
    try std.testing.expect(parseDrift(&.{ "a", "b" }) == null);
    try std.testing.expect(parseDrift(&.{"--json"}) == null);
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
    try std.testing.expect(std.mem.find(u8, on, "gates     answer settled questions (threshold 0.80)") != null);
    try std.testing.expect(std.mem.find(u8, on, "plan before changes (threshold 0.50)") != null);
    try std.testing.expect(std.mem.find(u8, on, "action check") == null);
    try std.testing.expect(std.mem.find(u8, on, "route file changes to fix, spec or change (with SDD on)") != null);
    try std.testing.expect(std.mem.find(u8, on, "test-first behavior changes") != null);
    try std.testing.expect(std.mem.find(u8, on, "completion check (threshold 0.60)") != null);
    try std.testing.expect(std.mem.find(u8, on, "fx jev on") == null);
}
