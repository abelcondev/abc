//! Memory gate: before the agent writes a new workspace memory fact
//! (`memory_store.zig`), Jev judges whether the fact is worth keeping (it
//! will help later and cannot be read from the repository or git) and, when
//! the index has entries, whether it repeats one. A fact that fails either
//! check is held once with the reason; updates to existing facts and the
//! index itself are not checked.

const std = @import("std");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");

const Allocator = std.mem.Allocator;

pub const worth_id = "worth_saving";
pub const duplicate_id = "duplicate";
/// Below this the fact is not worth a memory.
pub const worth_threshold = 0.35;
/// At or above this the fact repeats an index entry.
pub const duplicate_threshold = 0.6;

const worth_question = jev_contract.Question{
    .id = worth_id,
    .instructions = "`fact` will help a coding agent in later conversations in this workspace and cannot be read from the repository's files or its git history: it is not code structure, a past fix, or something that only matters in the current conversation",
    .kind = .noul,
};
const duplicate_question = jev_contract.Question{
    .id = duplicate_id,
    .instructions = "`fact` records the same thing as one of the lines in `index`, so that entry should be updated instead of adding a new one",
    .kind = .noul,
};

pub const questions_with_index = [_]jev_contract.Question{ worth_question, duplicate_question };
pub const questions_without_index = [_]jev_contract.Question{worth_question};

pub const Verdict = enum { save, not_worth, duplicate };

/// Combines the answers; null when one is missing.
pub fn evaluate(response: *const jev_contract.Response, with_index: bool) ?Verdict {
    const worth = response.noul(worth_id) orelse return null;
    // A repeat also reads as not worth saving; "update the entry" is the
    // more useful answer, so it is checked first.
    if (with_index) {
        const duplicate = response.noul(duplicate_id) orelse return null;
        if (duplicate >= duplicate_threshold) return .duplicate;
    }
    return if (worth < worth_threshold) .not_worth else .save;
}

pub fn buildState(alloc: Allocator, user_request: []const u8, fact: []const u8, index: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(.{
        .user_request = turn_text.clip(user_request, 2 * 1024),
        .fact = turn_text.clip(fact, 4 * 1024),
        .index = turn_text.clip(index, 8 * 1024),
    });
    return out.toOwnedSlice();
}

pub const not_worth_reason =
    "Memory: this fact was not saved.\n" ++
    "Jev judged that it can be read from the repository or git, or only matters in this conversation. Memory is for what " ++
    "later conversations cannot recover on their own: who the user is, how they want you to work, ongoing goals and " ++
    "constraints, and external references. If the user asked you to remember it, ask what was non-obvious about it and " ++
    "save that instead; otherwise continue without saving.";

pub const duplicate_reason =
    "Memory: this fact repeats an entry in the index.\n" ++
    "Update that entry's file (and its index line if the hook changed) instead of adding a new fact.";

test "evaluate holds unhelpful and repeated facts" {
    const Case = struct { body: []const u8, with_index: bool, want: ?Verdict };
    const cases = [_]Case{
        .{ .body =
        \\{"model":"m","answers":{"worth_saving":{"type":"noul","noul":0.85},"duplicate":{"type":"noul","noul":0.1}}}
        , .with_index = true, .want = .save },
        .{ .body =
        \\{"model":"m","answers":{"worth_saving":{"type":"noul","noul":0.2},"duplicate":{"type":"noul","noul":0.1}}}
        , .with_index = true, .want = .not_worth },
        .{ .body =
        \\{"model":"m","answers":{"worth_saving":{"type":"noul","noul":0.8},"duplicate":{"type":"noul","noul":0.9}}}
        , .with_index = true, .want = .duplicate },
        .{ .body =
        \\{"model":"m","answers":{"worth_saving":{"type":"noul","noul":0.8}}}
        , .with_index = false, .want = .save },
        .{ .body =
        \\{"model":"m","answers":{"worth_saving":{"type":"noul","noul":0.8}}}
        , .with_index = true, .want = null },
    };
    for (cases) |case| {
        var response = try jev_contract.parseResponse(std.testing.allocator, case.body);
        defer response.deinit();
        try std.testing.expectEqual(case.want, evaluate(&response, case.with_index));
    }
}
