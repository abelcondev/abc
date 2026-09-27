//! Model routing: when the agent starts a temporary subagent without naming a
//! model, Jev picks one of the user's configured routes for the task and fx
//! fills in that route's model and effort.
//!
//! Routes come only from profile settings (`jev.routing`). A call that already
//! names a model, or targets a persistent child, is left unchanged.

const std = @import("std");
const jev_contract = @import("jev_contract.zig");
const turn_text = @import("turn_text.zig");

const Allocator = std.mem.Allocator;

pub const tool_name = "subagent";
pub const max_routes = 8;
pub const route_id = "route";

pub const Route = struct {
    name: []const u8,
    model: []const u8,
    effort: ?[]const u8 = null,
    description: []const u8,
};

pub const Limits = struct {
    pub const task_bytes = 8 * 1024;
};

/// Default descriptions for the conventional route names.
pub fn defaultDescription(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "light")) return "quick lookups, searching or reading code, summaries, small mechanical edits";
    if (std.mem.eql(u8, name, "heavy")) return "hard reasoning, debugging, design, or changes across several files";
    return null;
}

/// The task text of a `subagent` run call that names no model, or null when
/// the call is left alone. Borrows from `arena`.
pub fn routableTask(arena: Allocator, arguments_json: []const u8) ?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return null;
    if (root != .object) return null;
    const request = root.object.get("request") orelse return null;
    if (request != .object) return null;
    const action = request.object.get("action") orelse return null;
    if (action != .string or !std.mem.eql(u8, action.string, "run")) return null;
    if (request.object.get("model") != null) return null;
    return switch (request.object.get("task") orelse return null) {
        .string => |task| task,
        else => null,
    };
}

pub fn questions(arena: Allocator, routes: []const Route) ![]const jev_contract.Question {
    const options = try arena.alloc(jev_contract.Option, routes.len);
    for (routes, 0..) |route, index| options[index] = .{ .name = route.name, .description = route.description };
    const list = try arena.alloc(jev_contract.Question, 1);
    list[0] = .{ .id = route_id, .instructions = "Which route fits `task` best", .kind = .{ .choice = options } };
    return list;
}

pub fn buildState(alloc: Allocator, task: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(.{ .task = turn_text.clip(task, Limits.task_bytes) }, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Minimum confidence for applying a route.
pub const min_confidence = 0.6;

pub fn pick(routes: []const Route, response: *const jev_contract.Response) ?Route {
    const answer = response.choice(route_id) orelse return null;
    if (answer.confidence < min_confidence) return null;
    for (routes) |route| {
        if (std.mem.eql(u8, route.name, answer.choice)) return route;
    }
    return null;
}

/// The call's arguments with the route's model (and effort, when the call
/// sets none) added to `request`. Caller owns the returned JSON.
pub fn rewriteArguments(alloc: Allocator, arguments_json: []const u8, route: Route) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{});
    defer parsed.deinit();
    const a = parsed.arena.allocator();
    const request = parsed.value.object.getPtr("request") orelse return error.InvalidSubagentArguments;
    if (request.* != .object) return error.InvalidSubagentArguments;
    try request.object.put(a, "model", .{ .string = route.model });
    if (route.effort) |effort| {
        if (request.object.get("effort") == null) try request.object.put(a, "effort", .{ .string = effort });
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "routableTask accepts only run calls without a model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("list files", routableTask(arena, "{\"request\":{\"action\":\"run\",\"task\":\"list files\"}}").?);
    try std.testing.expect(routableTask(arena, "{\"request\":{\"action\":\"run\",\"task\":\"x\",\"model\":\"m\"}}") == null);
    try std.testing.expect(routableTask(arena, "{\"request\":{\"action\":\"message\",\"agent\":\"a\",\"message\":\"x\"}}") == null);
    try std.testing.expect(routableTask(arena, "[]") == null);
}

test "pick and rewriteArguments apply a confident route" {
    const alloc = std.testing.allocator;
    const routes = [_]Route{
        .{ .name = "light", .model = "deepseek-flash", .effort = "low", .description = "quick" },
        .{ .name = "heavy", .model = "qwen3.8-max", .description = "hard" },
    };
    var response = try jev_contract.parseResponse(alloc,
        \\{"model":"m","answers":{"route":{"type":"choice","choice":"light","confidence":0.99}}}
    );
    defer response.deinit();
    const route = pick(&routes, &response).?;
    try std.testing.expectEqualStrings("deepseek-flash", route.model);
    const rewritten = try rewriteArguments(alloc, "{\"request\":{\"action\":\"run\",\"task\":\"list files\"}}", route);
    defer alloc.free(rewritten);
    try std.testing.expectEqualStrings("{\"request\":{\"action\":\"run\",\"task\":\"list files\",\"model\":\"deepseek-flash\",\"effort\":\"low\"}}", rewritten);

    var unsure = try jev_contract.parseResponse(alloc,
        \\{"model":"m","answers":{"route":{"type":"choice","choice":"heavy","confidence":0.4}}}
    );
    defer unsure.deinit();
    try std.testing.expect(pick(&routes, &unsure) == null);
}
