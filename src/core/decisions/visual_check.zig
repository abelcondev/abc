//! Visual check: a turn that changed how a UI looks ends with a screenshot
//! of the result, taken with Iris (https://github.com/brijr/iris), which the
//! user installs separately and registers as an MCP server.
//!
//! At Stop, after the completion check passes or skips a work turn (the
//! agent reported a blocker or asked the user), when the turn changed UI files and Jev judges the change visual,
//! fx asks the agent once to capture the changed UI with Iris's `capture`
//! tool and compare it with the request, unless the turn already captured
//! after its last UI change. Without an Iris server, fx says so once per
//! process instead of skipping the check silently. Jev only decides; the
//! screenshot is judged by the agent, or by a subagent on a vision model
//! (`jev.visual.model`) when the agent's model cannot read images.

const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

/// MCP server name that marks Iris; its capture tool is `mcp_iris_capture`.
pub const server_name = "iris";
const capture_tool_prefix = "mcp_iris_capture";
const max_config_bytes = 1024 * 1024;

pub const visual_id = "visual_change";
pub const threshold = 0.6;

pub const questions = [_]jev_contract.Question{.{
    .id = visual_id,
    .instructions = "The changes in `changed_files` alter what a user sees on screen (layout, styling, spacing, alignment, icons, text shown in the interface, or which elements appear), so a screenshot is the way to check them",
    .kind = .noul,
}};

const ui_extensions = [_][]const u8{ ".tsx", ".jsx", ".vue", ".svelte", ".astro", ".html", ".css", ".scss", ".sass", ".less" };

/// Whether `path` is a file whose change can alter a UI.
pub fn isUiPath(path: []const u8) bool {
    if (std.mem.find(u8, path, ".test.") != null or std.mem.find(u8, path, ".spec.") != null) return false;
    for (ui_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

pub const Evidence = struct {
    /// UI files changed this turn with the arguments of their last change.
    ui_paths: []const []const u8,
    ui_changes: []const []const u8,
    /// An Iris capture succeeded after the last UI change.
    captured: bool,
};

/// Reads the turn's UI file changes and Iris captures. Allocated in `arena`.
pub fn scan(arena: Allocator, messages: []const ChatMessage) !Evidence {
    var calls: std.StringHashMapUnmanaged(types.ToolCall) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    var changes: std.ArrayList([]const u8) = .empty;
    var captured = false;
    for (messages) |message| {
        for (message.tool_calls) |call| try calls.put(arena, call.id, call);
        if (message.role != .tool) continue;
        const name = message.tool_name orelse continue;
        if ((message.tool_result_status orelse continue) != .success) continue;
        if (std.mem.startsWith(u8, name, capture_tool_prefix)) {
            captured = true;
            continue;
        }
        if (!std.mem.eql(u8, name, "write_file") and !std.mem.eql(u8, name, "edit_file")) continue;
        const call = calls.get(message.tool_call_id orelse continue) orelse continue;
        const path = argString(arena, call.arguments_json, "path") orelse continue;
        if (!isUiPath(path)) continue;
        captured = false;
        if (paths.items.len < 16) {
            try paths.append(arena, path);
            try changes.append(arena, call.arguments_json);
        }
    }
    return .{ .ui_paths = paths.items, .ui_changes = changes.items, .captured = captured };
}

fn argString(arena: Allocator, arguments_json: []const u8, field: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return null;
    if (parsed != .object) return null;
    const value = parsed.object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn buildState(alloc: Allocator, user_request: []const u8, evidence: Evidence) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("user_request");
    try jw.write(turn_text.clip(user_request, 2 * 1024));
    try jw.objectField("changed_files");
    try jw.beginArray();
    var budget: usize = 8 * 1024;
    for (evidence.ui_paths, evidence.ui_changes) |path, change| {
        if (budget == 0) break;
        const text = turn_text.clip(change, @min(budget, 2 * 1024));
        budget -|= text.len;
        try jw.write(.{ .path = path, .change = text });
    }
    try jw.endArray();
    try jw.endObject();
    return out.toOwnedSlice();
}

/// Whether an MCP server named `iris`, or one whose command runs `iris`, is
/// configured in the profile or the workspace `.mcp.json`.
pub fn irisConfigured(alloc: Allocator, workspace_root: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = io_mod.getIo();
    if (io_mod.getenv("HOME")) |home| {
        if (profile_paths.mcpConfigPath(arena, home)) |path| {
            if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_config_bytes))) |bytes| {
                if (mentionsIris(arena, bytes)) return true;
            } else |_| {}
        } else |_| {}
    }
    const project = std.fs.path.join(arena, &.{ workspace_root, ".mcp.json" }) catch return false;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, project, arena, .limited(max_config_bytes)) catch return false;
    return mentionsIris(arena, bytes);
}

/// Looks through `mcp` and `mcpServers` objects for an Iris server.
fn mentionsIris(arena: Allocator, bytes: []const u8) bool {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return false;
    if (root != .object) return false;
    inline for (.{ "mcp", "mcpServers" }) |field| {
        if (root.object.get(field)) |servers| {
            if (servers == .object) {
                var it = servers.object.iterator();
                while (it.next()) |server| {
                    if (std.ascii.eqlIgnoreCase(server.key_ptr.*, server_name)) {
                        if (enabled(server.value_ptr.*)) return true;
                    }
                    if (runsIris(server.value_ptr.*) and enabled(server.value_ptr.*)) return true;
                }
            }
        }
    }
    return false;
}

fn enabled(server: std.json.Value) bool {
    if (server != .object) return false;
    const value = server.object.get("enabled") orelse return true;
    return value != .bool or value.bool;
}

fn runsIris(server: std.json.Value) bool {
    if (server != .object) return false;
    const command = server.object.get("command") orelse return false;
    const first = switch (command) {
        .string => |text| text,
        .array => |items| if (items.items.len != 0 and items.items[0] == .string) items.items[0].string else return false,
        else => return false,
    };
    return std.mem.eql(u8, std.fs.path.basename(first), "iris");
}

/// Continuation asking for a screenshot. Caller owns the text.
pub fn captureReason(alloc: Allocator, evidence: Evidence, vision_model: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("Visual check: capturing the changed UI with Iris before finishing.\n");
    try w.writeAll("This turn changed how the interface looks:\n");
    for (evidence.ui_paths) |path| try w.print("- {s}\n", .{path});
    try w.writeAll("Iris's capture tool is the MCP tool `mcp_iris_capture`; if it is not in your tools, load it first with " ++
        "`mcp_select_tool` and name `mcp_iris_capture`. ");
    try w.writeAll("Capture the page that shows this change: the running dev server or a dev-only preview " ++
        "route, with `selector` for the changed element and `padding` around it. Compare the image with the request and fix " ++
        "what does not match, then capture again. If the page needs a login or clicks to reach, say that it could not be " ++
        "captured instead of guessing. ");
    if (vision_model) |model| {
        try w.print("If your model cannot read images (the tool result says the image was withheld), run a subagent with model " ++
            "`{s}` that captures the same page and reports what it sees. ", .{model});
    } else {
        try w.writeAll("If your model cannot read images (the tool result says the image was withheld), say so in one line; " ++
            "the user can set `jev.visual.model` to a vision model for that check. ");
    }
    try w.writeAll("Reply with only what the capture showed and what you changed.");
    return out.toOwnedSlice();
}

pub const missing_reason =
    "Visual check skipped: Iris is not set up.\n" ++
    "This turn changed how the interface looks, but no Iris MCP server is configured, so no screenshot was taken. " ++
    "Tell the user in one line that the visual check was skipped and that installing Iris " ++
    "(https://github.com/brijr/iris) and registering it as an MCP server named `iris` enables it. Do not repeat your answer.";

test "isUiPath keeps interface files and skips tests" {
    try std.testing.expect(isUiPath("src/components/Card.tsx"));
    try std.testing.expect(isUiPath("styles/app.css"));
    try std.testing.expect(!isUiPath("src/lib/total.ts"));
    try std.testing.expect(!isUiPath("tests/Card.test.tsx"));
}

test "scan resets the capture after a later UI change" {
    const pair = struct {
        fn make(comptime id: []const u8, comptime name: []const u8, comptime args: []const u8) [2]ChatMessage {
            return .{
                .{ .role = .assistant, .tool_calls = &.{.{ .id = id, .name = name, .arguments_json = args }} },
                .{ .role = .tool, .tool_call_id = id, .tool_name = name, .content = "ok", .tool_result_status = .success },
            };
        }
    }.make;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const captured = pair("a", "edit_file", "{\"path\":\"src/Card.tsx\"}") ++ pair("b", "mcp_iris_capture", "{\"url\":\"localhost:5173\"}");
    const first = try scan(arena.allocator(), &captured);
    try std.testing.expect(first.captured);
    try std.testing.expectEqual(@as(usize, 1), first.ui_paths.len);
    const changed_again = captured ++ pair("c", "edit_file", "{\"path\":\"src/Card.css\"}") ++ pair("d", "edit_file", "{\"path\":\"src/lib/x.ts\"}");
    const second = try scan(arena.allocator(), &changed_again);
    try std.testing.expect(!second.captured);
    try std.testing.expectEqual(@as(usize, 2), second.ui_paths.len);
}

test "mentionsIris finds a server by name or command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(mentionsIris(a, "{\"mcp\":{\"iris\":{\"type\":\"local\",\"command\":[\"iris\",\"mcp\"]}}}"));
    try std.testing.expect(mentionsIris(a, "{\"mcpServers\":{\"camera\":{\"command\":\"/opt/bin/iris\",\"args\":[\"mcp\"]}}}"));
    try std.testing.expect(!mentionsIris(a, "{\"mcp\":{\"iris\":{\"command\":[\"iris\"],\"enabled\":false}}}"));
    try std.testing.expect(!mentionsIris(a, "{\"mcp\":{\"engram\":{\"command\":[\"engram\",\"mcp\"]}}}"));
}

test "captureReason names the vision model when set" {
    const evidence = Evidence{ .ui_paths = &.{"src/Card.tsx"}, .ui_changes = &.{"{}"}, .captured = false };
    const with_model = try captureReason(std.testing.allocator, evidence, "qwen-vl");
    defer std.testing.allocator.free(with_model);
    try std.testing.expect(std.mem.startsWith(u8, with_model, "Visual check: capturing the changed UI with Iris"));
    try std.testing.expect(std.mem.find(u8, with_model, "model `qwen-vl`") != null);
    const without = try captureReason(std.testing.allocator, evidence, null);
    defer std.testing.allocator.free(without);
    try std.testing.expect(std.mem.find(u8, without, "jev.visual.model") != null);
}
