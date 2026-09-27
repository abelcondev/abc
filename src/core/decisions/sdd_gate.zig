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
//! Code composes the answers: an explicit request to skip the process means
//! fix; high stakes means change; an unclear request or an incomplete answer
//! is sent back to the agent to ask the user; otherwise a confident
//! "substantial" means change and changed rules mean spec. A proposed change counts as approved when the user's message
//! approves it.

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
};

const approves_question = jev_contract.Question{
    .id = approves_id,
    .instructions = "`user_request` approves `proposal` as written (for example yes, approved, go ahead, dale, adelante) rather than asking for changes or a different plan",
    .kind = .noul,
};

const rule_ids = blk: {
    var list: [Limits.max_rules][]const u8 = undefined;
    for (0..Limits.max_rules) |index| list[index] = std.fmt.comptimePrint("rule_{d}", .{index});
    break :blk list;
};

const rule_instructions = blk: {
    var list: [Limits.max_rules][]const u8 = undefined;
    for (0..Limits.max_rules) |index| list[index] = std.fmt.comptimePrint(
        "`user_request` changes the behavior that `rules[{d}]` describes (not merely code near it)",
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
};

pub const EvaluateError = error{ IncompleteJevAnswer, OutOfMemory };

pub fn evaluate(arena: Allocator, response: *const jev_contract.Response, rule_count: usize, with_proposal: bool) EvaluateError!Verdict {
    const scope = response.choice(scope_id) orelse return error.IncompleteJevAnswer;
    const high_stakes = response.noul(high_stakes_id) orelse return error.IncompleteJevAnswer;
    const skip = response.noul(skip_id) orelse return error.IncompleteJevAnswer;
    const clear = response.noul(clear_id) orelse return error.IncompleteJevAnswer;
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
    };
    if (skip >= skip_threshold) return verdict;
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
            "Then show it to the user and ask them to approve it. Do not set the status yourself and do not change other files " ++
            "until it is approved; the user approves by replying yes or with /sdd approve.",
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
    try std.testing.expectEqual(@as(usize, 6), without.len);
    try std.testing.expectEqualStrings("rule_1", without[5].id);
    const with = try questions(arena.allocator(), 40, true);
    try std.testing.expectEqual(@as(usize, 5 + Limits.max_rules), with.len);
    try std.testing.expectEqualStrings(approves_id, with[4].id);
}

test "evaluate routes high stakes to change and touched rules to spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stakes = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.8},"high_stakes":{"type":"noul","noul":0.9},"skip_process":{"type":"noul","noul":0.1},"clear":{"type":"noul","noul":0.9},"rule_0":{"type":"noul","noul":0.9}}}
    );
    defer stakes.deinit();
    const change = try evaluate(arena.allocator(), &stakes, 1, false);
    try std.testing.expectEqual(Route.change, change.route);

    var spec = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.9},"high_stakes":{"type":"noul","noul":0.1},"skip_process":{"type":"noul","noul":0.1},"clear":{"type":"noul","noul":0.9},"rule_0":{"type":"noul","noul":0.2},"rule_1":{"type":"noul","noul":0.8}}}
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
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"substantial","confidence":0.9},"high_stakes":{"type":"noul","noul":0.9},"skip_process":{"type":"noul","noul":0.9},"clear":{"type":"noul","noul":0.9}}}
    );
    defer skip.deinit();
    try std.testing.expectEqual(Route.fix, (try evaluate(arena.allocator(), &skip, 0, false)).route);

    var vague = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.5},"high_stakes":{"type":"noul","noul":0.2},"skip_process":{"type":"noul","noul":0.0},"clear":{"type":"noul","noul":0.2},"approves_proposal":{"type":"noul","noul":0.95}}}
    );
    defer vague.deinit();
    const unclear = try evaluate(arena.allocator(), &vague, 0, true);
    try std.testing.expectEqual(Route.unclear, unclear.route);
    try std.testing.expect(unclear.approves);

    var missing = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.9},"high_stakes":{"type":"noul","noul":0.1},"skip_process":{"type":"noul","noul":0.0},"clear":{"type":"noul","noul":0.9}}}
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
}
