//! Bounded text views of a turn for Jev `state` payloads.

const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// The agent's visible messages in this turn plus the text that accompanies
/// the pending call, newest kept first within `budget` bytes. Returned slices
/// borrow from the inputs; the list itself is allocated in `arena`.
pub fn agentMessages(
    arena: Allocator,
    turn_messages: []const types.ChatMessage,
    assistant_text: []const u8,
    budget: usize,
) ![]const []const u8 {
    var texts: std.ArrayList([]const u8) = .empty;
    for (turn_messages) |message| {
        if (message.role != .assistant) continue;
        const content = std.mem.trim(u8, message.content orelse "", " \t\r\n");
        if (content.len != 0) try texts.append(arena, content);
    }
    const current = std.mem.trim(u8, assistant_text, " \t\r\n");
    if (current.len != 0) try texts.append(arena, current);

    var start = texts.items.len;
    var used: usize = 0;
    while (start > 0) {
        const cost = texts.items[start - 1].len;
        if (used + cost > budget) break;
        used += cost;
        start -= 1;
    }
    return texts.items[start..];
}

/// A UTF-8-safe prefix of at most `max` bytes.
pub fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

test "agentMessages keeps the newest messages within the budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .content = "first message" },
        .{ .role = .tool, .content = "ignored" },
        .{ .role = .assistant, .content = "  " },
        .{ .role = .assistant, .content = "second" },
    };
    const all = try agentMessages(arena_state.allocator(), &messages, "current", 1024);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("current", all[2]);
    const recent = try agentMessages(arena_state.allocator(), &messages, "current", 13);
    try std.testing.expectEqual(@as(usize, 2), recent.len);
    try std.testing.expectEqualStrings("second", recent[0]);
}

test "clip never splits a UTF-8 sequence" {
    try std.testing.expectEqualStrings("a", clip("añb", 2));
    try std.testing.expectEqualStrings("añb", clip("añb", 10));
}
