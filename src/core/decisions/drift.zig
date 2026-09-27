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

pub fn contradictionQuestions(arena: Allocator, count: usize) ![]const jev_contract.Question {
    const list = try arena.alloc(jev_contract.Question, count);
    for (list, 0..) |*question, index| question.* = .{ .id = contradicts_ids[index], .instructions = contradicts_instructions[index], .kind = .noul };
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
pub fn contradictionState(alloc: Allocator, diff: []const u8, selected: []const Decision) ![]u8 {
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
    const contradictions = try contradictionQuestions(arena, 1);
    try std.testing.expect(std.mem.find(u8, contradictions[0].instructions, "`decisions[0].text`") != null);
}
