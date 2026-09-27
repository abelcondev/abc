//! Append-only record of Jev decisions.
//!
//! Each decision is one JSON line in `~/.fx/sessions/<id>/decisions.jsonl`,
//! or `~/.fx/decisions.jsonl` when the turn has no saved session. Lines hold
//! the gate, Jev's raw answers, the threshold and the outcome, never the
//! state sent to Jev. Logging is best effort and never changes a decision.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const jev_contract = @import("jev_contract.zig");

const Allocator = std.mem.Allocator;

pub const file_name = "decisions.jsonl";

pub const Entry = struct {
    gate: []const u8,
    session_id: ?[]const u8 = null,
    turn_id: ?u64 = null,
    model: []const u8,
    threshold: f64,
    outcome: []const u8,
    detail: ?[]const u8 = null,
    latency_ms: i64,
    input_tokens: u64 = 0,
    answers: []const jev_contract.NamedAnswer = &.{},
};

/// Writes one entry as a JSON line. Caller owns the returned bytes.
pub fn formatLine(alloc: Allocator, timestamp_ms: i64, entry: Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("ts_ms");
    try jw.write(timestamp_ms);
    try jw.objectField("gate");
    try jw.write(entry.gate);
    if (entry.session_id) |id| {
        try jw.objectField("session_id");
        try jw.write(id);
    }
    if (entry.turn_id) |id| {
        try jw.objectField("turn_id");
        try jw.write(id);
    }
    try jw.objectField("model");
    try jw.write(entry.model);
    try jw.objectField("threshold");
    try jw.write(entry.threshold);
    try jw.objectField("outcome");
    try jw.write(entry.outcome);
    if (entry.detail) |detail| {
        try jw.objectField("detail");
        try jw.write(detail);
    }
    try jw.objectField("latency_ms");
    try jw.write(entry.latency_ms);
    try jw.objectField("input_tokens");
    try jw.write(entry.input_tokens);
    try jw.objectField("answers");
    try jw.beginObject();
    for (entry.answers) |named| {
        try jw.objectField(named.id);
        switch (named.answer) {
            .noul => |value| try jw.write(value),
            .choice => |value| try jw.write(.{ .choice = value.choice, .confidence = value.confidence }),
            .score => |value| try jw.write(.{ .score = value.score, .confidence = value.confidence }),
        }
    }
    try jw.endObject();
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Appends `entry` to the profile decision log. Failures are ignored.
pub fn append(alloc: Allocator, entry: Entry) void {
    const home = io_mod.getenv("HOME") orelse return;
    const line = formatLine(alloc, io_mod.milliTimestamp(), entry) catch return;
    defer alloc.free(line);
    const path = logPath(alloc, home, entry.session_id) catch return;
    defer alloc.free(path);
    appendToPath(path, line) catch {};
}

fn logPath(alloc: Allocator, home: []const u8, session_id: ?[]const u8) ![]u8 {
    if (session_id) |id| {
        if (validSessionId(id)) {
            const sessions = try profile_paths.sessionsDir(alloc, home);
            defer alloc.free(sessions);
            const dir = try std.fs.path.join(alloc, &.{ sessions, id });
            defer alloc.free(dir);
            if (std.Io.Dir.cwd().access(io_mod.getIo(), dir, .{})) |_| {
                return std.fs.path.join(alloc, &.{ dir, file_name });
            } else |_| {}
        }
    }
    const root = try profile_paths.rootDir(alloc, home);
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, file_name });
}

fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return true;
}

fn appendToPath(path: []const u8, line: []const u8) !void {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, line, stat.size);
}

test "formatLine records answers without state" {
    const alloc = std.testing.allocator;
    const line = try formatLine(alloc, 42, .{
        .gate = "stop",
        .session_id = "s-1",
        .turn_id = 3,
        .model = "jev-1.13.0",
        .threshold = 0.5,
        .outcome = "continue",
        .latency_ms = 390,
        .input_tokens = 512,
        .answers = &.{
            .{ .id = "work_done", .answer = .{ .noul = 0.25 } },
            .{ .id = "task_kind", .answer = .{ .choice = .{ .choice = "work", .confidence = 0.9 } } },
        },
    });
    defer alloc.free(line);
    try std.testing.expectEqualStrings(
        "{\"ts_ms\":42,\"gate\":\"stop\",\"session_id\":\"s-1\",\"turn_id\":3,\"model\":\"jev-1.13.0\",\"threshold\":0.5," ++
            "\"outcome\":\"continue\",\"latency_ms\":390,\"input_tokens\":512," ++
            "\"answers\":{\"work_done\":0.25,\"task_kind\":{\"choice\":\"work\",\"confidence\":0.9}}}\n",
        line,
    );
}

test "validSessionId rejects path traversal" {
    try std.testing.expect(validSessionId("20260926-abc_1"));
    try std.testing.expect(!validSessionId("../x"));
    try std.testing.expect(!validSessionId(""));
}
