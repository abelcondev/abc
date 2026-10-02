//! Claim check: a turn-end note, without a model call, when the final
//! answer says the tests pass but no passing test run follows the turn's
//! last source change.
//!
//! The note goes to the user only. The agent is not sent back, so a missed
//! claim costs one line instead of a model round.

const std = @import("std");
const types = @import("../shared/types.zig");
const tdd_gate = @import("tdd_gate.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const note_text = "· fx: the answer says the tests pass, but no passing test run follows the last code change in this turn.";

/// Phrases that claim a passing test run, matched case-insensitively.
const claims = [_][]const u8{
    "tests pass",
    "test pass",
    "tests passed",
    "all tests",
    " 0 fail",
    "0 failed",
    "tests green",
    "all green",
    "pasan los tests",
    "los tests pasan",
    "tests pasan",
    "en verde",
    "todo verde",
};

/// Whether `text` claims that tests pass.
pub fn claimsGreen(text: []const u8) bool {
    var buf: [8 * 1024]u8 = undefined;
    const clipped = text[0..@min(text.len, buf.len)];
    const lower = std.ascii.lowerString(&buf, clipped);
    for (claims) |phrase| {
        if (std.mem.find(u8, lower, phrase) != null) return true;
    }
    return false;
}

/// The note to show, or null when the claim is backed or absent.
pub fn check(arena: Allocator, final_message: []const u8, messages: []const ChatMessage, workspace_root: []const u8, configured: ?[]const u8) !?[]const u8 {
    if (!claimsGreen(final_message)) return null;
    const evidence = try tdd_gate.scan(arena, messages, workspace_root, configured, null);
    if (!evidence.source_changed or evidence.green) return null;
    return note_text;
}

fn toolPair(comptime id: []const u8, comptime name: []const u8, comptime args: []const u8, comptime status: types.PersistedToolStatus, comptime output: []const u8) [2]ChatMessage {
    return .{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = id, .name = name, .arguments_json = args }} },
        .{ .role = .tool, .tool_call_id = id, .tool_name = name, .content = output, .tool_result_status = status },
    };
}

test "claimsGreen reads English and Spanish claims" {
    try std.testing.expect(claimsGreen("Done. All tests pass."));
    try std.testing.expect(claimsGreen("bun test 384 pass / 0 fail"));
    try std.testing.expect(claimsGreen("Quedó todo en verde."));
    try std.testing.expect(!claimsGreen("I renamed the export."));
}

test "check notes a green claim with no run after the last change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edited = toolPair("c1", "edit_file", "{\"path\":\"src/calc.ts\"}", .success, "Edited");
    try std.testing.expectEqualStrings(note_text, (try check(arena, "Fixed, all tests pass.", &edited, "/repo", null)).?);

    const tested = edited ++ toolPair("c2", "shell", "{\"command\":\"bun test\"}", .success, "12 pass\n0 fail");
    try std.testing.expect((try check(arena, "Fixed, all tests pass.", &tested, "/repo", null)) == null);

    const stale = tested ++ toolPair("c3", "edit_file", "{\"path\":\"src/other.ts\"}", .success, "Edited");
    try std.testing.expect((try check(arena, "Fixed, all tests pass.", &stale, "/repo", null)) != null);

    try std.testing.expect((try check(arena, "Fixed the bug.", &edited, "/repo", null)) == null);
    const read_only = toolPair("c1", "read_file", "{\"path\":\"src/calc.ts\"}", .success, "x");
    try std.testing.expect((try check(arena, "The tests pass on main.", &read_only, "/repo", null)) == null);
}
