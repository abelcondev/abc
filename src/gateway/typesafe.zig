//! HTTP transport for TypeSafe AI's System One API (Jev).
//!
//! One bounded POST to `<base_url>/v1/systemone` with a bearer key. Rate
//! limits, overload and server errors get one retry; everything else is
//! reported to the caller, which decides how an unavailable decision is
//! handled. There is no streaming.

const std = @import("std");
const client_mod = @import("client.zig");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const jev_contract = @import("../core/decisions/jev_contract.zig");

const Allocator = std.mem.Allocator;

pub const default_base_url = "https://api.typesafe.ai";

pub const Request = struct {
    base_url: []const u8 = default_base_url,
    api_key: []const u8,
    model: []const u8,
    /// One JSON value embedded as the request `state`.
    state_json: []const u8,
    questions: []const jev_contract.Question,
    timeout_ms: u32 = 15_000,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const Error = jev_contract.ParseError || error{
    Cancelled,
    Timeout,
    JevUnauthorized,
    JevRequestRejected,
    JevUnavailable,
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
    url: []const u8,
    authorization: []const u8,
    body: []const u8,

    pub fn run(self: *const HttpOperation) !HttpResult {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        const result = try client.fetch(.{
            .location = .{ .url = self.url },
            .method = .POST,
            .payload = self.body,
            .headers = .{
                .accept_encoding = .omit,
                .user_agent = .{ .override = client_mod.user_agent },
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.authorization },
            },
            .response_writer = &out.writer,
            .redirect_behavior = .unhandled,
        });
        return .{ .status = result.status, .body = try out.toOwnedSlice() };
    }
};

/// The request runs as a concurrent task, so it allocates from the
/// thread-safe C allocator; the parsed response is copied into `alloc`.
const http_alloc = std.heap.c_allocator;

/// Evaluates `request.questions` against `request.state_json`. The caller owns
/// the returned response and frees it with `deinit`.
pub fn systemOne(alloc: Allocator, request: Request) Error!jev_contract.Response {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    jev_contract.writeRequest(&body.writer, request.model, request.state_json, request.questions) catch return error.OutOfMemory;

    const trimmed_base = std.mem.trimEnd(u8, request.base_url, "/");
    const url = try std.fmt.allocPrint(alloc, "{s}/v1/systemone", .{trimmed_base});
    defer alloc.free(url);
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer {
        std.crypto.secureZero(u8, authorization);
        alloc.free(authorization);
    }

    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = request.cancel_flag orelse &local_cancel;
    const operation = HttpOperation{
        .alloc = http_alloc,
        .url = url,
        .authorization = authorization,
        .body = body.written(),
    };

    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(request.timeout_ms),
        });
        var result = client_mod.runBoundedHttpOperation(HttpResult, http_alloc, cancel_flag, deadline, &operation) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.Timeout => {
                if (attempt == 0) continue;
                return error.Timeout;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("jev", "transport failed err={s} attempt={d}", .{ @errorName(err), attempt });
                if (attempt == 0) continue;
                return error.JevUnavailable;
            },
        };
        defer result.deinit(http_alloc);
        switch (classify(result.status)) {
            .ok => return jev_contract.parseResponse(alloc, result.body),
            .unauthorized => return error.JevUnauthorized,
            .rejected => {
                debug_trace.logf("jev", "request rejected status={d} body={s}", .{ @intFromEnum(result.status), result.body[0..@min(result.body.len, 512)] });
                return error.JevRequestRejected;
            },
            .retryable => {
                debug_trace.logf("jev", "retryable status={d} attempt={d}", .{ @intFromEnum(result.status), attempt });
                if (attempt == 0) {
                    io_mod.sleep(500 * std.time.ns_per_ms);
                    continue;
                }
                return error.JevUnavailable;
            },
        }
    }
}

const StatusClass = enum { ok, unauthorized, rejected, retryable };

fn classify(status: std.http.Status) StatusClass {
    const code = @intFromEnum(status);
    if (code >= 200 and code < 300) return .ok;
    if (code == 401 or code == 403) return .unauthorized;
    if (code == 408 or code == 429 or code >= 500) return .retryable;
    return .rejected;
}

test "classify maps documented statuses" {
    try std.testing.expectEqual(StatusClass.ok, classify(.ok));
    try std.testing.expectEqual(StatusClass.unauthorized, classify(.unauthorized));
    try std.testing.expectEqual(StatusClass.rejected, classify(.unprocessable_entity));
    try std.testing.expectEqual(StatusClass.retryable, classify(.too_many_requests));
    try std.testing.expectEqual(StatusClass.retryable, classify(@enumFromInt(529)));
    try std.testing.expectEqual(StatusClass.retryable, classify(.internal_server_error));
}
