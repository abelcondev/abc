//! Risk-tiered review before a pull request opens.
//!
//! When the agent runs `gh pr create` or `gh pr ready`, Jev rates the
//! branch's diff against the default branch: `low` (docs, tests, styling),
//! `medium` (ordinary code) or `high` (security, money, data, migrations,
//! public contracts), with a grounding question about the harm a mistake
//! could do. High risk, or medium risk over `large_change_lines`, holds the
//! command once per branch so the agent reviews the diff, refutes each
//! finding against the code, fixes what survives and reports it in the PR
//! body. Low-risk and small changes open without a review.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");

const Allocator = std.mem.Allocator;

/// Changed lines at which a medium-risk diff also needs a review.
pub const large_change_lines = 400;
pub const risk_confidence = 0.5;
pub const harm_threshold = 0.6;

pub const Limits = struct {
    pub const diff_bytes = 24 * 1024;
    pub const stat_bytes = 4 * 1024;
};

pub const risk_id = "risk";
pub const harm_id = "failure_harm";

pub const questions = [_]jev_contract.Question{
    .{
        .id = risk_id,
        .instructions = "How risky the change in `diff` is to merge",
        .kind = .{ .choice = &.{
            .{ .name = "low", .description = "only documentation, comments, tests, styling, layout or copy" },
            .{ .name = "medium", .description = "ordinary feature or fix code whose mistakes would show up as a visible bug" },
            .{ .name = "high", .description = "authentication, permissions or security, payments or money, data writes, migrations or deletion, concurrency, or a public API, schema or configuration other code depends on" },
        } },
    },
    .{
        .id = harm_id,
        .instructions = "A mistake in `diff` could lose or corrupt data, expose private data or credentials, charge or pay wrong amounts, or stop users from working",
        .kind = .noul,
    },
};

pub const Risk = enum { low, medium, high };

pub const Verdict = struct {
    risk: Risk,
    due: bool,
};

/// Combines Jev's answers with the size of the change. Null when an answer
/// is missing.
pub fn evaluate(response: *const jev_contract.Response, changed_lines: usize) ?Verdict {
    const kind = response.choice(risk_id) orelse return null;
    const harm = response.noul(harm_id) orelse return null;
    var risk = std.meta.stringToEnum(Risk, kind.choice) orelse return null;
    // An unsure low rating counts as ordinary code.
    if (risk == .low and kind.confidence < risk_confidence) risk = .medium;
    if (harm >= harm_threshold) risk = .high;
    const due = switch (risk) {
        .high => true,
        .medium => changed_lines >= large_change_lines,
        .low => false,
    };
    return .{ .risk = risk, .due = due };
}

/// Whether a shell command opens a pull request or marks one ready.
pub fn isPrCommand(command: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, command, ";&|\n");
    while (segments.next()) |segment| {
        var words = std.mem.tokenizeAny(u8, segment, " \t");
        var previous: [2][]const u8 = .{ "", "" };
        while (words.next()) |word| {
            if (std.mem.eql(u8, previous[0], "gh") and std.mem.eql(u8, previous[1], "pr") and
                (std.mem.eql(u8, word, "create") or std.mem.eql(u8, word, "ready"))) return true;
            previous = .{ previous[1], word };
        }
    }
    return false;
}

pub const Diff = struct {
    base: []const u8,
    stat: []const u8,
    text: []const u8,
    changed_lines: usize,
};

/// The branch's diff against the merge base with the default branch.
/// Allocated in `arena`; null when git cannot produce it.
pub fn branchDiff(arena: Allocator, workspace_root: []const u8) ?Diff {
    const base_ref = defaultRef(arena, workspace_root) orelse return null;
    const merge_base = std.mem.trim(u8, git(arena, workspace_root, &.{ "git", "merge-base", "HEAD", base_ref }) orelse return null, " \r\n");
    const numstat = git(arena, workspace_root, &.{ "git", "diff", "--numstat", merge_base, "HEAD" }) orelse return null;
    const stat = git(arena, workspace_root, &.{ "git", "diff", "--stat", merge_base, "HEAD" }) orelse return null;
    const text = git(arena, workspace_root, &.{ "git", "diff", "--unified=2", merge_base, "HEAD" }) orelse return null;
    return .{
        .base = base_ref,
        .stat = turn_text.clip(stat, Limits.stat_bytes),
        .text = turn_text.clip(text, Limits.diff_bytes),
        .changed_lines = countLines(numstat),
    };
}

/// Sum of added and removed lines in `git diff --numstat` output; binary
/// files count as nothing.
pub fn countLines(numstat: []const u8) usize {
    var total: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, numstat, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const added = fields.next() orelse continue;
        const removed = fields.next() orelse continue;
        total += std.fmt.parseInt(usize, added, 10) catch 0;
        total += std.fmt.parseInt(usize, removed, 10) catch 0;
    }
    return total;
}

/// The checked-out branch name, or null when detached. Allocated in `arena`.
pub fn currentBranch(arena: Allocator, workspace_root: []const u8) ?[]const u8 {
    const raw = git(arena, workspace_root, &.{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" }) orelse return null;
    const branch = std.mem.trim(u8, raw, " \r\n");
    return if (branch.len == 0) null else branch;
}

fn defaultRef(arena: Allocator, workspace_root: []const u8) ?[]const u8 {
    if (git(arena, workspace_root, &.{ "git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })) |raw| {
        return std.mem.trim(u8, raw, " \r\n");
    }
    inline for (.{ "origin/main", "origin/master", "main", "master" }) |candidate| {
        if (git(arena, workspace_root, &.{ "git", "rev-parse", "--verify", "--quiet", candidate }) != null) return candidate;
    }
    return null;
}

pub fn buildState(alloc: Allocator, user_request: []const u8, diff: Diff) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(.{
        .user_request = turn_text.clip(user_request, 2 * 1024),
        .changed_lines = diff.changed_lines,
        .diff_stat = diff.stat,
        .diff = diff.text,
    });
    return out.toOwnedSlice();
}

/// The hold that asks for a review before the pull request. Caller owns it.
pub fn holdReason(alloc: Allocator, verdict: Verdict, diff: Diff) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "Review: this pull request needs a review first ({s} risk, {d} changed lines against {s}).\n" ++
            "Before opening it:\n" ++
            "1. Review the full diff against {s} for correctness bugs, security problems and data loss (use a subagent if one is available).\n" ++
            "2. Refute each finding: read the code and keep it only if you can name the exact lines and a concrete input that breaks.\n" ++
            "3. Fix the findings that survive and rerun the relevant tests.\n" ++
            "4. Add a `## Review` section to the pull request body listing the confirmed findings and their fixes, or saying none survived.\n" ++
            "Then run the pull request command again.",
        .{ @tagName(verdict.risk), diff.changed_lines, diff.base, diff.base },
    );
}

fn git(arena: Allocator, workspace_root: []const u8, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = workspace_root },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024),
    }) catch return null;
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

test "isPrCommand finds gh pr create and ready" {
    try std.testing.expect(isPrCommand("gh pr create --draft --title x"));
    try std.testing.expect(isPrCommand("git push -u origin b && gh pr create --fill"));
    try std.testing.expect(isPrCommand("gh  pr ready 18"));
    try std.testing.expect(!isPrCommand("gh pr view 18"));
    try std.testing.expect(!isPrCommand("gh pr checks 18"));
    try std.testing.expect(!isPrCommand("echo gh"));
}

test "evaluate escalates on harm and size" {
    const Case = struct { body: []const u8, lines: usize, risk: Risk, due: bool };
    const cases = [_]Case{
        .{ .body =
        \\{"model":"m","answers":{"risk":{"type":"choice","choice":"low","confidence":0.9},"failure_harm":{"type":"noul","noul":0.1}}}
        , .lines = 900, .risk = .low, .due = false },
        .{ .body =
        \\{"model":"m","answers":{"risk":{"type":"choice","choice":"medium","confidence":0.9},"failure_harm":{"type":"noul","noul":0.2}}}
        , .lines = 120, .risk = .medium, .due = false },
        .{ .body =
        \\{"model":"m","answers":{"risk":{"type":"choice","choice":"medium","confidence":0.9},"failure_harm":{"type":"noul","noul":0.2}}}
        , .lines = 400, .risk = .medium, .due = true },
        .{ .body =
        \\{"model":"m","answers":{"risk":{"type":"choice","choice":"medium","confidence":0.9},"failure_harm":{"type":"noul","noul":0.7}}}
        , .lines = 20, .risk = .high, .due = true },
        .{ .body =
        \\{"model":"m","answers":{"risk":{"type":"choice","choice":"low","confidence":0.3},"failure_harm":{"type":"noul","noul":0.1}}}
        , .lines = 500, .risk = .medium, .due = true },
    };
    for (cases) |case| {
        var response = try jev_contract.parseResponse(std.testing.allocator, case.body);
        defer response.deinit();
        const verdict = evaluate(&response, case.lines).?;
        try std.testing.expectEqual(case.risk, verdict.risk);
        try std.testing.expectEqual(case.due, verdict.due);
    }
    var missing = try jev_contract.parseResponse(std.testing.allocator,
        \\{"model":"m","answers":{"risk":{"type":"choice","choice":"high","confidence":0.9}}}
    );
    defer missing.deinit();
    try std.testing.expect(evaluate(&missing, 10) == null);
}

test "countLines sums numstat and skips binary files" {
    try std.testing.expectEqual(@as(usize, 17), countLines("10\t2\tsrc/a.ts\n5\t0\tREADME.md\n-\t-\tlogo.png\n"));
}
