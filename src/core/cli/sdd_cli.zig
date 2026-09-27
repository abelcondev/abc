//! `fx sdd`: the spec-driven development process for the current workspace.
//!
//! `fx sdd` prints the status; `on`/`off` persist
//! `workspaces["<root>"].sdd.enabled` in the profile settings; `new <slug>`
//! writes `sdd/changes/<date>-<slug>.md`; `approve` and `done` set a change's
//! status; `tdd off|on|strict` saves `workspaces["<root>"].sdd.tdd`. `/sdd`
//! in a session accepts the same subcommands.

const std = @import("std");
const sdd_mode = @import("../sdd/sdd_mode.zig");
const sdd_layout = @import("../sdd/sdd_layout.zig");
const jev_config = @import("../decisions/jev_config.zig");
const drift = @import("../decisions/drift.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum { status, on, off, new, approve, done, tdd };

pub const usage = "usage: fx sdd [on|off|new <slug>|approve [<change>]|done [<change>]|tdd off|on|strict]\n";
pub const slash_usage = "usage: /sdd [on|off|new <slug>|approve [<change>]|done [<change>]|tdd off|on|strict]";

pub const Parsed = struct {
    action: Action,
    /// Slug for `new`, change name for `approve` and `done`, mode for `tdd`.
    name: ?[]const u8 = null,
};

pub fn parseWords(words: []const []const u8) ?Parsed {
    if (words.len == 0) return .{ .action = .status };
    const action = std.meta.stringToEnum(Action, words[0]) orelse return null;
    switch (action) {
        .status => return null,
        .on, .off => return if (words.len == 1) .{ .action = action } else null,
        .new => return if (words.len == 2) .{ .action = .new, .name = words[1] } else null,
        .tdd => {
            if (words.len != 2 or std.meta.stringToEnum(sdd_mode.Tdd, words[1]) == null) return null;
            return .{ .action = .tdd, .name = words[1] };
        },
        .approve, .done => return switch (words.len) {
            1 => .{ .action = action },
            2 => .{ .action = action, .name = words[1] },
            else => null,
        },
    }
}

pub fn parseAction(rest: []const [:0]const u8) ?Parsed {
    var words: [3][]const u8 = undefined;
    if (rest.len > words.len) return null;
    for (rest, 0..) |arg, index| words[index] = arg;
    return parseWords(words[0..rest.len]);
}

/// Parses `/sdd` payload text.
pub fn parseSlash(text: []const u8) ?Parsed {
    var words: [3][]const u8 = undefined;
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " \t");
    while (tokens.next()) |token| {
        if (count == words.len) return null;
        words[count] = token;
        count += 1;
    }
    return parseWords(words[0..count]);
}

/// What the status reports next to the mode.
pub const StatusContext = struct {
    workspace_root: []const u8,
    /// Decisions directory found in the workspace, if any.
    records_dir: ?[]const u8,
    jev_enabled: bool,
    drift_gate: bool,
    sdd_gate: bool = true,
    spec_count: usize = 0,
    rule_count: usize = 0,
    changes: []const sdd_layout.Change = &.{},
    /// Rules cited by a `spec: <spec> › <rule>` line somewhere in the repo.
    cited_rules: usize = 0,
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
    try w.print("  specs      {d} file(s), {d} rule(s) in " ++ sdd_layout.specs_dir ++ "\n", .{ context.spec_count, context.rule_count });
    if (context.records_dir) |dir| {
        if (!std.mem.eql(u8, dir, sdd_layout.specs_dir)) try w.print("  records    {s}\n", .{dir});
    }
    var active: usize = 0;
    for (context.changes) |change| {
        if (change.status == .done) continue;
        active += 1;
        try w.print("  {s}{s} {s} ({s}, tasks {d}/{d})\n", .{
            if (active == 1) "changes    " else "           ",
            if (change.status == .approved) "▸" else "·",
            change.file,
            if (change.status) |status| @tagName(status) else "no status",
            change.tasks_done,
            change.tasks_total,
        });
    }
    if (active == 0) try w.writeAll("  changes    none open\n");
    try w.print("  tdd        {s}", .{@tagName(mode.tdd)});
    if (mode.tdd != .off) {
        if (mode.testCommand()) |command| try w.print(" (tests: {s} or a common runner)", .{command}) else try w.writeAll(" (tests: common runners)");
    }
    try w.writeByte('\n');
    if (context.rule_count != 0) try w.print("  coverage   {d}/{d} rule(s) cited by a test (`spec: <spec> › <rule>`)\n", .{ context.cited_rules, context.rule_count });

    try w.writeAll("  checks     ");
    if (!mode.enabled) {
        try w.writeAll("none while SDD is off\n");
    } else if (!context.jev_enabled) {
        try w.writeAll("none; Jev is off (run `fx jev on`)\n");
    } else {
        var any = false;
        if (context.sdd_gate) {
            try w.writeAll("route the first file change to fix, spec or change\n");
            any = true;
        }
        if (context.drift_gate and context.records_dir != null) {
            if (any) try w.writeAll("             ");
            try w.writeAll("rules the turn's changes contradict\n");
            any = true;
        }
        if (context.sdd_gate and mode.tdd != .off) {
            if (any) try w.writeAll("             ");
            try w.writeAll(if (mode.tdd == .strict) "test-first behavior changes; every changed rule cited by a test\n" else "test-first behavior changes and bug fixes\n");
            any = true;
        }
        if (!any) try w.writeAll("none; the Jev sdd and drift gates are off\n");
    }
    if (mode.source == .environment) {
        try w.writeAll("\n" ++ sdd_mode.env_name ++ " overrides the saved setting in this shell.\n");
    } else if (!mode.enabled) {
        try w.print("\nTurn it on with `{s}`.\n", .{context.enable_command});
    }
    return out.toOwnedSlice();
}

/// Loads everything the status reports for `workspace_root` and renders
/// it. Caller owns the returned text.
pub fn statusFor(alloc: Allocator, workspace_root: []const u8, enable_command: []const u8) ![]u8 {
    var config = try jev_config.load(alloc);
    defer config.deinit(alloc);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = io_mod.getIo();
    var context = StatusContext{
        .workspace_root = workspace_root,
        .records_dir = null,
        .jev_enabled = config.enabled,
        .drift_gate = config.drift_gate,
        .sdd_gate = config.sdd_gate,
        .enable_command = enable_command,
    };
    if (std.Io.Dir.cwd().openDir(io, workspace_root, .{})) |root_value| {
        var root = root_value;
        defer root.close(io);
        context.records_dir = drift.findDir(root);
        context.spec_count = try sdd_layout.countSpecs(arena, root);
        context.rule_count = (try sdd_layout.listRules(arena, root)).len;
        context.changes = try sdd_layout.listChanges(arena, root);
        const rules = try sdd_layout.listRules(arena, root);
        const citations = citationLines(arena, workspace_root);
        for (rules) |rule| {
            if (std.mem.find(u8, citations, rule.title) != null) context.cited_rules += 1;
        }
    } else |_| {}
    return renderStatus(alloc, sdd_mode.load(alloc, workspace_root), context);
}

fn citationLines(arena: Allocator, workspace_root: []const u8) []const u8 {
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = &.{ "git", "grep", "-h", "-I", "-F", "-e", "spec:", "--", ".", ":(exclude)" ++ sdd_layout.root_dir },
        .cwd = .{ .path = workspace_root },
    }) catch return "";
    return result.stdout;
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

pub const Outcome = struct {
    /// Owned by the caller.
    text: []u8,
    ok: bool,
};

/// Runs `new`, `approve` or `done` in the workspace at `root`.
pub fn applyChangeAction(alloc: Allocator, root: std.Io.Dir, parsed: Parsed) !Outcome {
    switch (parsed.action) {
        .new => {
            var date_buf: [10]u8 = undefined;
            const path = sdd_layout.newChange(alloc, root, parsed.name.?, sdd_layout.today(&date_buf)) catch |err| return switch (err) {
                error.InvalidSlug => .{ .ok = false, .text = try alloc.dupe(u8, "The slug must be lowercase words joined by hyphens, for example pagos-parciales.\n") },
                error.ChangeExists => .{ .ok = false, .text = try std.fmt.allocPrint(alloc, "A change named {s} already exists today.\n", .{parsed.name.?}) },
                else => err,
            };
            defer alloc.free(path);
            return .{ .ok = true, .text = try std.fmt.allocPrint(alloc, "Created {s} (proposed). Fill in Why, What and Tasks, then approve it.\n", .{path}) };
        },
        .approve, .done => {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const changes = try sdd_layout.listChanges(arena_state.allocator(), root);
            const from: sdd_layout.Status = if (parsed.action == .approve) .proposed else .approved;
            const to: sdd_layout.Status = if (parsed.action == .approve) .approved else .done;
            switch (sdd_layout.pick(changes, parsed.name, from)) {
                .found => |change| {
                    try sdd_layout.setStatus(alloc, root, change.file, to);
                    return .{ .ok = true, .text = try std.fmt.allocPrint(alloc, "{s} is {s}.\n", .{ change.file, @tagName(to) }) };
                },
                .none => return .{ .ok = false, .text = try std.fmt.allocPrint(alloc, "No {s} change to mark {s}.\n", .{ @tagName(from), @tagName(to) }) },
                .ambiguous => return .{ .ok = false, .text = try std.fmt.allocPrint(alloc, "Several changes are {s}; name one.\n", .{@tagName(from)}) },
                .not_found => return .{ .ok = false, .text = try std.fmt.allocPrint(alloc, "No change named {s} in " ++ sdd_layout.changes_dir ++ ".\n", .{parsed.name.?}) },
            }
        },
        .status, .on, .off, .tdd => unreachable,
    }
}

test "parseAction accepts the documented subcommands" {
    try std.testing.expectEqual(Action.status, parseAction(&.{}).?.action);
    try std.testing.expectEqual(Action.on, parseAction(&.{"on"}).?.action);
    try std.testing.expectEqual(Action.off, parseAction(&.{"off"}).?.action);
    try std.testing.expectEqualStrings("pagos", parseAction(&.{ "new", "pagos" }).?.name.?);
    try std.testing.expect(parseAction(&.{"new"}) == null);
    try std.testing.expect(parseAction(&.{"approve"}).?.name == null);
    try std.testing.expectEqualStrings("x", parseAction(&.{ "done", "x" }).?.name.?);
    try std.testing.expect(parseAction(&.{"status"}) == null);
    try std.testing.expect(parseAction(&.{"enable"}) == null);
    try std.testing.expect(parseAction(&.{ "on", "now" }) == null);
    try std.testing.expectEqual(Action.approve, parseSlash("  approve  ").?.action);
    try std.testing.expect(parseSlash("new a b") == null);
    try std.testing.expectEqualStrings("strict", parseSlash("tdd strict").?.name.?);
    try std.testing.expect(parseSlash("tdd sometimes") == null);
    try std.testing.expect(parseSlash("tdd") == null);
}

test "renderStatus lists open changes and explains the checks" {
    const alloc = std.testing.allocator;
    const changes = [_]sdd_layout.Change{
        sdd_layout.parseChange("2026-09-01-old.md", "---\nstatus: done\n---\n"),
        sdd_layout.parseChange("2026-09-27-pagos.md", "---\nstatus: approved\n---\n- [x] a\n- [ ] b\n"),
    };
    const context = StatusContext{
        .workspace_root = "/repo",
        .records_dir = "sdd/specs",
        .jev_enabled = false,
        .drift_gate = true,
        .spec_count = 2,
        .rule_count = 5,
        .changes = &changes,
        .enable_command = "fx sdd on",
    };
    const off = try renderStatus(alloc, .{}, context);
    defer alloc.free(off);
    try std.testing.expect(std.mem.startsWith(u8, off, "SDD: off (default)\n"));
    try std.testing.expect(std.mem.find(u8, off, "2 file(s), 5 rule(s) in sdd/specs") != null);
    try std.testing.expect(std.mem.find(u8, off, "▸ 2026-09-27-pagos.md (approved, tasks 1/2)") != null);
    try std.testing.expect(std.mem.find(u8, off, "old.md") == null);
    try std.testing.expect(std.mem.find(u8, off, "none while SDD is off") != null);
    try std.testing.expect(std.mem.find(u8, off, "Turn it on with `fx sdd on`.") != null);

    const no_jev = try renderStatus(alloc, .{ .enabled = true, .source = .workspace }, context);
    defer alloc.free(no_jev);
    try std.testing.expect(std.mem.find(u8, no_jev, "Jev is off") != null);

    var live = context;
    live.jev_enabled = true;
    live.changes = &.{};
    const on = try renderStatus(alloc, .{ .enabled = true, .source = .environment }, live);
    defer alloc.free(on);
    try std.testing.expect(std.mem.find(u8, on, "route the first file change to fix, spec or change") != null);
    try std.testing.expect(std.mem.find(u8, on, "rules the turn's changes contradict") != null);
    try std.testing.expect(std.mem.find(u8, on, "none open") != null);
    try std.testing.expect(std.mem.find(u8, on, "FX_SDD overrides") != null);
}

test "savedMessage warns when FX_SDD disagrees" {
    try std.testing.expectEqualStrings("SDD is on for this workspace.\n", savedMessage(true, .{ .enabled = true, .source = .workspace }));
    try std.testing.expect(std.mem.find(u8, savedMessage(true, .{ .enabled = false, .source = .environment }), "keeps it off") != null);
}

test "applyChangeAction creates, approves and closes a change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const created = try applyChangeAction(alloc, tmp.dir, .{ .action = .new, .name = "pagos-parciales" });
    defer alloc.free(created.text);
    try std.testing.expect(created.ok);
    const bad = try applyChangeAction(alloc, tmp.dir, .{ .action = .new, .name = "Bad" });
    defer alloc.free(bad.text);
    try std.testing.expect(!bad.ok);
    const early = try applyChangeAction(alloc, tmp.dir, .{ .action = .done });
    defer alloc.free(early.text);
    try std.testing.expect(!early.ok);
    const approved = try applyChangeAction(alloc, tmp.dir, .{ .action = .approve });
    defer alloc.free(approved.text);
    try std.testing.expect(std.mem.endsWith(u8, approved.text, "-pagos-parciales.md is approved.\n"));
    const done = try applyChangeAction(alloc, tmp.dir, .{ .action = .done, .name = "pagos-parciales" });
    defer alloc.free(done.text);
    try std.testing.expect(done.ok);
}
