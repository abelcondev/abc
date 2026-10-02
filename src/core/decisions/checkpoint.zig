//! Automatic checkpoint commits: when a new request starts work that is not
//! part of the uncommitted work from earlier turns, that earlier work is
//! committed first so each piece of work lands in its own commit.
//!
//! Each turn that changes files appends its request and changed paths to
//! `~/.fx/sessions/<id>/work.jsonl`. Before the first file change of a later
//! turn, the entries whose paths are still uncommitted are the pending work.
//! The checkpoint needs all of:
//! - a git branch that is not the default branch (work never lands on main),
//! - a passing test or build receipt on exactly the current code
//!   (`receipts.zig`) and no failing one,
//! - Jev judging that the new request is separate work, not a follow-up.
//!
//! fx then holds the file change once and asks the agent to commit only the
//! pending paths with a message about that earlier work. Recording is best
//! effort; any missing piece skips the checkpoint and the turn goes on.

const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");
const receipts = @import("receipts.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const file_name = "work.jsonl";

pub const Limits = struct {
    pub const request_bytes = 1500;
    pub const read_bytes = 128 * 1024;
    pub const max_paths = 200;
    pub const max_requests = 8;
};

pub const relation_id = "relation";
pub const separate_id = "separate_work";
/// Confidence the relation and the grounding question must reach.
pub const threshold = 0.6;

pub const questions = [_]jev_contract.Question{
    .{
        .id = relation_id,
        .instructions = "How `current_request` relates to the uncommitted work done for `previous_requests`",
        .kind = .{ .choice = &.{
            .{ .name = "follow_up", .description = "continues, adjusts, extends or polishes that same work (the same feature, screen, component or fix)" },
            .{ .name = "correction", .description = "reports a problem in the code changed for `previous_requests` or asks to fix or undo part of that same work" },
            .{ .name = "new_work", .description = "starts a different feature or topic, or fixes a bug in another part of the product than the work for `previous_requests`" },
            .{ .name = "no_change", .description = "only asks a question, asks for a review, or asks to commit, push or open a pull request" },
        } },
    },
    .{
        .id = separate_id,
        .instructions = "The work `current_request` asks for could be reviewed and committed on its own, separately from the work done for `previous_requests`",
        .kind = .noul,
    },
};

pub const Verdict = enum { commit, keep };

/// Combines Jev's answers; null when an answer is missing.
pub fn evaluate(response: *const jev_contract.Response) ?Verdict {
    const relation = response.choice(relation_id) orelse return null;
    const separate = response.noul(separate_id) orelse return null;
    if (!std.mem.eql(u8, relation.choice, "new_work")) return .keep;
    return if (relation.confidence >= threshold and separate >= threshold) .commit else .keep;
}

pub fn buildState(alloc: Allocator, previous_requests: []const []const u8, current_request: []const u8, paths: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("previous_requests");
    try jw.beginArray();
    for (previous_requests) |request| try jw.write(turn_text.clip(request, Limits.request_bytes));
    try jw.endArray();
    try jw.objectField("uncommitted_files");
    try jw.write(paths[0..@min(paths.len, 40)]);
    try jw.objectField("current_request");
    try jw.write(turn_text.clip(current_request, Limits.request_bytes));
    try jw.endObject();
    return out.toOwnedSlice();
}

/// Workspace-relative paths of the turn's successful file changes. Slices
/// are allocated in `arena`.
pub fn changedPaths(arena: Allocator, workspace_root: []const u8, messages: []const ChatMessage) ![]const []const u8 {
    var calls: std.StringHashMapUnmanaged(types.ToolCall) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    for (messages) |message| {
        for (message.tool_calls) |call| try calls.put(arena, call.id, call);
        if (message.role != .tool) continue;
        const name = message.tool_name orelse continue;
        if (!std.mem.eql(u8, name, "write_file") and !std.mem.eql(u8, name, "edit_file")) continue;
        if ((message.tool_result_status orelse continue) != .success) continue;
        const call = calls.get(message.tool_call_id orelse continue) orelse continue;
        const raw = argString(arena, call.arguments_json, "path") orelse continue;
        const path = relative(workspace_root, raw) orelse continue;
        if (seen.contains(path) or paths.items.len >= Limits.max_paths) continue;
        try seen.put(arena, path, {});
        try paths.append(arena, path);
    }
    return paths.items;
}

/// `path` relative to `workspace_root`, or null when it is outside it.
fn relative(workspace_root: []const u8, path: []const u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(path)) {
        const trimmed = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
        if (std.mem.startsWith(u8, trimmed, "../") or trimmed.len == 0) return null;
        return trimmed;
    }
    const root = std.mem.trimEnd(u8, workspace_root, "/");
    if (path.len <= root.len + 1 or !std.mem.startsWith(u8, path, root) or path[root.len] != '/') return null;
    return path[root.len + 1 ..];
}

fn argString(arena: Allocator, arguments_json: []const u8, field: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return null;
    if (parsed != .object) return null;
    const value = parsed.object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

/// Appends the turn's request and changed paths. Failures are ignored.
pub fn recordWork(alloc: Allocator, session_id: []const u8, request: []const u8, paths: []const []const u8) void {
    if (paths.len == 0) return;
    const path = sessionFile(alloc, session_id) catch return;
    defer alloc.free(path);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(.{ .ts_ms = io_mod.milliTimestamp(), .request = turn_text.clip(request, Limits.request_bytes), .paths = paths }) catch return;
    out.writer.writeByte('\n') catch return;
    appendToPath(path, out.written()) catch {};
}

pub const Pending = struct {
    /// Requests whose changes are still uncommitted, oldest first.
    requests: []const []const u8,
    /// Their paths that git still reports as changed.
    paths: []const []const u8,
};

/// The recorded work that is still uncommitted. Allocated in `arena`.
pub fn pendingWork(arena: Allocator, session_id: []const u8, workspace_root: []const u8) ?Pending {
    const path = sessionFile(arena, session_id) catch return null;
    const bytes = readTail(arena, path) catch return null;
    const status = git(arena, workspace_root, &.{ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" }) orelse return null;
    // Status paths are relative to the repository root; recorded paths are
    // relative to the workspace, which may be a subdirectory.
    const prefix = std.mem.trim(u8, git(arena, workspace_root, &.{ "git", "rev-parse", "--show-prefix" }) orelse return null, " \r\n");
    return pendingFrom(arena, bytes, dirtyPaths(arena, status) catch return null, prefix);
}

fn pendingFrom(arena: Allocator, log: []const u8, dirty: std.StringHashMapUnmanaged(void), prefix: []const u8) ?Pending {
    var requests: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = std.json.parseFromSliceLeaky(struct {
            request: []const u8 = "",
            paths: []const []const u8 = &.{},
        }, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        var any = false;
        for (entry.paths) |p| {
            const repo_path = if (prefix.len == 0) p else std.mem.concat(arena, u8, &.{ prefix, p }) catch return null;
            if (!dirty.contains(repo_path)) continue;
            any = true;
            if (seen.contains(p)) continue;
            seen.put(arena, p, {}) catch return null;
            paths.append(arena, p) catch return null;
        }
        if (any) requests.append(arena, entry.request) catch return null;
    }
    if (paths.items.len == 0) return null;
    const keep = @min(requests.items.len, Limits.max_requests);
    return .{ .requests = requests.items[requests.items.len - keep ..], .paths = paths.items };
}

/// Paths in `git status --porcelain=v1 -z` output, including both sides of
/// a rename.
fn dirtyPaths(arena: Allocator, status: []const u8) !std.StringHashMapUnmanaged(void) {
    var dirty: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.splitScalar(u8, status, 0);
    while (it.next()) |record| {
        if (record.len < 4) continue;
        try dirty.put(arena, record[3..], {});
        // A rename or copy is followed by its source path.
        if (record[0] == 'R' or record[0] == 'C') {
            if (it.next()) |source| try dirty.put(arena, source, {});
        }
    }
    return dirty;
}

pub const BranchError = error{ NotOnBranch, DefaultBranch };

/// The current branch, unless it is detached or the default branch.
pub fn workBranch(arena: Allocator, workspace_root: []const u8) BranchError![]const u8 {
    const raw = git(arena, workspace_root, &.{ "git", "symbolic-ref", "--quiet", "--short", "HEAD" }) orelse return error.NotOnBranch;
    const branch = std.mem.trim(u8, raw, " \r\n");
    if (branch.len == 0) return error.NotOnBranch;
    if (std.mem.eql(u8, branch, "main") or std.mem.eql(u8, branch, "master")) return error.DefaultBranch;
    if (git(arena, workspace_root, &.{ "git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })) |remote_head| {
        const default = std.mem.trim(u8, remote_head, " \r\n");
        const name = if (std.mem.findScalar(u8, default, '/')) |slash| default[slash + 1 ..] else default;
        if (std.mem.eql(u8, name, branch)) return error.DefaultBranch;
    }
    return branch;
}

/// Whether the newest receipt of each kind on the current code passed, with
/// at least one receipt.
pub fn verified(found: []const receipts.Receipt) bool {
    var tests: ?bool = null;
    var build: ?bool = null;
    for (found) |receipt| {
        const slot = switch (receipt.kind) {
            .tests => &tests,
            .build => &build,
        };
        if (slot.* == null) slot.* = receipt.ok;
    }
    if (tests == null and build == null) return false;
    return (tests orelse true) and (build orelse true);
}

/// The hold that asks the agent to commit the earlier work. Caller owns it.
pub fn holdReason(alloc: Allocator, branch: []const u8, pending: Pending) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("Checkpoint: committing the earlier work on {s} before starting this request.\n", .{branch});
    try w.writeAll("This request is separate from the uncommitted work from earlier turns, which already passed its tests. " ++
        "Before changing any file, commit exactly these paths and nothing else:\n");
    for (pending.paths) |path| try w.print("- {s}\n", .{path});
    try w.writeAll("Earlier requests:\n");
    for (pending.requests) |request| try w.print("- {s}\n", .{turn_text.clip(request, 200)});
    try w.writeAll("Run `git add -- <those paths>` and `git commit` with a short imperative subject that describes that " ++
        "earlier work (not this request), with no trailers or attribution lines. Do not push. Then continue with the current request. " ++
        "The user turned on these automatic checkpoint commits (`jev.gates.checkpoint`), so mention the commit in one line " ++
        "without asking whether it was wanted.");
    return out.toOwnedSlice();
}

fn git(arena: Allocator, workspace_root: []const u8, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = workspace_root },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1024),
    }) catch return null;
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

fn readTail(arena: Allocator, path: []const u8) ![]const u8 {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    const start = size -| Limits.read_bytes;
    const buf = try arena.alloc(u8, @intCast(size - start));
    const read = try file.readPositionalAll(io, buf, start);
    var bytes = buf[0..read];
    if (start != 0) {
        const newline = std.mem.findScalar(u8, bytes, '\n') orelse return "";
        bytes = bytes[newline + 1 ..];
    }
    return bytes;
}

fn sessionFile(alloc: Allocator, session_id: []const u8) ![]u8 {
    if (!validSessionId(session_id)) return error.InvalidSessionId;
    const home = io_mod.getenv("HOME") orelse return error.NoHome;
    const sessions = try profile_paths.sessionsDir(alloc, home);
    defer alloc.free(sessions);
    return std.fs.path.join(alloc, &.{ sessions, session_id, file_name });
}

fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return true;
}

fn appendToPath(path: []const u8, bytes: []const u8) !void {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, bytes, stat.size);
}

test "evaluate commits only confident separate new work" {
    const cases = [_]struct { body: []const u8, want: ?Verdict }{
        .{ .body =
        \\{"model":"m","answers":{"relation":{"type":"choice","choice":"new_work","confidence":0.9},"separate_work":{"type":"noul","noul":0.8}}}
        , .want = .commit },
        .{ .body =
        \\{"model":"m","answers":{"relation":{"type":"choice","choice":"new_work","confidence":0.9},"separate_work":{"type":"noul","noul":0.4}}}
        , .want = .keep },
        .{ .body =
        \\{"model":"m","answers":{"relation":{"type":"choice","choice":"follow_up","confidence":0.95},"separate_work":{"type":"noul","noul":0.9}}}
        , .want = .keep },
        .{ .body =
        \\{"model":"m","answers":{"relation":{"type":"choice","choice":"new_work","confidence":0.9}}}
        , .want = null },
    };
    for (cases) |case| {
        var response = try jev_contract.parseResponse(std.testing.allocator, case.body);
        defer response.deinit();
        try std.testing.expectEqual(case.want, evaluate(&response));
    }
}

test "pendingFrom keeps requests whose paths are still dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log =
        \\{"ts_ms":1,"request":"committed work","paths":["src/old.ts"]}
        \\{"ts_ms":2,"request":"card layout","paths":["src/Card.tsx","tests/card.test.ts"]}
        \\{"ts_ms":3,"request":"card colors","paths":["src/Card.tsx"]}
        \\
    ;
    const dirty = try dirtyPaths(a, " M src/Card.tsx\x00?? tests/card.test.ts\x00R  src/new.ts\x00src/older.ts\x00");
    const pending = pendingFrom(a, log, dirty, "").?;
    try std.testing.expectEqual(@as(usize, 2), pending.requests.len);
    try std.testing.expectEqualStrings("card layout", pending.requests[0]);
    try std.testing.expectEqual(@as(usize, 2), pending.paths.len);
    try std.testing.expect(dirty.contains("src/older.ts"));
    const clean: std.StringHashMapUnmanaged(void) = .empty;
    try std.testing.expect(pendingFrom(a, log, clean, "") == null);
    const nested = try dirtyPaths(a, " M app/src/Card.tsx\x00");
    try std.testing.expectEqualStrings("src/Card.tsx", pendingFrom(a, log, nested, "app/").?.paths[0]);
}

test "verified needs the newest run of each kind to pass" {
    const green = receipts.Receipt{ .kind = .tests, .command = "bun test", .ok = true, .summary = "", .fingerprint = "f" };
    const red = receipts.Receipt{ .kind = .tests, .command = "bun test", .ok = false, .summary = "", .fingerprint = "f" };
    const built = receipts.Receipt{ .kind = .build, .command = "bun run build", .ok = true, .summary = "", .fingerprint = "f" };
    try std.testing.expect(verified(&.{ green, red }));
    try std.testing.expect(!verified(&.{ red, green }));
    try std.testing.expect(verified(&.{built}));
    try std.testing.expect(!verified(&.{}));
}

test "relative keeps workspace paths only" {
    try std.testing.expectEqualStrings("src/a.ts", relative("/repo", "/repo/src/a.ts").?);
    try std.testing.expectEqualStrings("src/a.ts", relative("/repo/", "./src/a.ts").?);
    try std.testing.expect(relative("/repo", "/repo2/a.ts") == null);
    try std.testing.expect(relative("/repo", "/tmp/a.ts") == null);
    try std.testing.expect(relative("/repo", "../a.ts") == null);
}

test "holdReason lists the paths and forbids attribution" {
    const text = try holdReason(std.testing.allocator, "feature", .{ .requests = &.{"center the date"}, .paths = &.{"src/Card.tsx"} });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "Checkpoint: committing the earlier work on feature"));
    try std.testing.expect(std.mem.find(u8, text, "- src/Card.tsx\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "no trailers or attribution") != null);
}

test "workBranch refuses the default branch and detached heads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (git(a, root, &.{ "git", "init", "-q", "-b", "main" }) == null) return error.SkipZigTest;
    _ = git(a, root, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init" }) orelse return error.SkipZigTest;
    try std.testing.expectError(error.DefaultBranch, workBranch(a, root));
    _ = git(a, root, &.{ "git", "checkout", "-q", "-b", "cart-work" }) orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("cart-work", try workBranch(a, root));
    _ = git(a, root, &.{ "git", "checkout", "-q", "--detach" }) orelse return error.SkipZigTest;
    try std.testing.expectError(error.NotOnBranch, workBranch(a, root));
}
