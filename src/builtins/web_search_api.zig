//! Web search through a search API, usable with any model provider.
//!
//! Backends are enabled by environment: TAVILY_API_KEY, BRAVE_API_KEY
//! (Brave Search API subscription token), or ABC_SEARXNG_URL pointing at a
//! SearXNG instance with the JSON format enabled. When several are set they
//! are preferred in that order; ABC_WEB_SEARCH_BACKEND=tavily|brave|searxng
//! pins one.

const std = @import("std");
const client_mod = @import("../gateway/client.zig");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const types = @import("../core/shared/types.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");

const Allocator = std.mem.Allocator;
const BackendId = web_search_contract.SearchBackendId;

const Backend = enum { tavily, brave, searxng };

const backend_ids = [_]BackendId{
    .{ .value = "tavily" },
    .{ .value = "brave" },
    .{ .value = "searxng" },
};

fn backendId(backend: Backend) BackendId {
    return backend_ids[@intFromEnum(backend)];
}

fn backendFromId(id: BackendId) ?Backend {
    for (backend_ids, 0..) |candidate, index| {
        if (candidate.eql(id)) return @enumFromInt(index);
    }
    return null;
}

fn features(domain_filters: web_search_contract.BackendFeatureMode) web_search_contract.BackendCapabilities {
    return .{
        .max_uses = .best_effort,
        .allowed_domains = domain_filters,
        .blocked_domains = domain_filters,
        .ordered_sources = true,
        .usage = true,
        .terminal_incomplete = true,
        .timeout = true,
        .cancellation = true,
        .result_bounds = .post_filter,
    };
}

const backend_policies = [_]web_search_policy.BackendPolicy{
    .{ .id = backendId(.tavily), .features = features(.pass_through) },
    .{ .id = backendId(.brave), .features = features(.unsupported) },
    .{ .id = backendId(.searxng), .features = features(.unsupported) },
};

/// Every ordered subset of the backends, indexed by availability bitmask, so
/// the preferred list can be returned without shared mutable storage.
const backend_orders = blk: {
    var orders: [8][]const BackendId = undefined;
    for (0..8) |mask| {
        var ids: []const BackendId = &.{};
        for (0..backend_ids.len) |index| {
            if (mask & (1 << index) != 0) ids = ids ++ [_]BackendId{backend_ids[index]};
        }
        orders[mask] = ids;
    }
    break :blk orders;
};

const single_backend = [_][]const BackendId{
    &.{backend_ids[0]},
    &.{backend_ids[1]},
    &.{backend_ids[2]},
};

pub const policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = backend_orders[7],
    .backend_policies = &backend_policies,
};

pub const provider = web_search_provider.Provider{
    .policy = policy,
    .preferred_backends_fn = preferredBackends,
    .execute_fn = execute,
    .ready_fn = available,
};

/// Search APIs when one is configured, otherwise `fallback` (the gateway's
/// model-driven search). The choice is made per request from the environment.
pub fn withFallback(comptime fallback: web_search_provider.Provider) web_search_provider.Provider {
    const Composite = struct {
        const merged_policy = blk: {
            var merged = fallback.policy;
            merged.preferred_backends = backend_orders[7] ++ fallback.policy.preferred_backends;
            merged.backend_policies = &(backend_policies ++ fallback.policy.backend_policies[0..fallback.policy.backend_policies.len].*);
            break :blk merged;
        };

        fn preferred(context: ?*anyopaque) !?[]const BackendId {
            if (nonEmptyEnv("ABC_WEB_SEARCH_BACKEND") != null or available()) return preferredBackends(null);
            return fallback.preferred_backends_fn(context);
        }

        fn run(
            context: ?*anyopaque,
            alloc: Allocator,
            inputs: web_search_provider.Inputs,
            request: web_search_contract.ProviderRequest,
            on_progress: ?web_search_contract.ProgressFn,
            progress_ctx: ?*anyopaque,
        ) !web_search_contract.ProviderResponse {
            if (backendFromId(request.backend) != null) return execute(null, alloc, inputs, request, on_progress, progress_ctx);
            return fallback.execute_fn(context, alloc, inputs, request, on_progress, progress_ctx);
        }
    };
    return .{
        .context = fallback.context,
        .policy = Composite.merged_policy,
        .input_overhead_bytes = fallback.input_overhead_bytes,
        .preferred_backends_fn = Composite.preferred,
        .execute_fn = Composite.run,
        .ready_fn = available,
    };
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const value = io_mod.getenv(name) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn backendConfigured(backend: Backend) bool {
    return switch (backend) {
        .tavily => nonEmptyEnv("TAVILY_API_KEY") != null,
        .brave => nonEmptyEnv("BRAVE_API_KEY") != null,
        .searxng => nonEmptyEnv("ABC_SEARXNG_URL") != null,
    };
}

/// True when at least one search API is configured.
pub fn available() bool {
    return availableMask() != 0;
}

fn availableMask() usize {
    var mask: usize = 0;
    inline for (@typeInfo(Backend).@"enum".fields) |field| {
        if (backendConfigured(@field(Backend, field.name))) mask |= 1 << field.value;
    }
    return mask;
}

fn preferredBackends(_: ?*anyopaque) !?[]const BackendId {
    if (nonEmptyEnv("ABC_WEB_SEARCH_BACKEND")) |pinned| {
        inline for (@typeInfo(Backend).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(pinned, field.name)) return single_backend[field.value];
        }
        return error.UnknownWebSearchBackend;
    }
    return backend_orders[availableMask()];
}

const Hit = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

const HttpResult = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *HttpResult, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

const HttpOperation = struct {
    alloc: Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,

    pub fn run(self: *const HttpOperation) !HttpResult {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        const result = try client.fetch(.{
            .location = .{ .url = self.url },
            .method = self.method,
            .payload = self.body,
            .headers = .{
                .accept_encoding = .omit,
                .user_agent = .{ .override = client_mod.user_agent },
                .content_type = if (self.body != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = self.headers,
            .response_writer = &out.writer,
            .redirect_behavior = .unhandled,
        });
        return .{ .status = result.status, .body = try out.toOwnedSlice() };
    }
};

/// The request runs as a concurrent task, so it allocates from the
/// thread-safe C allocator; callers copy what they keep and free the result.
const http_alloc = std.heap.c_allocator;

fn send(request: web_search_contract.ProviderRequest, operation: *const HttpOperation) !HttpResult {
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(request.timeout_ms),
    });
    return client_mod.runBoundedHttpOperation(HttpResult, http_alloc, @constCast(request.cancel_flag), deadline, operation);
}

fn execute(
    _: ?*anyopaque,
    alloc: Allocator,
    _: web_search_provider.Inputs,
    request: web_search_contract.ProviderRequest,
    on_progress: ?web_search_contract.ProgressFn,
    progress_ctx: ?*anyopaque,
) !web_search_contract.ProviderResponse {
    const backend = backendFromId(request.backend) orelse return error.UnknownWebSearchBackend;
    if (on_progress) |callback| if (progress_ctx) |ctx| callback(ctx, .{ .query_update = request.query });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hits = searchBackend(arena, backend, request) catch |err| switch (err) {
        error.Cancelled, error.Timeout, error.OutOfMemory => |failure| return failure,
        else => {
            debug_trace.logf("web_search", "search api failed backend={s} err={s}", .{ @tagName(backend), @errorName(err) });
            return errorResponse(alloc, backend, err);
        },
    };
    if (on_progress) |callback| if (progress_ctx) |ctx| callback(ctx, .{ .results_received = .{ .query = request.query, .result_count = hits.len } });
    return buildResponse(alloc, request, hits);
}

fn errorResponse(alloc: Allocator, backend: Backend, err: anyerror) !web_search_contract.ProviderResponse {
    const text = try std.fmt.allocPrint(alloc, "Web search via {s} failed: {s}", .{ @tagName(backend), @errorName(err) });
    errdefer alloc.free(text);
    const items = try alloc.alloc(web_search_contract.ResultItem, 1);
    items[0] = .{ .error_text = text };
    return .{ .content = items, .usage = .{ .web_search_requests = 1 } };
}

fn searchBackend(arena: Allocator, backend: Backend, request: web_search_contract.ProviderRequest) ![]const Hit {
    const count = @max(@as(u8, 1), request.max_results);
    return switch (backend) {
        .tavily => blk: {
            const key = nonEmptyEnv("TAVILY_API_KEY") orelse return error.MissingSearchApiKey;
            var body: std.Io.Writer.Allocating = .init(arena);
            try std.json.Stringify.value(.{
                .query = request.query,
                .max_results = count,
                .search_depth = "basic",
                .include_domains = request.allowed_domains orelse &.{},
                .exclude_domains = request.blocked_domains orelse &.{},
            }, .{}, &body.writer);
            const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{key});
            var result = try send(request, &.{
                .alloc = http_alloc,
                .method = .POST,
                .url = "https://api.tavily.com/search",
                .headers = &.{.{ .name = "authorization", .value = authorization }},
                .body = body.written(),
            });
            defer result.deinit(http_alloc);
            try requireOk(result.status);
            break :blk try parseHits(arena, result.body, &.{"results"}, "content");
        },
        .brave => blk: {
            const key = nonEmptyEnv("BRAVE_API_KEY") orelse return error.MissingSearchApiKey;
            const url = try std.fmt.allocPrint(arena, "https://api.search.brave.com/res/v1/web/search?count={d}&q={f}", .{ @min(count, 20), queryEscape(request.query) });
            var result = try send(request, &.{
                .alloc = http_alloc,
                .method = .GET,
                .url = url,
                .headers = &.{ .{ .name = "x-subscription-token", .value = key }, .{ .name = "accept", .value = "application/json" } },
                .body = null,
            });
            defer result.deinit(http_alloc);
            try requireOk(result.status);
            break :blk try parseHits(arena, result.body, &.{ "web", "results" }, "description");
        },
        .searxng => blk: {
            const base = nonEmptyEnv("ABC_SEARXNG_URL") orelse return error.MissingSearchApiKey;
            const trimmed = std.mem.trimEnd(u8, base, "/");
            const url = try std.fmt.allocPrint(arena, "{s}/search?format=json&q={f}", .{ trimmed, queryEscape(request.query) });
            var result = try send(request, &.{
                .alloc = http_alloc,
                .method = .GET,
                .url = url,
                .headers = &.{.{ .name = "accept", .value = "application/json" }},
                .body = null,
            });
            defer result.deinit(http_alloc);
            try requireOk(result.status);
            const hits = try parseHits(arena, result.body, &.{"results"}, "content");
            break :blk hits[0..@min(hits.len, count)];
        },
    };
}

fn requireOk(status: std.http.Status) !void {
    switch (status) {
        .ok => {},
        .unauthorized, .forbidden => return error.SearchApiUnauthorized,
        .too_many_requests => return error.SearchApiRateLimited,
        else => return error.SearchApiHttpError,
    }
}

const QueryEscape = struct {
    text: []const u8,

    pub fn format(self: QueryEscape, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.text) |byte| {
            if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
                try writer.writeByte(byte);
            } else if (byte == ' ') {
                try writer.writeByte('+');
            } else {
                try writer.print("%{X:0>2}", .{byte});
            }
        }
    }
};

fn queryEscape(text: []const u8) QueryEscape {
    return .{ .text = text };
}

/// Reads `path` (object keys) to an array of objects with title, url and the
/// named snippet field. Entries without a url are skipped.
fn parseHits(arena: Allocator, body: []const u8, path: []const []const u8, snippet_field: []const u8) ![]const Hit {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always }) catch return error.SearchApiMalformedResponse;
    var node = parsed;
    for (path) |key| {
        if (node != .object) return error.SearchApiMalformedResponse;
        node = node.object.get(key) orelse return &.{};
    }
    if (node != .array) return error.SearchApiMalformedResponse;
    var hits: std.ArrayList(Hit) = .empty;
    for (node.array.items) |item| {
        if (item != .object) continue;
        const url = stringField(item, "url") orelse continue;
        try hits.append(arena, .{
            .title = stringField(item, "title") orelse url,
            .url = url,
            .snippet = stringField(item, snippet_field) orelse "",
        });
    }
    return hits.items;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = value.object.get(key) orelse return null;
    return if (field == .string and field.string.len != 0) field.string else null;
}

/// Commentary lists the hits with snippets; the search block carries the
/// sources for citation. Output is bounded by max_output_chars.
fn buildResponse(alloc: Allocator, request: web_search_contract.ProviderRequest, hits: []const Hit) !web_search_contract.ProviderResponse {
    var commentary: std.Io.Writer.Allocating = .init(alloc);
    defer commentary.deinit();
    if (hits.len == 0) {
        try commentary.writer.print("No web results for \"{s}\".", .{request.query});
    }
    const limit = request.max_output_chars;
    for (hits, 1..) |hit, number| {
        if (commentary.written().len >= limit) break;
        try commentary.writer.print("{d}. {s}\n   {s}\n", .{ number, hit.title, hit.url });
        if (hit.snippet.len != 0) {
            const room = limit -| commentary.written().len;
            const snippet = std.mem.trim(u8, hit.snippet[0..@min(hit.snippet.len, @min(room, 1200))], " \t\r\n");
            try commentary.writer.print("   {s}\n", .{snippet});
        }
    }
    const text = try commentary.toOwnedSlice();
    var text_owned = true;
    errdefer if (text_owned) alloc.free(text);

    const sources = try alloc.alloc(web_search_contract.Source, hits.len);
    var initialized: usize = 0;
    errdefer {
        for (sources[0..initialized]) |source| source.deinit(alloc);
        alloc.free(sources);
    }
    for (hits) |hit| {
        const title = try alloc.dupe(u8, hit.title);
        errdefer alloc.free(title);
        sources[initialized] = .{ .title = title, .url = try alloc.dupe(u8, hit.url) };
        initialized += 1;
    }
    const tool_use_id = try alloc.dupe(u8, "search_api_1");
    errdefer alloc.free(tool_use_id);
    const items = try alloc.alloc(web_search_contract.ResultItem, 2);
    items[0] = .{ .commentary = text };
    text_owned = false;
    items[1] = .{ .search = .{ .tool_use_id = tool_use_id, .content = sources } };
    return .{ .content = items, .usage = .{ .web_search_requests = 1 } };
}

test "search api policy admits every backend and orders subsets" {
    for (backend_policies) |backend| {
        try std.testing.expect(web_search_policy.backendCanSatisfy(backend, .{}));
    }
    try std.testing.expect(web_search_policy.backendCanSatisfy(backend_policies[0], .{ .has_allowed_domains = true }));
    try std.testing.expect(!web_search_policy.backendCanSatisfy(backend_policies[1], .{ .has_allowed_domains = true }));
    try std.testing.expectEqual(@as(usize, 0), backend_orders[0].len);
    try std.testing.expectEqualStrings("brave", backend_orders[2][0].value);
    try std.testing.expectEqual(@as(usize, 2), backend_orders[5].len);
    try std.testing.expectEqualStrings("searxng", backend_orders[5][1].value);
}

test "search api parses tavily brave and searxng shapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tavily = try parseHits(arena, "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"content\":\"A language\"},{\"title\":\"no url\"}]}", &.{"results"}, "content");
    try std.testing.expectEqual(@as(usize, 1), tavily.len);
    try std.testing.expectEqualStrings("A language", tavily[0].snippet);
    const brave = try parseHits(arena, "{\"web\":{\"results\":[{\"title\":\"B\",\"url\":\"https://b.example\",\"description\":\"desc\"}]}}", &.{ "web", "results" }, "description");
    try std.testing.expectEqualStrings("https://b.example", brave[0].url);
    const empty = try parseHits(arena, "{\"query\":\"x\"}", &.{ "web", "results" }, "description");
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.SearchApiMalformedResponse, parseHits(arena, "not json", &.{"results"}, "content"));
}

test "search api response lists hits and sources within bounds" {
    const alloc = std.testing.allocator;
    const cancel = std.atomic.Value(bool).init(false);
    const hits = [_]Hit{
        .{ .title = "Zig", .url = "https://ziglang.org", .snippet = "A language" },
        .{ .title = "Docs", .url = "https://ziglang.org/documentation", .snippet = "" },
    };
    var response = try buildResponse(alloc, .{ .backend = backendId(.tavily), .query = "zig", .cancel_flag = &cancel }, &hits);
    defer response.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), response.content.len);
    const text = response.content[0].commentary;
    try std.testing.expect(std.mem.find(u8, text, "1. Zig") != null);
    try std.testing.expect(std.mem.find(u8, text, "A language") != null);
    try std.testing.expectEqual(@as(usize, 2), response.content[1].search.content.len);
    try std.testing.expectEqual(@as(u32, 1), response.usage.?.web_search_requests);
}

test "search api escapes queries for urls" {
    var buffer: [64]u8 = undefined;
    const escaped = try std.fmt.bufPrint(&buffer, "{f}", .{queryEscape("zig 0.16 & c++")});
    try std.testing.expectEqualStrings("zig+0.16+%26+c%2B%2B", escaped);
}
