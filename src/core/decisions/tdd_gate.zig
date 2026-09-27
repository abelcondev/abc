//! TDD gate: with SDD and `sdd.tdd` on, behavior changes are test-first.
//!
//! Red and green come from the turn's own evidence, not from running
//! anything here: a test file changed and a test command failed before the
//! first source change (red), and a test command succeeded after the last
//! source change (green). Jev then answers whether the changed tests would
//! fail without the requested behavior, so tests written only to pass do
//! not count.
//!
//! The same scan feeds the growth check: work routed as a fix or a spec
//! update that spreads over many source files is held once so the agent can
//! propose a change instead.

const std = @import("std");
const types = @import("../shared/types.zig");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");
const sdd_layout = @import("../sdd/sdd_layout.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

/// Distinct source files a fix or spec update may touch before it is held.
pub const growth_limit = 8;
/// Probability the changed tests must reach to count as checking the request.
pub const meaningful_threshold = 0.5;

pub const Limits = struct {
    pub const request_bytes = 4 * 1024;
    pub const test_bytes = 3 * 1024;
    pub const tests_bytes = 12 * 1024;
    pub const output_bytes = 2 * 1024;
    pub const max_paths = 64;
};

/// Common test runners, matched as a command prefix after `cd … &&`.
const runner_prefixes = [_][]const u8{
    "bun test",   "bun run test",       "npm test",          "npm run test",       "pnpm test",           "pnpm run test",
    "yarn test",  "npx vitest",         "npx jest",          "vitest",             "jest",                "deno test",
    "pytest",     "python -m pytest",   "python3 -m pytest", "python -m unittest", "python3 -m unittest", "go test",
    "cargo test", "zig build test",     "zig test",          "mix test",           "rspec",               "bundle exec rspec",
    "mvn test",   "gradle test",        "./gradlew test",    "dotnet test",        "swift test",          "make test",
    "phpunit",    "vendor/bin/phpunit",
};

/// Whether `path` names a test file.
pub fn isTestPath(path: []const u8) bool {
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    var last: []const u8 = "";
    while (segments.next()) |segment| {
        if (segments.peek() != null) {
            inline for (.{ "test", "tests", "__tests__", "spec", "specs", "e2e" }) |dir| {
                if (std.mem.eql(u8, segment, dir)) return true;
            }
        }
        last = segment;
    }
    inline for (.{ ".test.", ".spec.", "_test.", "_spec." }) |marker| {
        if (std.mem.find(u8, last, marker) != null) return true;
    }
    return std.mem.startsWith(u8, last, "test_");
}

/// Whether a shell command runs tests: a known runner or `configured`.
pub fn isTestCommand(command: []const u8, configured: ?[]const u8) bool {
    var rest = std.mem.trim(u8, command, " \t\r\n");
    // `cd dir && bun test` and `FOO=1 bun test`.
    while (true) {
        if (std.mem.find(u8, rest, "&&")) |index| {
            if (isTestCommand(rest[0..index], configured)) return true;
            rest = std.mem.trim(u8, rest[index + 2 ..], " \t");
            continue;
        }
        break;
    }
    while (std.mem.findScalar(u8, rest, '=')) |eq| {
        const space = std.mem.findScalar(u8, rest, ' ') orelse break;
        if (eq > space) break;
        rest = std.mem.trim(u8, rest[space + 1 ..], " \t");
    }
    if (configured) |text| {
        if (std.mem.startsWith(u8, rest, text)) return true;
    }
    for (runner_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, rest, prefix)) continue;
        if (rest.len == prefix.len or rest[prefix.len] == ' ') return true;
    }
    return false;
}

pub const Evidence = struct {
    /// Changed test files, in order. Borrowed from the messages.
    tests: []const []const u8 = &.{},
    /// Arguments of the calls that changed them, parallel to `tests`.
    test_changes: []const []const u8 = &.{},
    /// A test command failed after a test file changed and before any source
    /// change.
    red: bool = false,
    /// A source file changed this turn.
    source_changed: bool = false,
    /// A test command succeeded after the last source change.
    green: bool = false,
    /// Output of the last successful test run.
    green_output: []const u8 = "",
    /// Distinct source files changed, including a pending one.
    source_files: usize = 0,
};

pub const Pending = struct {
    path: []const u8,
};

fn isFileTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "edit_file");
}

/// Reads the turn's successful file changes and test runs, plus an optional
/// pending file change. Results borrow from `messages`.
pub fn scan(arena: Allocator, messages: []const ChatMessage, workspace_root: []const u8, configured: ?[]const u8, pending: ?Pending) !Evidence {
    var calls: std.StringHashMapUnmanaged(types.ToolCall) = .empty;
    var tests: std.ArrayList([]const u8) = .empty;
    var test_changes: std.ArrayList([]const u8) = .empty;
    var sources: std.StringHashMapUnmanaged(void) = .empty;
    var evidence = Evidence{};
    for (messages) |message| {
        for (message.tool_calls) |call| try calls.put(arena, call.id, call);
        if (message.role != .tool) continue;
        const name = message.tool_name orelse continue;
        const id = message.tool_call_id orelse continue;
        const call = calls.get(id) orelse continue;
        const status = message.tool_result_status orelse continue;
        if (isFileTool(name)) {
            if (status != .success) continue;
            const path = argString(arena, call.arguments_json, "path") orelse continue;
            if (sdd_layout.isSddPath(workspace_root, path)) continue;
            if (isTestPath(path)) {
                if (tests.items.len < Limits.max_paths) {
                    try tests.append(arena, path);
                    try test_changes.append(arena, call.arguments_json);
                }
            } else {
                if (sources.count() < Limits.max_paths) try sources.put(arena, path, {});
                evidence.source_changed = true;
                evidence.green = false;
            }
        } else if (std.mem.eql(u8, name, "shell")) {
            const command = argString(arena, call.arguments_json, "command") orelse continue;
            if (!isTestCommand(command, configured)) continue;
            const content = message.content orelse "";
            // `bun test | tail` exits 0 even when tests fail, so the
            // runner's summary counts too.
            const failed = if (status == .success) outputShowsFailure(content) else assertionFailure(content);
            if (!failed and status == .success) {
                if (evidence.source_changed) {
                    evidence.green = true;
                    evidence.green_output = content;
                }
            } else if (failed and tests.items.len != 0 and !evidence.source_changed) {
                evidence.red = true;
            }
        }
    }
    if (pending) |change| {
        if (!sdd_layout.isSddPath(workspace_root, change.path) and !isTestPath(change.path)) {
            if (sources.count() < Limits.max_paths) try sources.put(arena, change.path, {});
        }
    }
    evidence.tests = tests.items;
    evidence.test_changes = test_changes.items;
    evidence.source_files = sources.count();
    return evidence;
}

/// Whether a test runner's output reports failing tests: a count such as
/// `1 fail`, `2 failed` or `3 failures`, or a `FAILED` / `--- FAIL` marker.
pub fn outputShowsFailure(content: []const u8) bool {
    if (std.mem.find(u8, content, "FAILED") != null or std.mem.find(u8, content, "--- FAIL") != null) return true;
    var index: usize = 0;
    while (std.mem.findPos(u8, content, index, "fail")) |at| : (index = at + 4) {
        var cursor = at;
        while (cursor > 0 and (content[cursor - 1] == ' ' or content[cursor - 1] == '\t')) cursor -= 1;
        const digits_end = cursor;
        while (cursor > 0 and std.ascii.isDigit(content[cursor - 1])) cursor -= 1;
        if (cursor == digits_end or digits_end == at) continue;
        const count = std.fmt.parseInt(u32, content[cursor..digits_end], 10) catch continue;
        if (count != 0) return true;
    }
    return false;
}

/// A failing run that is not a missing command or a crash of the shell:
/// exit codes 126 and 127 mean the runner never ran.
fn assertionFailure(content: []const u8) bool {
    const marker = "\"exit_code\":";
    const index = std.mem.find(u8, content, marker) orelse return true;
    var end = index + marker.len;
    while (end < content.len and std.ascii.isDigit(content[end])) end += 1;
    const code = std.fmt.parseInt(u16, content[index + marker.len .. end], 10) catch return true;
    return code != 0 and code != 126 and code != 127;
}

fn argString(arena: Allocator, arguments_json: []const u8, field: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return null;
    if (parsed != .object) return null;
    const value = parsed.object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

/// Whether a pending file change is source code the gate cares about.
pub fn isSourceChange(workspace_root: []const u8, path: []const u8) bool {
    return !sdd_layout.isSddPath(workspace_root, path) and !isTestPath(path);
}

pub const meaningful_id = "tests_check_request";

pub const questions = [_]jev_contract.Question{.{
    .id = meaningful_id,
    .instructions = "The tests in `changed_tests` would fail if the behavior `user_request` asks for were missing or wrong; they are not trivially true, skipped, or only checking that code runs",
    .kind = .noul,
}};

/// Builds the Jev `state` JSON for the meaningful-test question. Caller
/// owns the returned bytes.
pub fn buildState(alloc: Allocator, user_request: []const u8, evidence: Evidence) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("user_request");
    try jw.write(turn_text.clip(user_request, Limits.request_bytes));
    try jw.objectField("changed_tests");
    try jw.beginArray();
    var budget: usize = Limits.tests_bytes;
    for (evidence.tests, evidence.test_changes) |path, change| {
        if (budget == 0) break;
        const text = turn_text.clip(change, @min(budget, Limits.test_bytes));
        budget -|= text.len;
        try jw.write(.{ .path = path, .change = text });
    }
    try jw.endArray();
    try jw.objectField("passing_run");
    try jw.write(tail(evidence.green_output, Limits.output_bytes));
    try jw.endObject();
    return out.toOwnedSlice();
}

fn tail(text: []const u8, limit: usize) []const u8 {
    return if (text.len <= limit) text else text[text.len - limit ..];
}

pub fn meaningful(response: *const jev_contract.Response) ?bool {
    const p = response.noul(meaningful_id) orelse return null;
    return p >= meaningful_threshold;
}

pub const red_reason =
    "SDD TDD: this change alters behavior, so it is test-first. Before changing source files, add or update a test " ++
    "for the new behavior (cite the rule in a comment, for example `// spec: reservas › Saldo follows Asesor`), " ++
    "run it with the project's test command (directly, without piping it through tail or grep, so its exit status " ++
    "shows the failure), and show that it fails for the right reason. Then change the code. " ++
    "If the behavior cannot be unit tested (a purely visual change), say so, mark the rule heading `(manual)` in its " ++
    "spec (or add `tdd: manual` to the change's front matter), and continue.";

pub const green_reason =
    "SDD TDD: source files changed after the last passing test run. Run the project's test command now and show " ++
    "that it passes, fixing the code until it does, before giving your final answer.";

pub const weak_test_reason =
    "SDD TDD: Jev judged that the changed tests would still pass without the requested behavior. Tighten them so " ++
    "they fail when the behavior is missing or wrong, run them, then give your final answer.";

/// Guidance when a fix or spec update spreads too far. Caller owns the text.
pub fn growthReason(alloc: Allocator, files: usize) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "SDD: this was routed as a small change, but it now touches {d} source files. Stop and tell the user; if it " ++
            "really needs this much, write a change file in " ++ sdd_layout.changes_dir ++ " and ask them to approve it. " ++
            "If they already said to go ahead, continue.",
        .{files},
    );
}

/// Rules a strict turn changed that no test cites. `citations` are lines
/// containing `spec:` from the test files.
pub fn uncitedRules(arena: Allocator, rules: []const sdd_layout.Rule, touched: []const usize, citations: []const u8) ![]const sdd_layout.Rule {
    var missing: std.ArrayList(sdd_layout.Rule) = .empty;
    for (touched) |index| {
        if (index >= rules.len) continue;
        const rule = rules[index];
        if (isManual(rule.title)) continue;
        if (std.mem.find(u8, citations, rule.title) == null) try missing.append(arena, rule);
    }
    return missing.items;
}

/// Rules marked `(manual)` are checked in the running app, not by tests.
pub fn isManual(title: []const u8) bool {
    return std.mem.endsWith(u8, std.mem.trimEnd(u8, title, " "), "(manual)");
}

/// Continuation for strict mode. Caller owns the text.
pub fn uncitedReason(alloc: Allocator, missing: []const sdd_layout.Rule) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("SDD TDD (strict): no test cites these changed rules:\n");
    for (missing) |rule| try w.print("- {s} › {s}\n", .{ rule.capability, rule.title });
    try w.writeAll("Add a test for each, with a comment such as `// spec: <spec> › <rule>`, run the tests, then give your final answer.");
    return out.toOwnedSlice();
}

fn toolPair(comptime id: []const u8, comptime name: []const u8, comptime args: []const u8, comptime status: types.PersistedToolStatus, comptime output: []const u8) [2]ChatMessage {
    return .{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = id, .name = name, .arguments_json = args }} },
        .{ .role = .tool, .tool_call_id = id, .tool_name = name, .content = output, .tool_result_status = status },
    };
}

test "test paths and commands" {
    try std.testing.expect(isTestPath("tests/lib/format.test.ts"));
    try std.testing.expect(isTestPath("src/calc_test.go"));
    try std.testing.expect(isTestPath("test_calc.py"));
    try std.testing.expect(isTestPath("src/__tests__/a.js"));
    try std.testing.expect(!isTestPath("src/lib/testing.ts"));
    try std.testing.expect(!isTestPath("src/lib/format.ts"));
    try std.testing.expect(!isTestPath("tests"));

    try std.testing.expect(isTestCommand("bun test tests/lib", null));
    try std.testing.expect(isTestCommand("cd app && CI=1 npm test", null));
    try std.testing.expect(isTestCommand("zig build test -Dtest-filter=x", null));
    try std.testing.expect(!isTestCommand("bun testify", null));
    try std.testing.expect(!isTestCommand("ls tests", null));
    try std.testing.expect(isTestCommand("./scripts/check.sh --fast", "./scripts/check.sh"));
}

test "scan finds red before the source change and green after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const red_then_green = toolPair("c1", "write_file", "{\"path\":\"tests/saldo.test.ts\",\"content\":\"expect(saldo(b)).toBe(70)\"}", .success, "Wrote") ++
        toolPair("c2", "shell", "{\"command\":\"bun test\"}", .failure, "{\"exit_code\":1,\"output_delta\":\"Expected: 70\"}") ++
        toolPair("c3", "edit_file", "{\"path\":\"src/saldo.ts\"}", .success, "Edited") ++
        toolPair("c4", "shell", "{\"command\":\"bun test\"}", .success, "{\"exit_code\":0,\"output_delta\":\"1 pass\"}");
    const done = try scan(arena.allocator(), &red_then_green, "/repo", null, null);
    try std.testing.expect(done.red);
    try std.testing.expect(done.green);
    try std.testing.expectEqual(@as(usize, 1), done.source_files);
    try std.testing.expectEqualStrings("tests/saldo.test.ts", done.tests[0]);

    const before = try scan(arena.allocator(), red_then_green[0..4], "/repo", null, .{ .path = "src/saldo.ts" });
    try std.testing.expect(before.red);
    try std.testing.expect(!before.source_changed);
    try std.testing.expectEqual(@as(usize, 1), before.source_files);

    const missing_runner = toolPair("c1", "write_file", "{\"path\":\"tests/a.test.ts\"}", .success, "Wrote") ++
        toolPair("c2", "shell", "{\"command\":\"bun test\"}", .failure, "{\"exit_code\":127}");
    try std.testing.expect(!(try scan(arena.allocator(), &missing_runner, "/repo", null, null)).red);

    const piped = toolPair("c1", "edit_file", "{\"path\":\"tests/saldo.test.js\"}", .success, "Edited") ++
        toolPair("c2", "shell", "{\"command\":\"bun test 2>&1 | tail -30\"}", .success, "{\"exit_code\":0,\"output_delta\":\" 1 pass\\n 1 fail\\n\"}") ++
        toolPair("c3", "edit_file", "{\"path\":\"src/saldo.js\"}", .success, "Edited") ++
        toolPair("c4", "shell", "{\"command\":\"bun test 2>&1 | tail -30\"}", .success, "{\"exit_code\":0,\"output_delta\":\" 2 pass\\n 0 fail\\n\"}");
    const piped_scan = try scan(arena.allocator(), &piped, "/repo", null, null);
    try std.testing.expect(piped_scan.red);
    try std.testing.expect(piped_scan.green);

    const edited_after_green = red_then_green ++ toolPair("c5", "edit_file", "{\"path\":\"src/other.ts\"}", .success, "Edited");
    const stale = try scan(arena.allocator(), &edited_after_green, "/repo", null, null);
    try std.testing.expect(!stale.green);
    try std.testing.expectEqual(@as(usize, 2), stale.source_files);
}

test "outputShowsFailure reads common runner summaries" {
    try std.testing.expect(outputShowsFailure(" 1 pass\n 1 fail\n"));
    try std.testing.expect(outputShowsFailure("1 failed, 3 passed in 0.2s"));
    try std.testing.expect(outputShowsFailure("Tests:       2 failed, 1 passed"));
    try std.testing.expect(outputShowsFailure("--- FAIL: TestSaldo"));
    try std.testing.expect(outputShowsFailure("test result: FAILED. 0 passed; 1 failed"));
    try std.testing.expect(!outputShowsFailure(" 3 pass\n 0 fail\n"));
    try std.testing.expect(!outputShowsFailure("all passed, nothing failed"));
    try std.testing.expect(!outputShowsFailure("ok  \texample.com/saldo\t0.01s"));
}

test "uncited rules skip manual ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rules = [_]sdd_layout.Rule{
        .{ .capability = "reservas", .title = "Saldo follows Asesor", .body = "" },
        .{ .capability = "reservas", .title = "Pastel colors (manual)", .body = "" },
        .{ .capability = "reservas", .title = "Saldo is the balance", .body = "" },
    };
    const missing = try uncitedRules(arena.allocator(), &rules, &.{ 0, 1, 2 }, "// spec: reservas › Saldo follows Asesor\n");
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("Saldo is the balance", missing[0].title);
}

test "buildState carries the changed tests and the passing run" {
    const alloc = std.testing.allocator;
    const state = try buildState(alloc, "Saldo must subtract refunds", .{
        .tests = &.{"tests/saldo.test.ts"},
        .test_changes = &.{"{\"content\":\"expect(saldo(b)).toBe(70)\"}"},
        .green_output = "1 pass",
    });
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "tests/saldo.test.ts") != null);
    try std.testing.expect(std.mem.find(u8, state, "\"passing_run\":\"1 pass\"") != null);
}
