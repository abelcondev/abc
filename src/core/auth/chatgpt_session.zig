const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const native_auth_store = if (host_target.is_wasm) struct {} else @import("../hosts/native_auth_store.zig");
const host = @import("../hosts/host.zig");
const types = @import("../shared/types.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const expiry_skew_ms: i64 = 60 * 1000;

pub const issuer = "https://auth.openai.com";

pub fn presence() host.SecretStorePresence {
    if (comptime host_target.is_wasm) return .missing;
    return native_auth_store.entry_presence(.chatgpt_subscription);
}

pub fn refreshDeadlineMs(expires_at_ms: i64) i64 {
    return @max(expires_at_ms - expiry_skew_ms, 0);
}

pub const Session = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    account_id: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refreshDeadlineMs(self.expires_at_ms) <= now_ms;
    }
};

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const Mutation = if (host_target.is_wasm) WasmMutation else NativeMutation;

const WasmMutation = struct {
    pub fn deinit(self: *WasmMutation) void {
        self.* = undefined;
    }

    pub fn load(_: *WasmMutation, _: Allocator) !?Session {
        return null;
    }

    pub fn save(_: *WasmMutation, _: Allocator, _: Session) !void {
        return error.ChatGptOAuthUnavailable;
    }

    pub fn delete(_: *WasmMutation) !DeleteOutcome {
        return .missing;
    }
};

const NativeMutation = struct {
    inner: native_auth_store.EntryMutation,

    pub fn deinit(self: *Mutation) void {
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        const bytes = (try self.inner.load(alloc)) orelse return null;
        defer secret.zeroAndFree(alloc, bytes);
        return parse(alloc, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                debug_trace.logf("auth", "ChatGPT session load failed step=parse_common_mutation err={s}", .{@errorName(err)});
                return null;
            },
        };
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try self.inner.save(alloc, text);
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        return switch (try self.inner.delete(std.heap.c_allocator)) {
            .deleted => .deleted,
            .missing => .missing,
            .deleted_not_durable => .deleted_not_durable,
        };
    }
};

pub fn load(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return null;
    return loadNative(alloc, .active);
}

pub fn loadStored(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return null;
    return loadNative(alloc, .inspect);
}

fn loadNative(alloc: Allocator, intent: @import("auth_store.zig").LoadIntent) !?Session {
    const bytes = (native_auth_store.load_entry(alloc, .chatgpt_subscription, intent) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "ChatGPT session load failed step=common_store err={s}", .{@errorName(err)});
            return null;
        },
    }) orelse return null;
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "ChatGPT session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
    var mutation = try beginExistingMutation() orelse return error.HomeNotSet;
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) return null;
    return .{ .inner = try native_auth_store.begin_entry_mutation(.chatgpt_subscription) };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChatGptAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidChatGptAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidChatGptAuthSession;

    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const account_id = try dupeRequiredString(alloc, object, "account_id");
    errdefer alloc.free(account_id);
    if (!types.validCredentialAccountId(account_id)) return error.InvalidChatGptAuthSession;
    const expires_at_ms = try requiredInteger(object, "expires_at_ms");
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"access_token\":");
    try std.json.Stringify.value(session.access_token, .{}, &out.writer);
    try out.writer.writeAll(",\"refresh_token\":");
    try std.json.Stringify.value(session.refresh_token, .{}, &out.writer);
    try out.writer.print(",\"expires_at_ms\":{d},\"account_id\":", .{session.expires_at_ms});
    try std.json.Stringify.value(session.account_id, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidChatGptAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidChatGptAuthSession;
    return alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidChatGptAuthSession;
    if (value != .integer) return error.InvalidChatGptAuthSession;
    return value.integer;
}

test "ChatGPT auth session round trips without exposing token fields to structure" {
    const alloc = std.testing.allocator;
    var session = Session{
        .access_token = try alloc.dupe(u8, "header.payload.signature"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 1234,
        .account_id = try alloc.dupe(u8, "acct_123"),
    };
    defer session.deinit(alloc);

    const encoded = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, encoded);
    var decoded = try parse(alloc, encoded);
    defer decoded.deinit(alloc);

    try std.testing.expectEqualStrings(session.access_token, decoded.access_token);
    try std.testing.expectEqualStrings(session.refresh_token, decoded.refresh_token);
    try std.testing.expectEqualStrings(session.account_id, decoded.account_id);
    try std.testing.expectEqual(session.expires_at_ms, decoded.expires_at_ms);
}

test "ChatGPT session refresh deadline keeps a one minute safety margin" {
    try std.testing.expectEqual(@as(i64, 40_000), refreshDeadlineMs(100_000));
    try std.testing.expectEqual(@as(i64, 0), refreshDeadlineMs(10_000));
}

test "ChatGPT auth session rejects account identifiers unsafe for HTTP headers" {
    var session = parse(
        std.testing.allocator,
        "{\"version\":1,\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1000,\"account_id\":\"acct\\r\\ninjected\"}",
    ) catch |err| {
        try std.testing.expectEqual(error.InvalidChatGptAuthSession, err);
        return;
    };
    defer session.deinit(std.testing.allocator);
    return error.TestExpectedInvalidChatGptAuthSession;
}
