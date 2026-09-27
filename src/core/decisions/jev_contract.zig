//! Typed questions and answers for Jev, TypeSafe AI's System One decision
//! model (`POST /v1/systemone`).
//!
//! Jev does not generate text. It receives a `state` and a set of atomic
//! questions and returns calibrated answers: `noul` (a 0-1 probability that a
//! statement holds), `choice` (one option from a fixed set) or `score` (a
//! level on an ordered scale). Callers compose answers in code; hard rules and
//! arithmetic never belong in a question.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Option = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const QuestionKind = union(enum) {
    noul,
    choice: []const Option,
    score: []const []const u8,
};

pub const Question = struct {
    id: []const u8,
    instructions: []const u8,
    kind: QuestionKind,
};

/// Writes a `/v1/systemone` request body. `state_json` must already be one
/// valid JSON value (string, object or array); it is embedded unchanged.
pub fn writeRequest(
    writer: *std.Io.Writer,
    model: []const u8,
    state_json: []const u8,
    questions: []const Question,
) !void {
    var jw: std.json.Stringify = .{ .writer = writer };
    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(model);
    try jw.objectField("state");
    try jw.beginWriteRaw();
    try writer.writeAll(state_json);
    jw.endWriteRaw();
    try jw.objectField("questions");
    try jw.beginObject();
    for (questions) |question| {
        try jw.objectField(question.id);
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(@tagName(question.kind));
        try jw.objectField("instructions");
        try jw.write(question.instructions);
        switch (question.kind) {
            .noul => {},
            .choice => |options| {
                try jw.objectField("criteria");
                try jw.beginObject();
                for (options) |option| {
                    try jw.objectField(option.name);
                    try jw.write(option.description);
                }
                try jw.endObject();
            },
            .score => |levels| {
                try jw.objectField("criteria");
                try jw.write(levels);
            },
        }
        try jw.endObject();
    }
    try jw.endObject();
    try jw.endObject();
}

pub const Answer = union(enum) {
    noul: f64,
    choice: struct { choice: []const u8, confidence: f64 },
    score: struct { score: f64, confidence: f64 },
};

pub const NamedAnswer = struct {
    id: []const u8,
    answer: Answer,
};

/// A parsed response. Strings borrow from the response arena; free with deinit.
pub const Response = struct {
    arena: std.heap.ArenaAllocator,
    model: []const u8,
    answers: []const NamedAnswer,
    input_tokens: u64,

    pub fn deinit(self: *Response) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Response, id: []const u8) ?Answer {
        for (self.answers) |named| {
            if (std.mem.eql(u8, named.id, id)) return named.answer;
        }
        return null;
    }

    /// The probability for a `noul` question, or null when it is missing or
    /// came back as another type. Missing answers must never read as "yes".
    pub fn noul(self: *const Response, id: []const u8) ?f64 {
        const answer = self.get(id) orelse return null;
        return switch (answer) {
            .noul => |value| value,
            else => null,
        };
    }

    pub fn choice(self: *const Response, id: []const u8) ?@FieldType(Answer, "choice") {
        const answer = self.get(id) orelse return null;
        return switch (answer) {
            .choice => |value| value,
            else => null,
        };
    }
};

pub const ParseError = Allocator.Error || error{InvalidJevResponse};

/// Parses a `/v1/systemone` response body. Answers with an unknown type or
/// out-of-range numbers make the whole response invalid.
pub fn parseResponse(alloc: Allocator, body: []const u8) ParseError!Response {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJevResponse,
    };
    if (root != .object) return error.InvalidJevResponse;
    const model = switch (root.object.get("model") orelse return error.InvalidJevResponse) {
        .string => |value| value,
        else => return error.InvalidJevResponse,
    };
    const answers_value = root.object.get("answers") orelse return error.InvalidJevResponse;
    if (answers_value != .object) return error.InvalidJevResponse;

    var answers: std.ArrayList(NamedAnswer) = .empty;
    var it = answers_value.object.iterator();
    while (it.next()) |entry| {
        try answers.append(a, .{
            .id = entry.key_ptr.*,
            .answer = try parseAnswer(entry.value_ptr.*),
        });
    }

    var input_tokens: u64 = 0;
    if (root.object.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("input_tokens")) |tokens| {
                if (tokens == .integer and tokens.integer >= 0) input_tokens = @intCast(tokens.integer);
            }
        }
    }

    return .{
        .arena = arena,
        .model = model,
        .answers = answers.items,
        .input_tokens = input_tokens,
    };
}

fn parseAnswer(value: std.json.Value) ParseError!Answer {
    if (value != .object) return error.InvalidJevResponse;
    const kind = switch (value.object.get("type") orelse return error.InvalidJevResponse) {
        .string => |text| text,
        else => return error.InvalidJevResponse,
    };
    if (std.mem.eql(u8, kind, "noul")) {
        return .{ .noul = try probability(value.object.get("noul")) };
    }
    if (std.mem.eql(u8, kind, "choice")) {
        const picked = switch (value.object.get("choice") orelse return error.InvalidJevResponse) {
            .string => |text| text,
            else => return error.InvalidJevResponse,
        };
        return .{ .choice = .{
            .choice = picked,
            .confidence = try probability(value.object.get("confidence")),
        } };
    }
    if (std.mem.eql(u8, kind, "score")) {
        const score = try number(value.object.get("score"));
        if (score < 0) return error.InvalidJevResponse;
        return .{ .score = .{
            .score = score,
            .confidence = try probability(value.object.get("confidence")),
        } };
    }
    return error.InvalidJevResponse;
}

fn number(value: ?std.json.Value) error{InvalidJevResponse}!f64 {
    return switch (value orelse return error.InvalidJevResponse) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => error.InvalidJevResponse,
    };
}

fn probability(value: ?std.json.Value) error{InvalidJevResponse}!f64 {
    const result = try number(value);
    if (!(result >= 0 and result <= 1)) return error.InvalidJevResponse;
    return result;
}

test "writeRequest embeds state and typed criteria" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeRequest(&out.writer, "jev-latest", "{\"message\":\"hi\"}", &.{
        .{ .id = "urgent", .instructions = "The `message` is urgent", .kind = .noul },
        .{ .id = "team", .instructions = "Which team", .kind = .{ .choice = &.{
            .{ .name = "billing", .description = "Payments" },
            .{ .name = "other" },
        } } },
        .{ .id = "tone", .instructions = "Tone", .kind = .{ .score = &.{ "calm", "angry" } } },
    });
    try std.testing.expectEqualStrings(
        "{\"model\":\"jev-latest\",\"state\":{\"message\":\"hi\"},\"questions\":{" ++
            "\"urgent\":{\"type\":\"noul\",\"instructions\":\"The `message` is urgent\"}," ++
            "\"team\":{\"type\":\"choice\",\"instructions\":\"Which team\",\"criteria\":{\"billing\":\"Payments\",\"other\":null}}," ++
            "\"tone\":{\"type\":\"score\",\"instructions\":\"Tone\",\"criteria\":[\"calm\",\"angry\"]}}}",
        out.written(),
    );
}

test "parseResponse reads answers from the documented response shape" {
    // Captured from a live jev-1.13.0 call.
    const body =
        \\{"model":"jev-1.13.0","answers":{"scope":{"type":"choice","choice":"small","confidence":0.96,"probabilities":{"small":0.97,"substantial":0.01,"trivial":0.02}},"plan_covers_request":{"type":"noul","noul":0.77},"claims_verified":{"type":"noul","noul":0.53}},"usage":{"input_tokens":512,"output_tokens":78}}
    ;
    var response = try parseResponse(std.testing.allocator, body);
    defer response.deinit();
    try std.testing.expectEqualStrings("jev-1.13.0", response.model);
    try std.testing.expectEqual(@as(u64, 512), response.input_tokens);
    try std.testing.expectEqual(@as(?f64, 0.77), response.noul("plan_covers_request"));
    try std.testing.expectEqual(@as(?f64, 0.53), response.noul("claims_verified"));
    try std.testing.expectEqualStrings("small", response.choice("scope").?.choice);
    try std.testing.expect(response.noul("scope") == null);
    try std.testing.expect(response.noul("missing") == null);
}

test "parseResponse reads integer probabilities and rejects invalid answers" {
    var response = try parseResponse(std.testing.allocator,
        \\{"model":"m","answers":{"a":{"type":"noul","noul":1},"b":{"type":"score","score":1.0,"confidence":1}}}
    );
    defer response.deinit();
    try std.testing.expectEqual(@as(?f64, 1.0), response.noul("a"));

    for ([_][]const u8{
        "not json",
        "{\"answers\":{}}",
        "{\"model\":\"m\",\"answers\":[]}",
        "{\"model\":\"m\",\"answers\":{\"a\":{\"type\":\"noul\",\"noul\":1.5}}}",
        "{\"model\":\"m\",\"answers\":{\"a\":{\"type\":\"noul\"}}}",
        "{\"model\":\"m\",\"answers\":{\"a\":{\"type\":\"essay\",\"text\":\"x\"}}}",
    }) |body| {
        try std.testing.expectError(error.InvalidJevResponse, parseResponse(std.testing.allocator, body));
    }
}
