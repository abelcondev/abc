//! Completion gate: before a turn ends, Jev checks that the agent's final
//! answer is backed by what actually happened in the turn.
//!
//! The state holds the user's request, the final message and bounded tool
//! evidence. Atomic `noul` questions ask whether the requested work was done
//! and whether every claim is supported; code combines the answers. A failed
//! check sends the agent back once with the reasons. Jev never sees hidden
//! instructions from the harness, and its answers never authorize tools.

const std = @import("std");
const types = @import("../shared/types.zig");
const jev_contract = @import("jev_contract.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const Input = struct {
    user_request: []const u8,
    final_message: []const u8,
    turn_messages: []const ChatMessage,
};

pub const Limits = struct {
    pub const request_bytes = 6 * 1024;
    pub const final_message_bytes = 6 * 1024;
    pub const evidence_bytes = 48 * 1024;
    pub const tool_input_bytes = 400;
    pub const tool_output_head_bytes = 600;
    pub const tool_output_tail_bytes = 1400;
};

pub const task_kind_id = "task_kind";
pub const work_done_id = "work_done";
pub const claims_supported_id = "claims_supported";
pub const not_finished_id = "not_finished";
pub const needs_user_id = "needs_user";
pub const checked_id = "checked";

pub const questions = [_]jev_contract.Question{
    .{
        .id = task_kind_id,
        .instructions = "What `user_request` asks the coding agent to do",
        .kind = .{ .choice = &.{
            .{ .name = "work", .description = "change files, run commands, fix, build, test, or produce an artifact" },
            .{ .name = "information", .description = "only explain, answer a question, review, or give an opinion without changing anything" },
            .{ .name = "conversation", .description = "greeting, thanks, or small talk" },
        } },
    },
    .{
        .id = work_done_id,
        .instructions = "The tool results in `evidence` show that the agent actually carried out the work that `user_request` asks for",
        .kind = .noul,
    },
    .{
        .id = claims_supported_id,
        .instructions = "Every statement in `final_message` about work that was done or checks that passed is backed by a matching tool result in `evidence`",
        .kind = .noul,
    },
    // Two atomic questions: a single "blocked or asks the user" question
    // also fired on optional offers such as "want me to commit?".
    .{
        .id = not_finished_id,
        .instructions = "`final_message` says that some of the work `user_request` asks for was not done or could not be done",
        .kind = .noul,
    },
    .{
        .id = needs_user_id,
        .instructions = "`final_message` asks the user for information or a decision without which the work in `user_request` cannot be finished",
        .kind = .noul,
    },
    .{
        .id = checked_id,
        .instructions = "After its last change, the agent ran a check in `evidence` (tests, a build, running the program, or reading the result back) and that check succeeded",
        .kind = .noul,
    },
};

/// Confidence above which a non-work request skips the gate.
const skip_confidence = 0.5;
/// Probability above which an honest "blocked / need input" answer passes.
const blocker_pass = 0.6;

pub const Failure = enum { work_not_done, unsupported_claims };

pub const Verdict = union(enum) {
    /// The request did not ask for work, or the agent reported a blocker.
    skipped: []const u8,
    passed,
    failed: struct {
        work_done: f64,
        claims_supported: f64,
        failures: std.EnumSet(Failure),
    },
};

pub const EvaluateError = error{IncompleteJevAnswer};

/// Combines Jev's answers. Missing answers are an error, never a pass.
pub fn evaluate(response: *const jev_contract.Response, threshold: f64) EvaluateError!Verdict {
    const kind = response.choice(task_kind_id) orelse return error.IncompleteJevAnswer;
    const work_done = response.noul(work_done_id) orelse return error.IncompleteJevAnswer;
    const claims_supported = response.noul(claims_supported_id) orelse return error.IncompleteJevAnswer;
    const not_finished = response.noul(not_finished_id) orelse return error.IncompleteJevAnswer;
    const needs_user = response.noul(needs_user_id) orelse return error.IncompleteJevAnswer;

    if (!std.mem.eql(u8, kind.choice, "work") and kind.confidence >= skip_confidence) {
        return .{ .skipped = "not a work request" };
    }
    if (@max(not_finished, needs_user) >= blocker_pass) return .{ .skipped = "agent reported a blocker or asked the user" };

    var failures = std.EnumSet(Failure).initEmpty();
    if (work_done < threshold) failures.insert(.work_not_done);
    if (claims_supported < threshold) failures.insert(.unsupported_claims);
    if (failures.count() == 0) return .passed;
    return .{ .failed = .{
        .work_done = work_done,
        .claims_supported = claims_supported,
        .failures = failures,
    } };
}

/// The synthetic continuation sent to the agent after a failed check.
/// Caller owns the returned text.
pub fn feedback(alloc: Allocator, verdict: @FieldType(Verdict, "failed")) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("Jev, an independent completion check, could not confirm that this turn is finished:\n");
    if (verdict.failures.contains(.work_not_done)) {
        try w.print("- The tool results do not show that the requested work was carried out (p={d:.2}).\n", .{verdict.work_done});
    }
    if (verdict.failures.contains(.unsupported_claims)) {
        try w.print("- Some claims in the final answer are not backed by tool results (p={d:.2}).\n", .{verdict.claims_supported});
    }
    try w.writeAll(
        "Before finishing, verify the work with tools (run the relevant tests or build, or read back the changed files), " ++
            "complete anything that is missing, and then give a final answer that only claims what the evidence shows. " ++
            "If something cannot be done, say so plainly instead of claiming it.",
    );
    return out.toOwnedSlice();
}

/// Builds the Jev `state` JSON. Caller owns the returned bytes.
pub fn buildState(alloc: Allocator, input: Input) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const all = try collectEvidence(arena, input.turn_messages);
    // Keep the most recent evidence within the byte budget.
    var start = all.len;
    var used: usize = 0;
    while (start > 0) {
        const cost = all[start - 1].cost();
        if (used + cost > Limits.evidence_bytes) break;
        used += cost;
        start -= 1;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("user_request");
    try jw.write(try clip(arena, input.user_request, Limits.request_bytes));
    try jw.objectField("final_message");
    try jw.write(try clip(arena, input.final_message, Limits.final_message_bytes));
    try jw.objectField("evidence");
    try jw.write(all[start..]);
    if (start > 0) {
        try jw.objectField("earlier_evidence_omitted");
        try jw.write(start);
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

const Evidence = struct {
    tool: []const u8,
    input: []const u8,
    status: []const u8,
    output: []const u8,

    fn cost(self: Evidence) usize {
        return self.tool.len + self.input.len + self.status.len + self.output.len + 64;
    }
};

fn collectEvidence(arena: Allocator, messages: []const ChatMessage) ![]const Evidence {
    var calls: std.StringHashMapUnmanaged(types.ToolCall) = .empty;
    var evidence: std.ArrayList(Evidence) = .empty;
    for (messages) |message| {
        switch (message.role) {
            .assistant => for (message.tool_calls) |call| try calls.put(arena, call.id, call),
            .tool => {
                const call = if (message.tool_call_id) |id| calls.get(id) else null;
                const tool = message.tool_name orelse if (call) |known| known.name else "tool";
                try evidence.append(arena, .{
                    .tool = tool,
                    .input = if (call) |known| try clip(arena, known.arguments_json, Limits.tool_input_bytes) else "",
                    .status = if (message.tool_result_status) |status| @tagName(status) else "unknown",
                    .output = try headTail(arena, message.content orelse ""),
                });
            },
            .system, .user => {},
        }
    }
    return evidence.items;
}

fn clip(arena: Allocator, text: []const u8, max: usize) ![]const u8 {
    if (text.len <= max) return text;
    return std.fmt.allocPrint(arena, "{s}… [truncated]", .{validPrefix(text[0..max])});
}

/// Keeps the start and the end of long tool output; test and build results
/// usually end with the summary that matters.
fn headTail(arena: Allocator, text: []const u8) ![]const u8 {
    const head = Limits.tool_output_head_bytes;
    const tail = Limits.tool_output_tail_bytes;
    if (text.len <= head + tail) return text;
    return std.fmt.allocPrint(arena, "{s}\n… [{d} bytes omitted] …\n{s}", .{
        validPrefix(text[0..head]),
        text.len - head - tail,
        validSuffix(text[text.len - tail ..]),
    });
}

fn validPrefix(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) end -= 1;
    return bytes[0..end];
}

fn validSuffix(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and !std.unicode.utf8ValidateSlice(bytes[start..])) start += 1;
    return bytes[start..];
}

fn testResponse(body: []const u8) !jev_contract.Response {
    return jev_contract.parseResponse(std.testing.allocator, body);
}

test "evaluate passes supported work and fails unsupported claims" {
    var passed = try testResponse(
        \\{"model":"m","answers":{"task_kind":{"type":"choice","choice":"work","confidence":0.9},"work_done":{"type":"noul","noul":0.9},"claims_supported":{"type":"noul","noul":0.8},"not_finished":{"type":"noul","noul":0.1},"needs_user":{"type":"noul","noul":0.1},"checked":{"type":"noul","noul":0.7}}}
    );
    defer passed.deinit();
    try std.testing.expect((try evaluate(&passed, 0.5)) == .passed);

    var failed = try testResponse(
        \\{"model":"m","answers":{"task_kind":{"type":"choice","choice":"work","confidence":0.9},"work_done":{"type":"noul","noul":0.8},"claims_supported":{"type":"noul","noul":0.2},"not_finished":{"type":"noul","noul":0.1},"needs_user":{"type":"noul","noul":0.1},"checked":{"type":"noul","noul":0.1}}}
    );
    defer failed.deinit();
    const verdict = try evaluate(&failed, 0.5);
    try std.testing.expect(verdict == .failed);
    try std.testing.expect(verdict.failed.failures.contains(.unsupported_claims));
    try std.testing.expect(!verdict.failed.failures.contains(.work_not_done));
    const text = try feedback(std.testing.allocator, verdict.failed);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "not backed by tool results (p=0.20)") != null);
    try std.testing.expect(std.mem.find(u8, text, "requested work was carried out") == null);
}

test "evaluate skips non-work requests and honest blockers" {
    var chat = try testResponse(
        \\{"model":"m","answers":{"task_kind":{"type":"choice","choice":"information","confidence":0.8},"work_done":{"type":"noul","noul":0.0},"claims_supported":{"type":"noul","noul":0.1},"not_finished":{"type":"noul","noul":0.0},"needs_user":{"type":"noul","noul":0.0},"checked":{"type":"noul","noul":0.0}}}
    );
    defer chat.deinit();
    try std.testing.expect((try evaluate(&chat, 0.5)) == .skipped);

    var blocked = try testResponse(
        \\{"model":"m","answers":{"task_kind":{"type":"choice","choice":"work","confidence":0.9},"work_done":{"type":"noul","noul":0.1},"claims_supported":{"type":"noul","noul":0.9},"not_finished":{"type":"noul","noul":0.9},"needs_user":{"type":"noul","noul":0.2},"checked":{"type":"noul","noul":0.0}}}
    );
    defer blocked.deinit();
    try std.testing.expect((try evaluate(&blocked, 0.5)) == .skipped);
}

test "evaluate treats a missing answer as incomplete, not a pass" {
    var partial = try testResponse(
        \\{"model":"m","answers":{"task_kind":{"type":"choice","choice":"work","confidence":0.9},"work_done":{"type":"noul","noul":0.9}}}
    );
    defer partial.deinit();
    try std.testing.expectError(error.IncompleteJevAnswer, evaluate(&partial, 0.5));
}

test "buildState pairs tool calls with results and keeps recent evidence" {
    const alloc = std.testing.allocator;
    const long_output = "x" ** 5000 ++ "12 passed, 0 failed";
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "fix the test" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "c1", .name = "shell", .arguments_json = "{\"command\":\"zig build test\"}" }} },
        .{ .role = .tool, .tool_call_id = "c1", .tool_name = "shell", .content = long_output, .tool_result_status = .success },
    };
    const state = try buildState(alloc, .{
        .user_request = "fix the test",
        .final_message = "Fixed; all tests pass.",
        .turn_messages = &messages,
    });
    defer alloc.free(state);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, state, .{});
    defer parsed.deinit();
    const evidence = parsed.value.object.get("evidence").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), evidence.len);
    try std.testing.expectEqualStrings("shell", evidence[0].object.get("tool").?.string);
    try std.testing.expectEqualStrings("success", evidence[0].object.get("status").?.string);
    try std.testing.expectEqualStrings("{\"command\":\"zig build test\"}", evidence[0].object.get("input").?.string);
    const output = evidence[0].object.get("output").?.string;
    try std.testing.expect(std.mem.endsWith(u8, output, "12 passed, 0 failed"));
    try std.testing.expect(output.len < long_output.len);
    try std.testing.expect(parsed.value.object.get("earlier_evidence_omitted") == null);
}
