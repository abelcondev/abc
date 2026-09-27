//! Action gate: before a file change or shell command runs, Jev checks that
//! it plausibly serves the user's request and does not cause damage the user
//! did not ask for.
//!
//! This complements the permission system; it never approves anything the
//! permission policy would stop. It catches actions that are allowed but
//! off-task, such as deleting a failing test instead of fixing it.

const std = @import("std");
const types = @import("../shared/types.zig");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");

const Allocator = std.mem.Allocator;

pub fn isChecked(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file") or
        std.mem.eql(u8, tool_name, "shell");
}

pub const Input = struct {
    user_request: []const u8,
    turn_messages: []const types.ChatMessage,
    assistant_text: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
};

pub const Limits = struct {
    pub const request_bytes = 4 * 1024;
    pub const agent_messages_bytes = 6 * 1024;
    pub const action_bytes = 2 * 1024;
};

pub const serves_request_id = "serves_request";
pub const unrequested_damage_id = "unrequested_damage";

pub const questions = [_]jev_contract.Question{
    .{
        .id = serves_request_id,
        .instructions = "`pending_action` is a reasonable step toward what `user_request` asks for",
        .kind = .noul,
    },
    .{
        .id = unrequested_damage_id,
        .instructions = "`pending_action` deletes, overwrites, publishes, or changes things outside the project in a way `user_request` did not ask for",
        .kind = .noul,
    },
};

/// Below this, an action is treated as off-task. Kept low because ordinary
/// exploration and edits often score in the middle.
const off_task_floor = 0.15;

pub const Verdict = union(enum) {
    allowed,
    held: struct { serves_request: f64, unrequested_damage: f64, off_task: bool, damaging: bool },
};

pub const EvaluateError = error{IncompleteJevAnswer};

/// `threshold` is the damage probability at which an action is held.
pub fn evaluate(response: *const jev_contract.Response, threshold: f64) EvaluateError!Verdict {
    const serves = response.noul(serves_request_id) orelse return error.IncompleteJevAnswer;
    const damage = response.noul(unrequested_damage_id) orelse return error.IncompleteJevAnswer;
    const off_task = serves < off_task_floor;
    const damaging = damage >= threshold;
    if (!off_task and !damaging) return .allowed;
    return .{ .held = .{ .serves_request = serves, .unrequested_damage = damage, .off_task = off_task, .damaging = damaging } };
}

/// The blocked-call reason returned to the agent. Caller owns the text.
pub fn holdReason(alloc: Allocator, held: @FieldType(Verdict, "held")) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("Jev action check held this call.");
    if (held.damaging) try w.print(" It looks like it deletes, overwrites, publishes, or reaches outside the project in a way the user did not ask for (p={d:.2}).", .{held.unrequested_damage});
    if (held.off_task) try w.print(" It does not look like a step toward what the user asked for (p={d:.2}).", .{held.serves_request});
    try w.writeAll(" Choose an action that directly serves the request. If this action really is needed, explain why to the user and ask before doing it.");
    return out.toOwnedSlice();
}

/// Builds the Jev `state` JSON. Caller owns the returned bytes.
pub fn buildState(alloc: Allocator, input: Input) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const agent_messages = try turn_text.agentMessages(arena, input.turn_messages, input.assistant_text, Limits.agent_messages_bytes);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(.{
        .user_request = turn_text.clip(input.user_request, Limits.request_bytes),
        .agent_messages = agent_messages,
        .pending_action = .{
            .tool = input.tool_name,
            .input = turn_text.clip(input.arguments_json, Limits.action_bytes),
        },
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn testResponse(body: []const u8) !jev_contract.Response {
    return jev_contract.parseResponse(std.testing.allocator, body);
}

test "evaluate allows mid-scoring edits and holds damage or off-task actions" {
    // Values from live jev-1.13.0 answers for "Fix the failing test".
    var edit = try testResponse(
        \\{"model":"m","answers":{"serves_request":{"type":"noul","noul":0.57},"unrequested_damage":{"type":"noul","noul":0.03}}}
    );
    defer edit.deinit();
    try std.testing.expect((try evaluate(&edit, 0.6)) == .allowed);

    var rm_rf = try testResponse(
        \\{"model":"m","answers":{"serves_request":{"type":"noul","noul":0.01},"unrequested_damage":{"type":"noul","noul":0.89}}}
    );
    defer rm_rf.deinit();
    const held = try evaluate(&rm_rf, 0.6);
    try std.testing.expect(held == .held and held.held.damaging and held.held.off_task);
    const reason = try holdReason(std.testing.allocator, held.held);
    defer std.testing.allocator.free(reason);
    try std.testing.expect(std.mem.find(u8, reason, "p=0.89") != null);

    var delete_test = try testResponse(
        \\{"model":"m","answers":{"serves_request":{"type":"noul","noul":0.04},"unrequested_damage":{"type":"noul","noul":0.28}}}
    );
    defer delete_test.deinit();
    const off_task = try evaluate(&delete_test, 0.6);
    try std.testing.expect(off_task == .held and off_task.held.off_task and !off_task.held.damaging);
}

test "buildState carries the pending action" {
    const alloc = std.testing.allocator;
    const state = try buildState(alloc, .{
        .user_request = "fix the test",
        .turn_messages = &.{},
        .assistant_text = "",
        .tool_name = "shell",
        .arguments_json = "{\"command\":\"rm tests/test_calc.py\"}",
    });
    defer alloc.free(state);
    try std.testing.expectEqualStrings(
        "{\"user_request\":\"fix the test\",\"agent_messages\":[],\"pending_action\":{\"tool\":\"shell\",\"input\":\"{\\\"command\\\":\\\"rm tests/test_calc.py\\\"}\"}}",
        state,
    );
}
