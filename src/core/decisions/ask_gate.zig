//! Ask gate: when the agent asks the user a multiple-choice question, Jev
//! answers it only when the request or the agent's own findings already
//! settle the answer. Preferences and new decisions still go to the user.
//!
//! Each question gets two atomic checks in one call: which option the context
//! supports (`choice`) and whether the context states or implies the answer
//! at all (`noul`). A confident pick without grounding is not enough; Jev
//! picks an option confidently even when nothing in the context supports it.

const std = @import("std");
const types = @import("../shared/types.zig");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");

const Allocator = std.mem.Allocator;

pub const tool_name = "ask_user_question";
pub const max_questions = 4;
const max_options = 6;

pub const Limits = struct {
    pub const request_bytes = 4 * 1024;
    pub const agent_messages_bytes = 12 * 1024;
};

pub const Choice = struct {
    question: []const u8,
    labels: []const []const u8,
};

pub const Input = struct {
    user_request: []const u8,
    turn_messages: []const types.ChatMessage,
    assistant_text: []const u8,
    arguments_json: []const u8,
};

/// A parsed `ask_user_question` call. Strings borrow from `arena`.
pub const Parsed = struct {
    choices: []const Choice,
    questions: []const jev_contract.Question,
};

const answer_ids = [_][]const u8{ "answer_0", "answer_1", "answer_2", "answer_3" };
const grounded_ids = [_][]const u8{ "grounded_0", "grounded_1", "grounded_2", "grounded_3" };
const answer_instructions = blk: {
    var list: [max_questions][]const u8 = undefined;
    for (0..max_questions) |index| list[index] = std.fmt.comptimePrint(
        "The option that `user_request` and `agent_messages` support as the answer to `questions[{d}]`",
        .{index},
    );
    break :blk list;
};
const grounded_instructions = blk: {
    var list: [max_questions][]const u8 = undefined;
    for (0..max_questions) |index| list[index] = std.fmt.comptimePrint(
        "`user_request` or `agent_messages` state or directly imply which answer the user wants to `questions[{d}]`",
        .{index},
    );
    break :blk list;
};

/// Parses the call into Jev questions. Returns null for shapes the gate does
/// not handle (duplicate labels, too many options); the user is asked then.
pub fn parse(arena: Allocator, arguments_json: []const u8) !?Parsed {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return null;
    if (root != .object) return null;
    const list = root.object.get("questions") orelse return null;
    if (list != .array or list.array.items.len == 0 or list.array.items.len > max_questions) return null;

    const choices = try arena.alloc(Choice, list.array.items.len);
    var questions: std.ArrayList(jev_contract.Question) = .empty;
    for (list.array.items, 0..) |item, index| {
        if (item != .object) return null;
        const question = switch (item.object.get("question") orelse return null) {
            .string => |text| text,
            else => return null,
        };
        const options_value = item.object.get("options") orelse return null;
        if (options_value != .array or options_value.array.items.len < 2 or options_value.array.items.len > max_options) return null;
        const labels = try arena.alloc([]const u8, options_value.array.items.len);
        const options = try arena.alloc(jev_contract.Option, options_value.array.items.len);
        for (options_value.array.items, 0..) |option, option_index| {
            if (option != .object) return null;
            const label = switch (option.object.get("label") orelse return null) {
                .string => |text| text,
                else => return null,
            };
            if (label.len == 0) return null;
            for (labels[0..option_index]) |seen| if (std.mem.eql(u8, seen, label)) return null;
            const description: ?[]const u8 = if (option.object.get("description")) |value| switch (value) {
                .string => |text| text,
                else => null,
            } else null;
            labels[option_index] = label;
            options[option_index] = .{ .name = label, .description = description };
        }
        choices[index] = .{ .question = question, .labels = labels };
        try questions.append(arena, .{ .id = answer_ids[index], .instructions = answer_instructions[index], .kind = .{ .choice = options } });
        try questions.append(arena, .{ .id = grounded_ids[index], .instructions = grounded_instructions[index], .kind = .noul });
    }
    return .{ .choices = choices, .questions = questions.items };
}

/// Builds the Jev `state` JSON. Caller owns the returned bytes.
pub fn buildState(alloc: Allocator, arena: Allocator, input: Input, parsed: Parsed) ![]u8 {
    const agent_messages = try turn_text.agentMessages(arena, input.turn_messages, input.assistant_text, Limits.agent_messages_bytes);
    const question_texts = try arena.alloc([]const u8, parsed.choices.len);
    for (parsed.choices, 0..) |choice, index| question_texts[index] = choice.question;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(.{
        .user_request = turn_text.clip(input.user_request, Limits.request_bytes),
        .agent_messages = agent_messages,
        .questions = question_texts,
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub const Answer = struct {
    question: []const u8,
    label: []const u8,
    confidence: f64,
};

pub const Verdict = union(enum) {
    /// Every question is settled by the context; the answers are final.
    answered: []const Answer,
    /// At least one question needs the user.
    ask_user,
};

pub const EvaluateError = Allocator.Error || error{IncompleteJevAnswer};

/// Both the pick's confidence and the grounding must reach `threshold`.
pub fn evaluate(arena: Allocator, parsed: Parsed, response: *const jev_contract.Response, threshold: f64) EvaluateError!Verdict {
    const answers = try arena.alloc(Answer, parsed.choices.len);
    var all_settled = true;
    for (parsed.choices, 0..) |choice, index| {
        const pick = response.choice(answer_ids[index]) orelse return error.IncompleteJevAnswer;
        const grounded = response.noul(grounded_ids[index]) orelse return error.IncompleteJevAnswer;
        var known = false;
        for (choice.labels) |label| known = known or std.mem.eql(u8, label, pick.choice);
        if (!known) return error.IncompleteJevAnswer;
        if (pick.confidence < threshold or grounded < threshold) all_settled = false;
        answers[index] = .{ .question = choice.question, .label = pick.choice, .confidence = @min(pick.confidence, grounded) };
    }
    return if (all_settled) .{ .answered = answers } else .ask_user;
}

/// The tool result returned to the agent in place of asking. Caller owns it.
pub fn answerText(alloc: Allocator, answers: []const Answer) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("Jev answered for the user because the request and your findings already settle it:");
    for (answers) |answer| try w.print("\n- {s} → {s} (p={d:.2})", .{ answer.question, answer.label, answer.confidence });
    try w.writeAll("\nContinue with these choices and mention them in your final answer so the user can change them.");
    return out.toOwnedSlice();
}

test "parse builds a choice and a grounding question per user question" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = (try parse(arena_state.allocator(),
        \\{"questions":[{"question":"Which framework?","options":[{"label":"pytest","description":"already used"},{"label":"unittest"}]}]}
    )).?;
    try std.testing.expectEqual(@as(usize, 1), parsed.choices.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.questions.len);
    try std.testing.expectEqualStrings("answer_0", parsed.questions[0].id);
    try std.testing.expectEqualStrings("unittest", parsed.questions[0].kind.choice[1].name);
    try std.testing.expect(parsed.questions[0].kind.choice[1].description == null);
    try std.testing.expectEqualStrings("grounded_0", parsed.questions[1].id);
    try std.testing.expect(std.mem.find(u8, parsed.questions[1].instructions, "`questions[0]`") != null);
}

test "parse rejects duplicate labels and malformed calls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try parse(arena, "{\"questions\":[{\"question\":\"q\",\"options\":[{\"label\":\"a\"},{\"label\":\"a\"}]}]}")) == null);
    try std.testing.expect((try parse(arena, "{\"questions\":[]}")) == null);
    try std.testing.expect((try parse(arena, "not json")) == null);
}

test "evaluate answers only grounded, confident questions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = (try parse(arena,
        \\{"questions":[{"question":"Which framework?","options":[{"label":"pytest"},{"label":"unittest"}]},{"question":"Which database?","options":[{"label":"PostgreSQL"},{"label":"SQLite"}]}]}
    )).?;
    // Live jev-1.13.0 answers: the database pick is confident but ungrounded.
    var mixed = try jev_contract.parseResponse(std.testing.allocator,
        \\{"model":"m","answers":{"answer_0":{"type":"choice","choice":"pytest","confidence":1.0},"grounded_0":{"type":"noul","noul":0.94},"answer_1":{"type":"choice","choice":"SQLite","confidence":0.97},"grounded_1":{"type":"noul","noul":0.05}}}
    );
    defer mixed.deinit();
    try std.testing.expect((try evaluate(arena, parsed, &mixed, 0.8)) == .ask_user);

    var settled = try jev_contract.parseResponse(std.testing.allocator,
        \\{"model":"m","answers":{"answer_0":{"type":"choice","choice":"pytest","confidence":1.0},"grounded_0":{"type":"noul","noul":0.94},"answer_1":{"type":"choice","choice":"SQLite","confidence":0.9},"grounded_1":{"type":"noul","noul":0.85}}}
    );
    defer settled.deinit();
    const verdict = try evaluate(arena, parsed, &settled, 0.8);
    try std.testing.expect(verdict == .answered);
    const text = try answerText(std.testing.allocator, verdict.answered);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "Which database? → SQLite (p=0.85)") != null);
}
