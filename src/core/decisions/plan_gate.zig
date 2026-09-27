//! Plan gate: before the first file change of a substantial request, Jev
//! checks that the agent has stated a plan that covers the request.
//!
//! Jev classifies the request's scope and judges the plan found in the
//! agent's messages for this turn. Trivial and small requests pass without a
//! plan. A substantial request without an adequate plan gets its file change
//! held once with instructions to present one first; the change itself is
//! never judged here.

const std = @import("std");
const types = @import("../shared/types.zig");
const jev_contract = @import("jev_contract.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

/// Tools that change files. Shell commands are left to the permission system.
pub fn isFileChange(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "edit_file");
}

pub const Input = struct {
    user_request: []const u8,
    turn_messages: []const ChatMessage,
    assistant_text: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
};

pub const Limits = struct {
    pub const request_bytes = 6 * 1024;
    pub const agent_messages_bytes = 16 * 1024;
    pub const change_bytes = 600;
};

pub const scope_id = "scope";
pub const plan_present_id = "plan_present";
pub const plan_covers_id = "plan_covers";
pub const plan_extra_id = "plan_extra";

pub const questions = [_]jev_contract.Question{
    .{
        .id = scope_id,
        .instructions = "How much work `user_request` asks a coding agent to do",
        .kind = .{ .choice = &.{
            .{ .name = "trivial", .description = "a one-line, cosmetic, or obvious change" },
            .{ .name = "small", .description = "a focused change in one place with a clear approach" },
            .{ .name = "substantial", .description = "several files or components, new features, data formats, security, persistence, or an unclear approach" },
        } },
    },
    .{
        .id = plan_present_id,
        .instructions = "`agent_messages` state a step-by-step plan for `user_request` that says what will change and how the result will be checked",
        .kind = .noul,
    },
    .{
        .id = plan_covers_id,
        .instructions = "The plan in `agent_messages` covers everything `user_request` asks for",
        .kind = .noul,
    },
    .{
        .id = plan_extra_id,
        .instructions = "The plan in `agent_messages` includes significant work that `user_request` did not ask for",
        .kind = .noul,
    },
};

/// Confidence needed to treat a request as substantial.
const substantial_confidence = 0.6;
/// Probability above which the plan counts as adding unrequested work.
const extra_limit = 0.5;

pub const Issue = enum { no_plan, incomplete_plan, extra_work };

pub const Verdict = union(enum) {
    /// The request is trivial or small; no plan is required this turn.
    not_substantial,
    approved,
    needs_plan: struct {
        scope_confidence: f64,
        issues: std.EnumSet(Issue),
    },
};

pub const EvaluateError = error{IncompleteJevAnswer};

pub fn evaluate(response: *const jev_contract.Response, threshold: f64) EvaluateError!Verdict {
    const scope = response.choice(scope_id) orelse return error.IncompleteJevAnswer;
    const present = response.noul(plan_present_id) orelse return error.IncompleteJevAnswer;
    const covers = response.noul(plan_covers_id) orelse return error.IncompleteJevAnswer;
    const extra = response.noul(plan_extra_id) orelse return error.IncompleteJevAnswer;

    if (!std.mem.eql(u8, scope.choice, "substantial") or scope.confidence < substantial_confidence) {
        return .not_substantial;
    }
    var issues = std.EnumSet(Issue).initEmpty();
    if (present < threshold) {
        issues.insert(.no_plan);
    } else {
        if (covers < threshold) issues.insert(.incomplete_plan);
        if (extra >= extra_limit) issues.insert(.extra_work);
    }
    if (issues.count() == 0) return .approved;
    return .{ .needs_plan = .{ .scope_confidence = scope.confidence, .issues = issues } };
}

/// The blocked-call reason returned to the agent. Caller owns the text.
pub fn blockReason(alloc: Allocator, verdict: @FieldType(Verdict, "needs_plan")) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("Jev plan gate: this request looks substantial, so the file change was held.");
    if (verdict.issues.contains(.no_plan)) try w.writeAll(" No plan has been stated yet.");
    if (verdict.issues.contains(.incomplete_plan)) try w.writeAll(" The stated plan does not cover everything the user asked for.");
    if (verdict.issues.contains(.extra_work)) try w.writeAll(" The stated plan adds work the user did not ask for.");
    try w.writeAll(
        " Before changing files, write a short plan in your reply: numbered steps saying what you will change, " ++
            "and acceptance criteria you will check with tools (tests, a build, or reading the result back). " ++
            "Keep it to what the user asked, then make the change in the same reply.",
    );
    return out.toOwnedSlice();
}

/// Builds the Jev `state` JSON. Caller owns the returned bytes.
pub fn buildState(alloc: Allocator, input: Input) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var texts: std.ArrayList([]const u8) = .empty;
    for (input.turn_messages) |message| {
        if (message.role != .assistant) continue;
        const content = std.mem.trim(u8, message.content orelse "", " \t\r\n");
        if (content.len != 0) try texts.append(arena, content);
    }
    const current = std.mem.trim(u8, input.assistant_text, " \t\r\n");
    if (current.len != 0) try texts.append(arena, current);

    // Keep the most recent agent messages within the budget.
    var start = texts.items.len;
    var used: usize = 0;
    while (start > 0) {
        const cost = texts.items[start - 1].len;
        if (used + cost > Limits.agent_messages_bytes) break;
        used += cost;
        start -= 1;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("user_request");
    try jw.write(clip(input.user_request, Limits.request_bytes));
    try jw.objectField("agent_messages");
    try jw.write(texts.items[start..]);
    try jw.objectField("pending_change");
    try jw.write(.{
        .tool = input.tool_name,
        .input = clip(input.arguments_json, Limits.change_bytes),
    });
    try jw.endObject();
    return out.toOwnedSlice();
}

fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

fn testResponse(body: []const u8) !jev_contract.Response {
    return jev_contract.parseResponse(std.testing.allocator, body);
}

test "evaluate lets small requests through without a plan" {
    var response = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"small","confidence":0.9},"plan_present":{"type":"noul","noul":0.0},"plan_covers":{"type":"noul","noul":0.0},"plan_extra":{"type":"noul","noul":0.0}}}
    );
    defer response.deinit();
    try std.testing.expect((try evaluate(&response, 0.5)) == .not_substantial);
}

test "evaluate holds substantial requests until a covering plan exists" {
    var missing = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"substantial","confidence":0.9},"plan_present":{"type":"noul","noul":0.1},"plan_covers":{"type":"noul","noul":0.1},"plan_extra":{"type":"noul","noul":0.0}}}
    );
    defer missing.deinit();
    const verdict = try evaluate(&missing, 0.5);
    try std.testing.expect(verdict == .needs_plan);
    try std.testing.expect(verdict.needs_plan.issues.contains(.no_plan));
    const reason = try blockReason(std.testing.allocator, verdict.needs_plan);
    defer std.testing.allocator.free(reason);
    try std.testing.expect(std.mem.find(u8, reason, "No plan has been stated yet.") != null);

    var extra = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"substantial","confidence":0.9},"plan_present":{"type":"noul","noul":0.9},"plan_covers":{"type":"noul","noul":0.9},"plan_extra":{"type":"noul","noul":0.8}}}
    );
    defer extra.deinit();
    const extra_verdict = try evaluate(&extra, 0.5);
    try std.testing.expect(extra_verdict.needs_plan.issues.contains(.extra_work));

    var good = try testResponse(
        \\{"model":"m","answers":{"scope":{"type":"choice","choice":"substantial","confidence":0.9},"plan_present":{"type":"noul","noul":0.9},"plan_covers":{"type":"noul","noul":0.8},"plan_extra":{"type":"noul","noul":0.1}}}
    );
    defer good.deinit();
    try std.testing.expect((try evaluate(&good, 0.5)) == .approved);
}

test "buildState collects agent messages and the pending change" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .content = "Looking at the schema first." },
        .{ .role = .tool, .content = "file contents" },
    };
    const state = try buildState(alloc, .{
        .user_request = "add a users table",
        .turn_messages = &messages,
        .assistant_text = "Plan: 1. add migration 2. run tests",
        .tool_name = "write_file",
        .arguments_json = "{\"path\":\"db/001.sql\"}",
    });
    defer alloc.free(state);
    try std.testing.expectEqualStrings(
        "{\"user_request\":\"add a users table\",\"agent_messages\":[\"Looking at the schema first.\",\"Plan: 1. add migration 2. run tests\"]," ++
            "\"pending_change\":{\"tool\":\"write_file\",\"input\":\"{\\\"path\\\":\\\"db/001.sql\\\"}\"}}",
        state,
    );
}

test "isFileChange covers write and edit only" {
    try std.testing.expect(isFileChange("write_file"));
    try std.testing.expect(isFileChange("edit_file"));
    try std.testing.expect(!isFileChange("shell"));
    try std.testing.expect(!isFileChange("read_file"));
}
