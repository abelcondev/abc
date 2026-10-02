//! Verification receipts: test and build runs tied to the code they ran on.
//!
//! At the end of a turn the runs that came after the turn's last file change
//! are appended to `~/.fx/sessions/<id>/receipts.jsonl`, each with a
//! fingerprint of the workspace (git HEAD plus the content of every changed
//! or untracked file outside `sdd/`). A later turn can trust an earlier run only while the
//! fingerprint is unchanged, so "the tests pass" from three turns ago stays
//! backed until the code moves. Recording is best effort and never blocks a
//! turn.

const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const tdd_gate = @import("tdd_gate.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const file_name = "receipts.jsonl";

const sdd_dir = "sdd/";

pub const Limits = struct {
    pub const command_bytes = 300;
    pub const summary_bytes = 400;
    /// Receipts read back from the end of the file.
    pub const read_bytes = 64 * 1024;
    /// Changed files hashed into a fingerprint.
    pub const max_files = 2000;
    pub const max_file_bytes = 8 * 1024 * 1024;
};

/// Common build and type-check commands, matched like test runners.
const build_prefixes = [_][]const u8{
    "zig build",   "bun run build",     "npm run build",     "pnpm build",   "pnpm run build",  "yarn build",
    "cargo build", "cargo check",       "go build",          "go vet",       "tsc",             "bunx tsc",
    "npx tsc",     "make",              "mvn package",       "gradle build", "./gradlew build", "dotnet build",
    "swift build", "bun run typecheck", "npm run typecheck", "npm run lint", "bun run lint",
};

pub const Kind = enum { tests, build };

pub const Receipt = struct {
    ts_ms: i64 = 0,
    turn_id: ?u64 = null,
    /// Tool call id of the run.
    call_id: []const u8 = "",
    kind: Kind,
    command: []const u8,
    ok: bool,
    /// Tail of the run's output, where runners print their summary.
    summary: []const u8,
    fingerprint: []const u8,
};

/// Whether `command` is a verification run: tests (a known runner or
/// `configured`) or a build or type check.
pub fn classify(command: []const u8, configured: ?[]const u8) ?Kind {
    if (tdd_gate.isTestCommand(command, configured)) return .tests;
    var rest = std.mem.trim(u8, command, " \t\r\n");
    while (std.mem.find(u8, rest, "&&")) |index| {
        if (classify(rest[0..index], configured)) |kind| return kind;
        rest = std.mem.trim(u8, rest[index + 2 ..], " \t");
    }
    for (build_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, rest, prefix)) continue;
        if (rest.len == prefix.len or rest[prefix.len] == ' ') return .build;
    }
    return null;
}

pub const Run = struct {
    /// Tool call id, to record each run once.
    id: []const u8,
    kind: Kind,
    command: []const u8,
    ok: bool,
    output: []const u8,
};

/// Verification runs after the turn's last successful file change. Slices
/// borrow from `messages`; the list is allocated in `arena`.
pub fn runsAfterLastChange(arena: Allocator, messages: []const ChatMessage, configured: ?[]const u8) ![]const Run {
    var calls: std.StringHashMapUnmanaged(types.ToolCall) = .empty;
    var runs: std.ArrayList(Run) = .empty;
    for (messages) |message| {
        for (message.tool_calls) |call| try calls.put(arena, call.id, call);
        if (message.role != .tool) continue;
        const name = message.tool_name orelse continue;
        const call = calls.get(message.tool_call_id orelse continue) orelse continue;
        const status = message.tool_result_status orelse continue;
        if (std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit_file")) {
            if (status == .success) runs.clearRetainingCapacity();
            continue;
        }
        if (!std.mem.eql(u8, name, "shell")) continue;
        const command = argString(arena, call.arguments_json, "command") orelse continue;
        const kind = classify(command, configured) orelse continue;
        const output = commandOutput(arena, message.content orelse "");
        // `bun test | tail` exits 0 even when tests fail.
        const ok = status == .success and !(kind == .tests and tdd_gate.outputShowsFailure(output));
        try runs.append(arena, .{ .id = call.id, .kind = kind, .command = command, .ok = ok, .output = output });
    }
    return runs.items;
}

/// The command's own output from a shell result envelope, or the raw
/// content when it is not one.
fn commandOutput(arena: Allocator, content: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch return content;
    if (parsed != .object) return content;
    inline for (.{ "output_delta", "output" }) |field| {
        if (parsed.object.get(field)) |value| {
            if (value == .string) return value.string;
        }
    }
    return content;
}

fn argString(arena: Allocator, arguments_json: []const u8, field: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return null;
    if (parsed != .object) return null;
    const value = parsed.object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

/// Fingerprint of the workspace code: git HEAD plus the path and content of
/// every modified or untracked (not ignored) file. Null outside a git
/// repository or when git fails. Caller owns the returned hex.
pub fn fingerprint(alloc: Allocator, workspace_root: []const u8) ?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const head = git(arena, workspace_root, &.{ "git", "rev-parse", "HEAD" }) orelse return null;
    const listed = git(arena, workspace_root, &.{ "git", "ls-files", "-z", "--modified", "--others", "--exclude-standard", "--deduplicate" }) orelse return null;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(std.mem.trim(u8, head, " \n"));
    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, listed, 0);
    while (it.next()) |path| {
        if (paths.items.len >= Limits.max_files) break;
        // Specs and changes are documentation fx owns; editing them does
        // not invalidate a test run.
        if (std.mem.startsWith(u8, path, sdd_dir)) continue;
        paths.append(arena, path) catch return null;
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    const io = io_mod.getIo();
    var root = std.Io.Dir.cwd().openDir(io, workspace_root, .{}) catch return null;
    defer root.close(io);
    for (paths.items) |path| {
        hasher.update("\x00");
        hasher.update(path);
        hasher.update("\x00");
        // A deleted file hashes as its path alone.
        const bytes = root.readFileAlloc(io, path, arena, .limited(Limits.max_file_bytes)) catch continue;
        hasher.update(bytes);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..16], .lower);
    return alloc.dupe(u8, &hex) catch null;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

/// Writes one receipt as a JSON line. Caller owns the returned bytes.
pub fn formatLine(alloc: Allocator, receipt: Receipt) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(.{
        .ts_ms = receipt.ts_ms,
        .turn_id = receipt.turn_id,
        .call_id = receipt.call_id,
        .kind = @tagName(receipt.kind),
        .command = clip(receipt.command, Limits.command_bytes),
        .ok = receipt.ok,
        .summary = tail(receipt.summary, Limits.summary_bytes),
        .fingerprint = receipt.fingerprint,
    });
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Appends the runs as receipts for `session_id`. Failures are ignored.
pub fn record(alloc: Allocator, session_id: []const u8, turn_id: ?u64, fingerprint_hex: []const u8, runs: []const Run) void {
    if (runs.len == 0) return;
    const path = receiptsPath(alloc, session_id) catch return;
    defer alloc.free(path);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const now = io_mod.milliTimestamp();
    for (runs) |run| {
        const line = formatLine(alloc, .{
            .ts_ms = now,
            .turn_id = turn_id,
            .call_id = run.id,
            .kind = run.kind,
            .command = run.command,
            .ok = run.ok,
            .summary = run.output,
            .fingerprint = fingerprint_hex,
        }) catch return;
        defer alloc.free(line);
        out.writer.writeAll(line) catch return;
    }
    appendToPath(path, out.written()) catch {};
}

/// The newest receipts for `session_id` whose fingerprint matches, newest
/// first, at most `max`. Strings are allocated in `arena`.
pub fn matching(arena: Allocator, session_id: []const u8, fingerprint_hex: []const u8, max: usize) []const Receipt {
    const path = receiptsPath(arena, session_id) catch return &.{};
    const bytes = readTail(arena, path) catch return &.{};
    return parseMatching(arena, bytes, fingerprint_hex, max);
}

fn parseMatching(arena: Allocator, bytes: []const u8, fingerprint_hex: []const u8, max: usize) []const Receipt {
    var found: std.ArrayList(Receipt) = .empty;
    var lines = std.mem.splitBackwardsScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (found.items.len >= max) break;
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(struct {
            ts_ms: i64 = 0,
            turn_id: ?u64 = null,
            call_id: []const u8 = "",
            kind: Kind,
            command: []const u8,
            ok: bool,
            summary: []const u8 = "",
            fingerprint: []const u8,
        }, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, parsed.fingerprint, fingerprint_hex)) continue;
        found.append(arena, .{
            .ts_ms = parsed.ts_ms,
            .turn_id = parsed.turn_id,
            .call_id = parsed.call_id,
            .kind = parsed.kind,
            .command = parsed.command,
            .ok = parsed.ok,
            .summary = parsed.summary,
            .fingerprint = parsed.fingerprint,
        }) catch break;
    }
    return found.items;
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
    // Drop a partial first line.
    if (start != 0) {
        const newline = std.mem.findScalar(u8, bytes, '\n') orelse return "";
        bytes = bytes[newline + 1 ..];
    }
    return bytes;
}

fn receiptsPath(alloc: Allocator, session_id: []const u8) ![]u8 {
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

fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

fn tail(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var start = text.len - max;
    while (start < text.len and !std.unicode.utf8ValidateSlice(text[start..])) start += 1;
    return text[start..];
}

fn toolPair(comptime id: []const u8, comptime name: []const u8, comptime args: []const u8, comptime status: types.PersistedToolStatus, comptime output: []const u8) [2]ChatMessage {
    return .{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = id, .name = name, .arguments_json = args }} },
        .{ .role = .tool, .tool_call_id = id, .tool_name = name, .content = output, .tool_result_status = status },
    };
}

test "classify tells tests from builds and ignores other commands" {
    try std.testing.expectEqual(Kind.tests, classify("bun test", null).?);
    try std.testing.expectEqual(Kind.build, classify("bunx tsc --noEmit", null).?);
    try std.testing.expectEqual(Kind.build, classify("cd app && zig build", null).?);
    try std.testing.expectEqual(Kind.tests, classify("make check", "make check").?);
    try std.testing.expect(classify("ls -la", null) == null);
    try std.testing.expect(classify("makeup", null) == null);
}

test "runsAfterLastChange keeps only runs after the last file change" {
    const messages = toolPair("a", "shell", "{\"command\":\"bun test\"}", .success, "3 pass\n0 fail") ++
        toolPair("b", "edit_file", "{\"path\":\"src/x.ts\"}", .success, "ok") ++
        toolPair("c", "shell", "{\"command\":\"bun test | tail -3\"}", .success, "{\"exit_code\":0,\"output_delta\":\"2 pass\\n1 fail\"}") ++
        toolPair("d", "shell", "{\"command\":\"bun run build\"}", .success, "built in 600ms") ++
        toolPair("e", "edit_file", "{\"path\":\"src/y.ts\"}", .failure, "old_string not found");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const runs = try runsAfterLastChange(arena.allocator(), &messages, null);
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expect(!runs[0].ok);
    try std.testing.expectEqualStrings("2 pass\n1 fail", runs[0].output);
    try std.testing.expectEqual(Kind.build, runs[1].kind);
    try std.testing.expect(runs[1].ok);
}

test "parseMatching returns the newest receipts for the fingerprint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    for ([_]struct { fp: []const u8, cmd: []const u8 }{
        .{ .fp = "aa", .cmd = "bun test" },
        .{ .fp = "bb", .cmd = "bun run build" },
        .{ .fp = "aa", .cmd = "bunx tsc" },
    }) |item| {
        const line = try formatLine(a, .{ .kind = .tests, .command = item.cmd, .ok = true, .summary = "ok", .fingerprint = item.fp });
        try bytes.appendSlice(a, line);
    }
    const found = parseMatching(a, bytes.items, "aa", 5);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("bunx tsc", found[0].command);
    try std.testing.expectEqualStrings("bun test", found[1].command);
    try std.testing.expectEqual(@as(usize, 1), parseMatching(a, bytes.items, "aa", 1).len);
}

test "fingerprint follows file content in a git repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (git(arena.allocator(), root, &.{ "git", "init", "-q" }) == null) return error.SkipZigTest;
    _ = git(arena.allocator(), root, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init" }) orelse return error.SkipZigTest;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const first = fingerprint(std.testing.allocator, root) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(first);
    const again = fingerprint(std.testing.allocator, root).?;
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(first, again);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "two" });
    const changed = fingerprint(std.testing.allocator, root).?;
    defer std.testing.allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
    try tmp.dir.createDirPath(io, "sdd/changes");
    try tmp.dir.writeFile(io, .{ .sub_path = "sdd/changes/x.md", .data = "notes" });
    const with_docs = fingerprint(std.testing.allocator, root).?;
    defer std.testing.allocator.free(with_docs);
    try std.testing.expectEqualStrings(changed, with_docs);
}
