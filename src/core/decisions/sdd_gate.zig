//! SDD route gate: before the first file change outside `sdd/` in a turn,
//! Jev sorts the request into one of three routes, so small work does not
//! pay for paperwork.
//!
//! - fix: no rule in `sdd/specs` changes; nothing to write.
//! - spec: a small change to existing rules; the agent is told which rules to
//!   update in the same change (held once).
//! - change: substantial or high-stakes work; code changes are held until a
//!   change file in `sdd/changes` is approved.
//!
//! Code composes the answers: an explicit request to skip the process, or
//! one that only ships finished work (commit, PR, release notes), means fix; high stakes means change; an unclear request or an incomplete answer
//! is sent back to the agent to ask the user; otherwise a confident
//! "substantial" means change and changed rules mean spec. A proposed change counts as approved when the user's message
//! approves it, and an approved change with every task ticked counts as
//! done when the user's message confirms the finished work.

const std = @import("std");
const types = @import("../shared/types.zig");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");
const sdd_layout = @import("../sdd/sdd_layout.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const Limits = struct {
    pub const max_rules = 32;
    pub const request_bytes = 6 * 1024;
    pub const agent_messages_bytes = 8 * 1024;
    pub const change_bytes = 600;
    pub const rule_bytes = 300;
    pub const proposal_bytes = 4 * 1024;
};

pub const scope_id = "scope";
pub const high_stakes_id = "high_stakes";
pub const skip_id = "skip_process";
pub const clear_id = "clear";
pub const approves_id = "approves_proposal";
pub const bug_id = "bug_fix";
pub const publish_id = "publish_only";
pub const closes_id = "closes_change";

/// Probability at which a request counts as high stakes.
pub const high_stakes_threshold = 0.6;
/// Confidence needed to treat a request as substantial.
pub const substantial_confidence = 0.6;
/// Probability at which a rule counts as changed by the request.
pub const rule_threshold = 0.6;
/// Probability at which the user asked to skip the process.
pub const skip_threshold = 0.7;
/// Below this, the request is too vague to route.
pub const clear_threshold = 0.4;
/// Probability at which the user's message approves the proposed change.
pub const approval_threshold = 0.8;
/// Probability at which the user's message confirms a finished change can
/// be closed.
pub const close_threshold = 0.8;
/// Probability at which the request only ships work already done.
pub const publish_threshold = 0.7;
/// Probability at which the request reports a bug (it then needs a
/// regression test under TDD).
pub const bug_threshold = 0.6;

const base_questions = [_]jev_contract.Question{
    .{
        .id = scope_id,
        .instructions = "How much work `user_request` asks a coding agent to do",
        .kind = .{ .choice = &.{
            .{ .name = "trivial", .description = "a one-line, cosmetic, or obvious change" },
            .{ .name = "small", .description = "a focused change in one place with a clear approach" },
            .{ .name = "substantial", .description = "several files or components, a new feature, or an unclear approach" },
        } },
    },
    .{
        .id = high_stakes_id,
        .instructions = "`user_request` changes a database schema or stored data format, money or payments, authentication or permissions, an AI agent pipeline, or adds a new user-facing screen",
        .kind = .noul,
    },
    .{
        .id = skip_id,
        .instructions = "`user_request` explicitly tells the agent not to write a proposal, spec or plan for this (for example \"no hagas propuesta\", \"skip the spec\", \"sin SDD\"); describing the work as a fix is not enough",
        .kind = .noul,
    },
    .{
        .id = clear_id,
        .instructions = "`user_request` is specific enough to tell how much work it asks for",
        .kind = .noul,
    },
    .{
        .id = publish_id,
        .instructions = "`user_request` only asks to commit, push, open or merge a pull request, tag a release, or write notes about work already done, without changing what the software does",
        .kind = .noul,
    },
    .{
        .id = bug_id,
        .instructions = "`user_request` reports that the software computes or behaves wrongly (a wrong result, an error, a crash, data saved or shown incorrectly) and asks to fix it; typos, copy, styling or layout, showing something in a new way, and new features are not bugs",
        .kind = .noul,
    },
};

const approves_question = jev_contract.Question{
    .id = approves_id,
    .instructions = "`user_request` says yes to `proposal` (for example yes, si yes, sí, ok, approved, aprobado, dale, adelante, go ahead), even when it adds other instructions such as committing or opening a PR; it does not count when it asks to change the proposal or says not to go ahead with it",
    .kind = .noul,
};

pub const approval_questions = [_]jev_contract.Question{approves_question};

/// State for asking only whether the user's message approves `proposal`.
/// Caller owns the returned bytes.
pub fn approvalState(alloc: Allocator, user_request: []const u8, proposal: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(.{
        .user_request = turn_text.clip(user_request, Limits.request_bytes),
        .proposal = turn_text.clip(proposal, Limits.proposal_bytes),
    });
    return out.toOwnedSlice();
}

pub const close_questions = [_]jev_contract.Question{.{
    .id = closes_id,
    .instructions = "`user_request` tells the agent that the finished work in `change` is fine and can be closed (for example ok, perfecto, listo, done, cerralo, está bien, looks good, ship it), even when it adds other instructions such as committing or opening a PR; it does not count when it asks for more changes to that work, reports a problem with it, only asks a question, or is about something else",
    .kind = .noul,
}};

/// State for asking whether the user's message closes `change`. Caller
/// owns the returned bytes.
pub fn closeState(alloc: Allocator, user_request: []const u8, change: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(.{
        .user_request = turn_text.clip(user_request, Limits.request_bytes),
        .change = turn_text.clip(change, Limits.proposal_bytes),
    });
    return out.toOwnedSlice();
}

/// The approved change whose tasks are all ticked, so the user may close it:
/// the one `text` names, otherwise the first.
pub fn readyToClose(changes: []const sdd_layout.Change, text: []const u8) ?sdd_layout.Change {
    var first: ?sdd_layout.Change = null;
    for (changes) |change| {
        if (change.status != .approved or change.tasks_total == 0 or change.tasks_done != change.tasks_total) continue;
        if (mentionsChange(text, change.file)) return change;
        if (first == null) first = change;
    }
    return first;
}

const rule_ids = blk: {
    var list: [Limits.max_rules][]const u8 = undefined;
    for (0..Limits.max_rules) |index| list[index] = std.fmt.comptimePrint("rule_{d}", .{index});
    break :blk list;
};

const rule_instructions = blk: {
    var list: [Limits.max_rules][]const u8 = undefined;
    for (0..Limits.max_rules) |index| list[index] = std.fmt.comptimePrint(
        "`user_request` asks for behavior different from what `rules[{d}]` says, so the rule text must change; fixing code to do what the rule already says does not count",
        .{index},
    );
    break :blk list;
};

/// Questions for `rule_count` rules and an optional proposal to approve.
pub fn questions(arena: Allocator, rule_count: usize, with_proposal: bool) ![]const jev_contract.Question {
    const count = @min(rule_count, Limits.max_rules);
    var list: std.ArrayList(jev_contract.Question) = .empty;
    try list.appendSlice(arena, &base_questions);
    if (with_proposal) try list.append(arena, approves_question);
    for (0..count) |index| try list.append(arena, .{ .id = rule_ids[index], .instructions = rule_instructions[index], .kind = .noul });
    return list.items;
}

pub const Input = struct {
    user_request: []const u8,
    turn_messages: []const ChatMessage,
    assistant_text: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    rules: []const sdd_layout.Rule,
    /// Body of the proposed change waiting for approval, if any.
    proposal: ?[]const u8 = null,
};

/// Builds the Jev `state` JSON. Caller owns the returned bytes.
pub fn buildState(alloc: Allocator, input: Input) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const agent_messages = try turn_text.agentMessages(arena, input.turn_messages, input.assistant_text, Limits.agent_messages_bytes);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("user_request");
    try jw.write(turn_text.clip(input.user_request, Limits.request_bytes));
    try jw.objectField("agent_messages");
    try jw.write(agent_messages);
    try jw.objectField("pending_change");
    try jw.write(.{
        .tool = input.tool_name,
        .input = turn_text.clip(input.arguments_json, Limits.change_bytes),
    });
    try jw.objectField("rules");
    try jw.beginArray();
    for (input.rules[0..@min(input.rules.len, Limits.max_rules)]) |rule| {
        try jw.write(.{
            .spec = rule.capability,
            .rule = rule.title,
            .text = turn_text.clip(rule.body, Limits.rule_bytes),
        });
    }
    try jw.endArray();
    if (input.proposal) |proposal| {
        try jw.objectField("proposal");
        try jw.write(turn_text.clip(proposal, Limits.proposal_bytes));
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

pub const Route = enum { fix, spec, change, unclear };

pub const Verdict = struct {
    route: Route,
    /// Indices into the rules sent to Jev that the request changes.
    touched: []const usize = &.{},
    high_stakes: f64 = 0,
    substantial: bool = false,
    /// The user's message approves the proposed change.
    approves: bool = false,
    /// The request reports a bug.
    bug: bool = false,
};

pub const EvaluateError = error{ IncompleteJevAnswer, OutOfMemory };

pub fn evaluate(arena: Allocator, response: *const jev_contract.Response, rule_count: usize, with_proposal: bool) EvaluateError!Verdict {
    const scope = response.choice(scope_id) orelse return error.IncompleteJevAnswer;
    const high_stakes = response.noul(high_stakes_id) orelse return error.IncompleteJevAnswer;
    const skip = response.noul(skip_id) orelse return error.IncompleteJevAnswer;
    const clear = response.noul(clear_id) orelse return error.IncompleteJevAnswer;
    const bug = response.noul(bug_id) orelse return error.IncompleteJevAnswer;
    const publish = response.noul(publish_id) orelse return error.IncompleteJevAnswer;
    const approves = if (with_proposal)
        (response.noul(approves_id) orelse return error.IncompleteJevAnswer) >= approval_threshold
    else
        false;
    var touched: std.ArrayList(usize) = .empty;
    for (0..@min(rule_count, Limits.max_rules)) |index| {
        const p = response.noul(rule_ids[index]) orelse return error.IncompleteJevAnswer;
        if (p >= rule_threshold) try touched.append(arena, index);
    }
    const substantial = std.mem.eql(u8, scope.choice, "substantial") and scope.confidence >= substantial_confidence;
    var verdict = Verdict{
        .route = .fix,
        .touched = touched.items,
        .high_stakes = high_stakes,
        .substantial = substantial,
        .approves = approves,
        .bug = bug >= bug_threshold,
    };
    // Shipping finished work (commit, PR, release notes) is not a change.
    if (skip >= skip_threshold or publish >= publish_threshold) {
        verdict.bug = false;
        return verdict;
    }
    // A vague request is sent back before scope counts: "improve the page"
    // reads as substantial without saying what to build.
    if (high_stakes >= high_stakes_threshold) {
        verdict.route = .change;
    } else if (clear < clear_threshold) {
        verdict.route = .unclear;
    } else if (substantial) {
        verdict.route = .change;
    } else if (touched.items.len != 0) {
        verdict.route = .spec;
    }
    return verdict;
}

/// Why a change-route file change was held. Caller owns the text.
pub fn changeReason(alloc: Allocator, verdict: Verdict, date: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("SDD route: change (");
    if (verdict.high_stakes >= high_stakes_threshold) try w.print("high stakes p={d:.2}", .{verdict.high_stakes});
    if (verdict.substantial) try w.writeAll(if (verdict.high_stakes >= high_stakes_threshold) "; substantial" else "substantial");
    try w.print(
        "), so code changes are held until a change is approved. Files under sdd/ can be written now.\n" ++
            "Write sdd/changes/{s}-<slug>.md (lowercase-hyphen slug) with this shape:\n\n" ++
            "---\nstatus: proposed\nspecs: [<spec names this touches>]\n---\n# <Title>\n\n## Why\n<the problem>\n\n## What\n<the behavior to build, as bullets>\n\n" ++
            "## Wireframe\n<only for a new screen: a black-and-white ASCII layout>\n\n## Tasks\n- [ ] <step>\n\n## Notes\n\n" ++
            "Then show it to the user and ask them to approve it. Do not change its `status` yourself (fx does) and do not " ++
            "change other files until it is approved; the user approves by replying yes or with /sdd approve. You tick " ++
            "the Tasks checkboxes as you finish them.",
        .{date},
    );
    return out.toOwnedSlice();
}

/// Why a file change was held while a proposal waits. Caller owns the text.
pub fn pendingReason(alloc: Allocator, proposal_file: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "SDD: {s}/{s} is proposed and waiting for the user's approval, so code changes are held. " ++
            "Show the proposal to the user and ask them to approve it (they reply yes or run /sdd approve). " ++
            "You can still edit the proposal or anything under sdd/.",
        .{ sdd_layout.changes_dir, proposal_file },
    );
}

/// Sent once when the user's reply approved the proposal. Caller owns the
/// text.
pub fn approvedNotice(alloc: Allocator, proposal_file: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "SDD: the user's reply approved {s}/{s}; fx set its status to approved. Retry this change and implement it, " ++
            "ticking each task in its Tasks list (`- [x]`) as you finish it.",
        .{ sdd_layout.changes_dir, proposal_file },
    );
}

/// Guidance for a spec-route change (held once). Caller owns the text.
pub fn specReason(alloc: Allocator, rules: []const sdd_layout.Rule, touched: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("SDD route: spec. This request changes these rules:\n");
    for (touched) |index| try w.print("- {s}/{s}.md › {s}\n", .{ sdd_layout.specs_dir, rules[index].capability, rules[index].title });
    try w.writeAll("Update them in the same change so each describes the new behavior (no change file is needed), then continue.");
    return out.toOwnedSlice();
}

pub const StatusCommand = enum { approve, done };

/// Detects `fx sdd approve` or `fx sdd done` anywhere in a shell command,
/// including `/path/to/fx sdd approve` and chained commands.
pub fn statusCommand(command: []const u8) ?StatusCommand {
    var words: [3][]const u8 = .{ "", "", "" };
    var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n;&|()`'\"");
    while (tokens.next()) |token| {
        words[0] = words[1];
        words[1] = words[2];
        words[2] = token;
        if (!std.mem.eql(u8, std.fs.path.basename(words[0]), "fx") or !std.mem.eql(u8, words[1], "sdd")) continue;
        if (std.mem.eql(u8, words[2], "approve")) return .approve;
        if (std.mem.eql(u8, words[2], "done")) return .done;
    }
    return null;
}

/// A change's status as fx last saw it at the end of a turn.
pub const SeenStatus = struct {
    file: []const u8,
    status: ?sdd_layout.Status,
};

pub const StatusChange = struct {
    file: []const u8,
    from: ?sdd_layout.Status,
    to: ?sdd_layout.Status,
};

/// Changes in `now` whose status differs from `seen`. Files that were not
/// seen are left out: the agent writes new proposals itself.
pub fn statusChanges(arena: Allocator, seen: []const SeenStatus, now: []const sdd_layout.Change) ![]const StatusChange {
    var list: std.ArrayList(StatusChange) = .empty;
    for (now) |change| {
        for (seen) |before| {
            if (!std.mem.eql(u8, before.file, change.file)) continue;
            if (before.status != change.status) try list.append(arena, .{ .file = change.file, .from = before.status, .to = change.status });
            break;
        }
    }
    return list.items;
}

/// Whether `text` names `file` by its stem or its slug.
pub fn mentionsChange(text: []const u8, file: []const u8) bool {
    const stem = std.mem.trimEnd(u8, file, ".md");
    const slug = if (stem.len > 11 and stem[10] == '-') stem[11..] else stem;
    return std.mem.find(u8, text, stem) != null or std.mem.find(u8, text, slug) != null;
}

fn statusName(status: ?sdd_layout.Status) []const u8 {
    return if (status) |value| @tagName(value) else "none";
}

fn writeStatusChanges(w: *std.Io.Writer, changes: []const StatusChange) !void {
    try w.writeAll("SDD: the user changed a change's status since your last reply.\n");
    for (changes) |change| {
        try w.print("- {s}/{s}: {s} → {s}\n", .{ sdd_layout.changes_dir, change.file, statusName(change.from), statusName(change.to) });
    }
    try w.writeAll("The files on disk are current; anything said earlier about these statuses is out of date.");
}

/// Held once before the first tool call of a turn that follows a status
/// change the user made (`/sdd approve|done`). Caller owns the text.
pub fn statusChangedReason(alloc: Allocator, changes: []const StatusChange) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeStatusChanges(&out.writer, changes);
    try out.writer.writeAll(" Retry your call.");
    return out.toOwnedSlice();
}

/// Continuation when a final answer names a change whose status the user
/// changed and no tool call carried the news. Caller owns the text.
pub fn statusChangedAtStop(alloc: Allocator, changes: []const StatusChange) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeStatusChanges(&out.writer, changes);
    try out.writer.writeAll(
        " If your answer says otherwise, correct it in one short sentence; do not repeat the rest of your answer. " ++
            "If it already matches, reply with nothing more than a short confirmation.",
    );
    return out.toOwnedSlice();
}

/// Held once when the user's reply closed a finished change before the
/// agent's first tool call. Caller owns the text.
pub fn closedNotice(alloc: Allocator, change_file: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "SDD: the user's reply confirmed {s}/{s} is fine; fx set its status to done. Do not ask them to close it " ++
            "again. Retry your call.",
        .{ sdd_layout.changes_dir, change_file },
    );
}

/// Continuation when the user's reply closed a finished change in a turn
/// without tool calls. Caller owns the text.
pub fn closedAtStop(alloc: Allocator, change_file: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "SDD: fx closed {s}/{s} (status done) because the user's reply confirmed it.\n" ++
            "Tell the user in one short sentence that it is closed. Do not repeat the rest of your answer and do not " ++
            "ask them to run /sdd done.",
        .{ sdd_layout.changes_dir, change_file },
    );
}

pub const self_approve_reason =
    "SDD: only the user approves a change. Do not run `fx sdd approve`. If the user already approved in their " ++
    "message, retry your code change: fx reads their reply and approves it. Otherwise show the proposal and ask them.";

pub const self_done_reason =
    "SDD: closing a change is the user's call. Do not run `fx sdd done`; show the user what was done and ask them " ++
    "to review it and confirm it is ok to close. Their reply closes it (or they run /sdd done).";

/// Continuation after every task of the approved change is done. Caller
/// owns the text.
pub fn specsReminder(alloc: Allocator, change_file: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "SDD: this turn changed code for {s}/{s}. Tick each finished task in its Tasks list (`- [x]`; the checkboxes " ++
            "are yours, only `status` belongs to fx). If the change is now complete, write the behavior it added or " ++
            "changed as rules in {s}/<area>.md (create the file if needed): one `## ` heading per rule, a short " ++
            "description of the current behavior under it, no history; then ask the user to review the work and confirm " ++
            "it is ok to close (their reply closes it, or /sdd done). If work remains, say what is left. Then give your " ++
            "final answer.",
        .{ sdd_layout.changes_dir, change_file, sdd_layout.specs_dir },
    );
}

pub const unclear_reason =
    "SDD: the request is too vague to tell whether it needs a proposal, so the file change was held. " ++
    "Ask the user whether this is a small fix, an update to an existing rule in sdd/specs, or a change that needs a proposal, " ++
    "then continue.";

pub const incomplete_reason =
    "SDD: the request could not be classified, so the file change was held once. " ++
    "Ask the user whether this is a small fix, an update to an existing rule in sdd/specs, or a change that needs a proposal, " ++
    "then continue.";

fn testResponse(body: []const u8) !jev_contract.Response {
    return jev_contract.parseResponse(std.testing.allocator, body);
}

test "questions include one per rule and the approval question on demand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const without = try questions(arena.allocator(), 2, false);
    try std.testing.expectEqual(@as(usize, 8), without.len);
    try std.testing.expectEqualStrings("rule_1", without[7].id);
    const with = try questions(arena.allocator(), 40, true);
    try std.testing.expectEqual(@as(usize, 7 + Limits.max_rules), with.len);
    try std.testing.expectEqualStrings(approves_id, with[6].id);
}

test "evaluate routes high stakes to change and touched rules to spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stakes = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.8},"high_stakes":{"type":"noul","noul":0.9},"skip_process":{"type":"noul","noul":0.1},"bug_fix":{"type":"noul","noul":0.1},"publish_only":{"type":"noul","noul":0.05},"clear":{"type":"noul","noul":0.9},"rule_0":{"type":"noul","noul":0.9}}}
    );
    defer stakes.deinit();
    const change = try evaluate(arena.allocator(), &stakes, 1, false);
    try std.testing.expectEqual(Route.change, change.route);

    var spec = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.9},"high_stakes":{"type":"noul","noul":0.1},"skip_process":{"type":"noul","noul":0.1},"bug_fix":{"type":"noul","noul":0.1},"publish_only":{"type":"noul","noul":0.05},"clear":{"type":"noul","noul":0.9},"rule_0":{"type":"noul","noul":0.2},"rule_1":{"type":"noul","noul":0.8}}}
    );
    defer spec.deinit();
    const spec_verdict = try evaluate(arena.allocator(), &spec, 2, false);
    try std.testing.expectEqual(Route.spec, spec_verdict.route);
    try std.testing.expectEqualSlices(usize, &.{1}, spec_verdict.touched);
}

test "evaluate honors skip, flags vague requests and needs every answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var skip = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"substantial","confidence":0.9},"high_stakes":{"type":"noul","noul":0.9},"skip_process":{"type":"noul","noul":0.9},"bug_fix":{"type":"noul","noul":0.1},"publish_only":{"type":"noul","noul":0.05},"clear":{"type":"noul","noul":0.9}}}
    );
    defer skip.deinit();
    try std.testing.expectEqual(Route.fix, (try evaluate(arena.allocator(), &skip, 0, false)).route);

    var vague = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.5},"high_stakes":{"type":"noul","noul":0.2},"skip_process":{"type":"noul","noul":0.0},"bug_fix":{"type":"noul","noul":0.1},"publish_only":{"type":"noul","noul":0.05},"clear":{"type":"noul","noul":0.2},"approves_proposal":{"type":"noul","noul":0.95}}}
    );
    defer vague.deinit();
    const unclear = try evaluate(arena.allocator(), &vague, 0, true);
    try std.testing.expectEqual(Route.unclear, unclear.route);
    try std.testing.expect(unclear.approves);

    var missing = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.9},"high_stakes":{"type":"noul","noul":0.1},"skip_process":{"type":"noul","noul":0.0},"bug_fix":{"type":"noul","noul":0.1},"publish_only":{"type":"noul","noul":0.05},"clear":{"type":"noul","noul":0.9}}}
    );
    defer missing.deinit();
    try std.testing.expectError(error.IncompleteJevAnswer, evaluate(arena.allocator(), &missing, 1, false));
}

test "buildState lists rules and the proposal" {
    const alloc = std.testing.allocator;
    const rules = [_]sdd_layout.Rule{.{ .capability = "reservas", .title = "Saldo follows Asesor", .body = "The Saldo column comes right after Asesor." }};
    const state = try buildState(alloc, .{
        .user_request = "move Saldo before Asesor",
        .turn_messages = &.{},
        .assistant_text = "",
        .tool_name = "edit_file",
        .arguments_json = "{\"path\":\"src/ReservasList.tsx\"}",
        .rules = &rules,
        .proposal = "# Pagos parciales",
    });
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "\"rule\":\"Saldo follows Asesor\"") != null);
    try std.testing.expect(std.mem.find(u8, state, "\"proposal\":\"# Pagos parciales\"") != null);
}

test "statusCommand finds fx sdd approve and done" {
    try std.testing.expectEqual(StatusCommand.approve, statusCommand("fx sdd approve create-booking-brief 2>&1 | head -20").?);
    try std.testing.expectEqual(StatusCommand.done, statusCommand("cd /repo && /Users/a/.fx/bin/fx sdd done x").?);
    try std.testing.expectEqual(StatusCommand.approve, statusCommand("echo ok; fx sdd approve").?);
    try std.testing.expect(statusCommand("fx sdd status") == null);
    try std.testing.expect(statusCommand("fx sdd new pagos") == null);
    try std.testing.expect(statusCommand("grep 'sdd approve' notes.md") == null);
    try std.testing.expect(statusCommand("echo fx sdd") == null);
}

test "statusChanges reports only seen changes whose status moved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const seen = [_]SeenStatus{
        .{ .file = "2026-09-30-trenes.md", .status = .approved },
        .{ .file = "2026-09-27-brief.md", .status = .done },
    };
    const now = [_]sdd_layout.Change{
        sdd_layout.parseChange("2026-09-27-brief.md", "---\nstatus: done\n---\n"),
        sdd_layout.parseChange("2026-09-30-trenes.md", "---\nstatus: done\n---\n"),
        sdd_layout.parseChange("2026-10-01-nuevo.md", "---\nstatus: proposed\n---\n"),
    };
    const changes = try statusChanges(arena.allocator(), &seen, &now);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("2026-09-30-trenes.md", changes[0].file);
    try std.testing.expectEqual(sdd_layout.Status.approved, changes[0].from.?);
    try std.testing.expectEqual(sdd_layout.Status.done, changes[0].to.?);

    const reason = try statusChangedReason(std.testing.allocator, changes);
    defer std.testing.allocator.free(reason);
    try std.testing.expect(std.mem.find(u8, reason, "sdd/changes/2026-09-30-trenes.md: approved → done") != null);
    try std.testing.expect(mentionsChange("el doc ventas-trenes sigue en approved", "2026-09-30-ventas-trenes.md"));
    try std.testing.expect(!mentionsChange("listo", "2026-09-30-ventas-trenes.md"));
}

test "reasons name the files to write" {
    const alloc = std.testing.allocator;
    const change = try changeReason(alloc, .{ .route = .change, .high_stakes = 0.9, .substantial = true }, "2026-09-27");
    defer alloc.free(change);
    try std.testing.expect(std.mem.find(u8, change, "high stakes p=0.90; substantial") != null);
    try std.testing.expect(std.mem.find(u8, change, "sdd/changes/2026-09-27-<slug>.md") != null);
    const rules = [_]sdd_layout.Rule{.{ .capability = "reservas", .title = "Columns", .body = "" }};
    const spec = try specReason(alloc, &rules, &.{0});
    defer alloc.free(spec);
    try std.testing.expect(std.mem.find(u8, spec, "sdd/specs/reservas.md › Columns") != null);
    const reminder = try specsReminder(alloc, "2026-09-27-brief.md");
    defer alloc.free(reminder);
    try std.testing.expect(std.mem.find(u8, reminder, "sdd/changes/2026-09-27-brief.md") != null);
    try std.testing.expect(std.mem.find(u8, reminder, "confirm it is ok to close") != null);
}

test "readyToClose wants an approved change with every task ticked" {
    const changes = [_]sdd_layout.Change{
        sdd_layout.parseChange("2026-09-27-brief.md", "---\nstatus: approved\n---\n- [x] a\n- [ ] b\n"),
        sdd_layout.parseChange("2026-09-28-empty.md", "---\nstatus: approved\n---\nno tasks\n"),
        sdd_layout.parseChange("2026-09-29-pagos.md", "---\nstatus: approved\n---\n- [x] a\n"),
        sdd_layout.parseChange("2026-09-30-trenes.md", "---\nstatus: approved\n---\n- [x] a\n- [X] b\n"),
        sdd_layout.parseChange("2026-09-26-old.md", "---\nstatus: done\n---\n- [x] a\n"),
    };
    try std.testing.expectEqualStrings("2026-09-29-pagos.md", readyToClose(&changes, "ok perfecto").?.file);
    try std.testing.expectEqualStrings("2026-09-30-trenes.md", readyToClose(&changes, "trenes ok, cerralo").?.file);
    try std.testing.expect(readyToClose(changes[0..2], "ok") == null);

    const state = try closeState(std.testing.allocator, "ok perfecto done", "# Trenes");
    defer std.testing.allocator.free(state);
    try std.testing.expect(std.mem.find(u8, state, "\"change\":\"# Trenes\"") != null);
    const notice = try closedAtStop(std.testing.allocator, "2026-09-30-trenes.md");
    defer std.testing.allocator.free(notice);
    try std.testing.expect(std.mem.startsWith(u8, notice, "SDD: fx closed sdd/changes/2026-09-30-trenes.md (status done)"));
}
