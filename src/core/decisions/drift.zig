//! Spec drift: checks a code diff against the project's recorded decisions
//! (for example `sdd/decisions/*.md`) and flags decisions the diff may have
//! made out of date.
//!
//! Two Jev calls: the first asks, for every decision title, whether the diff
//! touches what it describes; the second reads the relevant decisions' text
//! and asks whether the diff contradicts each one. Code keeps the thresholds;
//! Jev never edits the decisions.

const std = @import("std");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");
const io_mod = @import("../shared/io.zig");
const typesafe = @import("../../gateway/typesafe.zig");
const sdd_layout = @import("../sdd/sdd_layout.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    pub const max_decisions = 64;
    pub const decision_bytes = 64 * 1024;
    pub const summary_bytes = 400;
    pub const body_bytes = 3 * 1024;
    pub const diff_bytes = 48 * 1024;
    /// Decision text sent in the second call, across all relevant decisions.
    pub const bodies_bytes = 24 * 1024;
};

pub const relevance_threshold = 0.5;
/// 0.55 rather than 0.5: live answers at 0.50-0.52 were ambiguous in practice.
pub const contradiction_threshold = 0.55;
/// Confidence the origin answer needs before fx picks a side.
pub const origin_confidence = 0.5;

const origin_choices = [_]jev_contract.Option{
    .{ .name = "asked", .description = "`user_request` asks for exactly this change in behavior" },
    .{ .name = "side_effect", .description = "`user_request` asks for something else, and this change came along with it without being asked for" },
};

/// Which side a contradiction is resolved on.
pub const Origin = struct {
    asked: bool,
    confidence: f64,
};

pub const Direction = enum {
    /// The user asked for the new behavior; the record is out of date.
    update_record,
    /// Nothing asked for the change; the code drifted from the record.
    fix_code,
    /// Unclear; the user decides before either side changes.
    ask_user,
    /// No request to judge against (`fx jev drift`).
    unknown,

    pub fn of(origin: ?Origin) Direction {
        const known = origin orelse return .unknown;
        if (known.confidence < origin_confidence) return .ask_user;
        return if (known.asked) .update_record else .fix_code;
    }
};

pub const Decision = struct {
    /// File name, e.g. `014-mimi-agent.md`.
    file: []const u8,
    title: []const u8,
    status: []const u8,
    summary: []const u8,
    body: []const u8,
};

/// Parses one decision file. Front matter `title`, `status` and
/// `description` are used when present; otherwise the first heading and the
/// file name stand in. Strings borrow from `text` or `file`.
pub fn parseDecision(file: []const u8, text: []const u8) Decision {
    var title: []const u8 = std.mem.trimEnd(u8, file, ".md");
    var status: []const u8 = "";
    var summary: []const u8 = "";
    var body = text;
    if (std.mem.startsWith(u8, text, "---\n")) {
        if (std.mem.find(u8, text[4..], "\n---")) |end| {
            const front = text[4 .. 4 + end];
            body = std.mem.trimStart(u8, text[4 + end + 4 ..], "\r\n");
            var lines = std.mem.splitScalar(u8, front, '\n');
            while (lines.next()) |line| {
                if (field(line, "title")) |value| title = value;
                if (field(line, "status")) |value| status = value;
                if (field(line, "description")) |value| summary = value;
            }
        }
    } else {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "# ")) {
                title = std.mem.trim(u8, line[2..], " \t\r");
                break;
            }
        }
    }
    return .{
        .file = file,
        .title = title,
        .status = status,
        .summary = turn_text.clip(summary, Limits.summary_bytes),
        .body = turn_text.clip(body, Limits.body_bytes),
    };
}

fn field(line: []const u8, comptime name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, name ++ ":")) return null;
    const value = std.mem.trim(u8, line[name.len + 1 ..], " \t\r\"'");
    return if (value.len == 0) null else value;
}

/// A spec rule checked like a decision record.
pub fn ruleDecision(file: []const u8, rule: sdd_layout.Rule) Decision {
    return .{
        .file = file,
        .title = rule.title,
        .status = "",
        .summary = turn_text.clip(rule.body, Limits.summary_bytes),
        .body = turn_text.clip(rule.body, Limits.body_bytes),
    };
}

/// Whether the decision still binds the code (superseded or rejected ones
/// are not checked).
pub fn isActive(decision: Decision) bool {
    inline for (.{ "superseded", "rejected", "deprecated" }) |inactive| {
        if (std.ascii.eqlIgnoreCase(decision.status, inactive)) return false;
    }
    return true;
}

const relevant_ids = blk: {
    var list: [Limits.max_decisions][]const u8 = undefined;
    for (0..Limits.max_decisions) |index| list[index] = std.fmt.comptimePrint("relevant_{d}", .{index});
    break :blk list;
};
const relevant_instructions = blk: {
    var list: [Limits.max_decisions][]const u8 = undefined;
    for (0..Limits.max_decisions) |index| list[index] = std.fmt.comptimePrint(
        "`diff` changes code or behavior that `decisions[{d}]` describes",
        .{index},
    );
    break :blk list;
};
const requested_ids = blk: {
    var list: [Limits.max_decisions][]const u8 = undefined;
    for (0..Limits.max_decisions) |index| list[index] = std.fmt.comptimePrint("requested_{d}", .{index});
    break :blk list;
};
const requested_instructions = blk: {
    var list: [Limits.max_decisions][]const u8 = undefined;
    for (0..Limits.max_decisions) |index| list[index] = std.fmt.comptimePrint(
        "Where the part of `diff` that no longer matches `decisions[{d}].text` comes from",
        .{index},
    );
    break :blk list;
};
const contradicts_ids = blk: {
    var list: [Limits.max_decisions][]const u8 = undefined;
    for (0..Limits.max_decisions) |index| list[index] = std.fmt.comptimePrint("contradicts_{d}", .{index});
    break :blk list;
};
const contradicts_instructions = blk: {
    var list: [Limits.max_decisions][]const u8 = undefined;
    for (0..Limits.max_decisions) |index| list[index] = std.fmt.comptimePrint(
        "After `diff`, some statement in `decisions[{d}].text` no longer matches the code",
        .{index},
    );
    break :blk list;
};

pub fn relevanceQuestions(arena: Allocator, count: usize) ![]const jev_contract.Question {
    const list = try arena.alloc(jev_contract.Question, count);
    for (list, 0..) |*question, index| question.* = .{ .id = relevant_ids[index], .instructions = relevant_instructions[index], .kind = .noul };
    return list;
}

/// One contradiction question per decision, plus, with a request, whether
/// the request asked for each departure.
pub fn contradictionQuestions(arena: Allocator, count: usize, with_request: bool) ![]const jev_contract.Question {
    const list = try arena.alloc(jev_contract.Question, if (with_request) count * 2 else count);
    for (0..count) |index| {
        list[index] = .{ .id = contradicts_ids[index], .instructions = contradicts_instructions[index], .kind = .noul };
        if (with_request) list[count + index] = .{ .id = requested_ids[index], .instructions = requested_instructions[index], .kind = .{ .choice = &origin_choices } };
    }
    return list;
}

/// State for the relevance call: the diff and each decision's title and
/// summary. Caller owns the returned bytes.
pub fn relevanceState(alloc: Allocator, diff: []const u8, decisions: []const Decision) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("diff");
    try jw.write(turn_text.clip(diff, Limits.diff_bytes));
    try jw.objectField("decisions");
    try jw.beginArray();
    for (decisions) |decision| try jw.write(.{ .title = decision.title, .summary = decision.summary });
    try jw.endArray();
    try jw.endObject();
    return out.toOwnedSlice();
}

/// State for the contradiction call over `selected` decisions, whose text
/// shares a byte budget. Caller owns the returned bytes.
pub fn contradictionState(alloc: Allocator, diff: []const u8, selected: []const Decision, user_request: ?[]const u8) ![]u8 {
    const per_decision = if (selected.len == 0) 0 else @min(Limits.body_bytes, Limits.bodies_bytes / selected.len);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("diff");
    try jw.write(turn_text.clip(diff, Limits.diff_bytes));
    try jw.objectField("decisions");
    try jw.beginArray();
    for (selected) |decision| try jw.write(.{ .title = decision.title, .text = turn_text.clip(decision.body, per_decision) });
    try jw.endArray();
    if (user_request) |request| {
        try jw.objectField("user_request");
        try jw.write(turn_text.clip(request, 4 * 1024));
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

/// Indices of decisions whose relevance reaches the threshold.
pub fn relevantIndices(arena: Allocator, response: *const jev_contract.Response, count: usize) ![]const usize {
    var list: std.ArrayList(usize) = .empty;
    for (0..count) |index| {
        const p = response.noul(relevant_ids[index]) orelse return error.IncompleteJevAnswer;
        if (p >= relevance_threshold) try list.append(arena, index);
    }
    return list.items;
}

pub fn relevance(response: *const jev_contract.Response, index: usize) ?f64 {
    return response.noul(relevant_ids[index]);
}

pub fn contradiction(response: *const jev_contract.Response, index: usize) ?f64 {
    return response.noul(contradicts_ids[index]);
}

pub fn originFor(response: *const jev_contract.Response, index: usize) ?Origin {
    const answer = response.choice(requested_ids[index]) orelse return null;
    return .{ .asked = std.mem.eql(u8, answer.choice, "asked"), .confidence = answer.confidence };
}

pub const default_dirs = [_][]const u8{ sdd_layout.specs_dir, "sdd/decisions", "docs/decisions", "docs/adr", "decisions" };

pub const Jev = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

pub const Finding = struct {
    decision: Decision,
    touched: f64,
    contradiction: f64,
    stale: bool,
    /// Whether the turn's request asked for the departure; null without one.
    origin: ?Origin = null,

    pub fn direction(self: Finding) Direction {
        return Direction.of(self.origin);
    }
};

pub const Report = struct {
    dir: []const u8,
    decision_count: usize,
    diff_bytes: usize,
    findings: []const Finding,

    pub fn staleCount(self: Report) usize {
        var count: usize = 0;
        for (self.findings) |finding| {
            if (finding.stale) count += 1;
        }
        return count;
    }
};

/// The first default decisions directory under `root`, or null.
pub fn findDir(root: std.Io.Dir) ?[]const u8 {
    for (default_dirs) |candidate| {
        root.access(io_mod.getIo(), candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

/// Checks `git diff <range>` in `root` against the decisions in `dir_path`
/// (relative to `root`). With `user_request`, each finding also says whether
/// the request asked for the change. Everything in the report is allocated
/// in `arena`.
pub fn check(arena: Allocator, jev: Jev, root_path: []const u8, range: []const u8, dir_path: []const u8, user_request: ?[]const u8) !Report {
    const io = io_mod.getIo();
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    var dir = try root.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md") or std.mem.startsWith(u8, entry.name, "_")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    // In `sdd/specs` every `## ` rule is checked on its own.
    const rules_mode = std.mem.eql(u8, dir_path, sdd_layout.specs_dir);
    var decisions: std.ArrayList(Decision) = .empty;
    for (names.items) |name| {
        if (decisions.items.len == Limits.max_decisions) break;
        const text = dir.readFileAlloc(io, name, arena, .limited(Limits.decision_bytes)) catch continue;
        if (rules_mode) {
            for (try sdd_layout.parseRules(arena, std.mem.trimEnd(u8, name, ".md"), text)) |rule| {
                if (decisions.items.len == Limits.max_decisions) break;
                try decisions.append(arena, ruleDecision(name, rule));
            }
            continue;
        }
        const decision = parseDecision(name, text);
        if (isActive(decision)) try decisions.append(arena, decision);
    }
    var report = Report{ .dir = dir_path, .decision_count = decisions.items.len, .diff_bytes = 0, .findings = &.{} };
    if (decisions.items.len == 0) return report;

    // Change files and specs are not code; leave the whole `sdd/` tree out.
    const excluded = if (std.mem.startsWith(u8, dir_path, sdd_layout.root_dir ++ "/")) sdd_layout.root_dir else dir_path;
    const exclude = try std.fmt.allocPrint(arena, ":(exclude){s}", .{excluded});
    const git = try std.process.run(arena, io, .{
        .argv = &.{ "git", "diff", "--no-color", "--no-ext-diff", range, "--", ".", exclude },
        .cwd = .{ .path = root_path },
    });
    if (git.term != .exited or git.term.exited != 0) return error.GitDiffFailed;
    const diff = std.mem.trim(u8, git.stdout, " \t\r\n");
    report.diff_bytes = diff.len;
    if (diff.len == 0) return report;

    var relevance_response = try typesafe.systemOne(arena, .{
        .base_url = jev.base_url,
        .api_key = jev.api_key,
        .model = jev.model,
        .state_json = try relevanceState(arena, diff, decisions.items),
        .questions = try relevanceQuestions(arena, decisions.items.len),
    });
    defer relevance_response.deinit();
    const relevant = try relevantIndices(arena, &relevance_response, decisions.items.len);
    if (relevant.len == 0) return report;

    const selected = try arena.alloc(Decision, relevant.len);
    for (relevant, 0..) |decision_index, index| selected[index] = decisions.items[decision_index];
    var contradiction_response = try typesafe.systemOne(arena, .{
        .base_url = jev.base_url,
        .api_key = jev.api_key,
        .model = jev.model,
        .state_json = try contradictionState(arena, diff, selected, user_request),
        .questions = try contradictionQuestions(arena, selected.len, user_request != null),
    });
    defer contradiction_response.deinit();

    const findings = try arena.alloc(Finding, selected.len);
    for (selected, 0..) |decision, index| {
        const p = contradiction(&contradiction_response, index) orelse return error.IncompleteJevAnswer;
        findings[index] = .{
            .decision = decision,
            .touched = relevance(&relevance_response, relevant[index]).?,
            .contradiction = p,
            .stale = p >= contradiction_threshold,
            .origin = if (user_request != null) originFor(&contradiction_response, index) else null,
        };
    }
    report.findings = findings;
    return report;
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// The continuation sent after a turn whose changes contradict decision
/// records. Caller owns the text.
pub fn feedback(alloc: Allocator, dir: []const u8, stale: []const Finding) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const specs = std.mem.eql(u8, dir, sdd_layout.specs_dir);
    const noun = if (specs) "spec rules" else "decision records";
    try w.print("Jev spec check: the changes in this turn may contradict these {s}:\n", .{noun});
    var counts = std.EnumArray(Direction, usize).initFill(0);
    for (stale) |finding| {
        counts.getPtr(finding.direction()).* += 1;
        if (specs) {
            try w.print("- {s}/{s} › {s} (p={d:.2}", .{ dir, finding.decision.file, finding.decision.title, finding.contradiction });
        } else {
            try w.print("- {s}/{s} \"{s}\" (p={d:.2}", .{ dir, finding.decision.file, finding.decision.title, finding.contradiction });
        }
        try w.print("){s}\n", .{switch (finding.direction()) {
            .update_record => ": the request asked for this, update it",
            .fix_code => ": the request did not ask for this, fix the code",
            .ask_user => ": unclear, ask the user",
            .unknown => "",
        }});
    }
    const update_how = if (specs)
        "rewrite the rule under its `## ` heading so it describes the behavior as it is now (a spec holds only current behavior, not history)"
    else
        "update the record so it describes the code as it is now (keep its format and add a short note of what changed)";
    if (counts.get(.unknown) != 0) {
        try w.print("Read each one. If the change is intended, {s}. If the change was a mistake, fix the code instead. ", .{update_how});
    }
    if (counts.get(.update_record) != 0) try w.print("For the ones marked update: {s}. ", .{update_how});
    if (counts.get(.fix_code) != 0) {
        try w.writeAll("For the ones marked fix the code: the user's request did not ask for this departure, so change the code back " ++
            "to match the text; do not edit the text to fit the code. Only undo what you changed in this turn: if the departure was " ++
            "already uncommitted before this turn, it may be the user's work in progress, so leave it and tell the user. If you are " ++
            "sure the text is wrong, ask the user instead. ");
    }
    if (counts.get(.ask_user) != 0) {
        try w.writeAll("For the ones marked ask: do not change the code or the text yet; ask the user which one is right, quoting the text. ");
    }
    try w.writeAll("The user already sees your previous answer; reply with only what you updated, fixed or are asking, without repeating it.");
    return out.toOwnedSlice();
}

test "spec rules are checked one by one and reported by rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rules = try sdd_layout.parseRules(arena.allocator(), "reservas", "## Saldo follows Asesor\nSaldo comes after Asesor.\n");
    const decision = ruleDecision("reservas.md", rules[0]);
    try std.testing.expectEqualStrings("Saldo follows Asesor", decision.title);
    try std.testing.expect(isActive(decision));
    const text = try feedback(std.testing.allocator, sdd_layout.specs_dir, &.{.{ .decision = decision, .touched = 0.9, .contradiction = 0.8, .stale = true }});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "- sdd/specs/reservas.md › Saldo follows Asesor (p=0.80)") != null);
    try std.testing.expect(std.mem.find(u8, text, "spec rules") != null);
}

test "parseDecision reads front matter and falls back to headings" {
    const decision = parseDecision("014-mimi-agent.md",
        \\---
        \\type: Decision
        \\title: Mimi — @mimi booking agent
        \\description: Staff invoke Mimi with @mimi.
        \\status: approved
        \\---
        \\
        \\# Decision
        \\
        \\Mention @mimi to call the agent.
    );
    try std.testing.expectEqualStrings("Mimi — @mimi booking agent", decision.title);
    try std.testing.expectEqualStrings("approved", decision.status);
    try std.testing.expectEqualStrings("Staff invoke Mimi with @mimi.", decision.summary);
    try std.testing.expect(std.mem.startsWith(u8, decision.body, "# Decision"));
    try std.testing.expect(isActive(decision));

    const plain = parseDecision("adr-7.md", "intro\n# Use SQLite\nbody");
    try std.testing.expectEqualStrings("Use SQLite", plain.title);
    const superseded = parseDecision("x.md", "---\nstatus: superseded\n---\nold");
    try std.testing.expect(!isActive(superseded));
}

test "states and questions line up by index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const decisions = [_]Decision{
        .{ .file = "a.md", .title = "A", .status = "", .summary = "sa", .body = "body a" },
        .{ .file = "b.md", .title = "B", .status = "", .summary = "", .body = "body b" },
    };
    const state = try relevanceState(arena, "+x", &decisions);
    try std.testing.expectEqualStrings("{\"diff\":\"+x\",\"decisions\":[{\"title\":\"A\",\"summary\":\"sa\"},{\"title\":\"B\",\"summary\":\"\"}]}", state);
    const questions = try relevanceQuestions(arena, 2);
    try std.testing.expectEqualStrings("relevant_1", questions[1].id);
    try std.testing.expect(std.mem.find(u8, questions[1].instructions, "`decisions[1]`") != null);
    const contradictions = try contradictionQuestions(arena, 1, false);
    try std.testing.expect(std.mem.find(u8, contradictions[0].instructions, "`decisions[0].text`") != null);
}

test "direction follows whether the request asked for the change" {
    try std.testing.expectEqual(Direction.update_record, Direction.of(.{ .asked = true, .confidence = 0.9 }));
    try std.testing.expectEqual(Direction.fix_code, Direction.of(.{ .asked = false, .confidence = 0.8 }));
    try std.testing.expectEqual(Direction.ask_user, Direction.of(.{ .asked = false, .confidence = 0.3 }));
    try std.testing.expectEqual(Direction.unknown, Direction.of(null));
}

test "feedback tells the agent which side to change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rules = try sdd_layout.parseRules(arena.allocator(), "ministerio", "## Coverage\nCovered when a row exists.\n## Edit sheet\nShows the booking selector.\n");
    const findings = [_]Finding{
        .{ .decision = ruleDecision("ministerio.md", rules[0]), .touched = 0.9, .contradiction = 0.8, .stale = true, .origin = .{ .asked = true, .confidence = 0.9 } },
        .{ .decision = ruleDecision("ministerio.md", rules[1]), .touched = 0.9, .contradiction = 0.7, .stale = true, .origin = .{ .asked = false, .confidence = 0.9 } },
    };
    const text = try feedback(std.testing.allocator, sdd_layout.specs_dir, &findings);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "› Coverage (p=0.80): the request asked for this, update it") != null);
    try std.testing.expect(std.mem.find(u8, text, "› Edit sheet (p=0.70): the request did not ask for this, fix the code") != null);
    try std.testing.expect(std.mem.find(u8, text, "do not edit the text to fit the code") != null);
    try std.testing.expect(std.mem.find(u8, text, "If the change is intended") == null);
}

test "contradiction questions add the request question per decision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const questions = try contradictionQuestions(arena.allocator(), 2, true);
    try std.testing.expectEqual(@as(usize, 4), questions.len);
    try std.testing.expectEqualStrings("requested_1", questions[3].id);
    const state = try contradictionState(arena.allocator(), "+x", &.{.{ .file = "a.md", .title = "A", .status = "", .summary = "", .body = "b" }}, "do x");
    try std.testing.expect(std.mem.find(u8, state, "\"user_request\":\"do x\"") != null);
}
