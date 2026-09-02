const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_contract = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const native_auth_store = if (host_target.is_wasm) struct {} else @import("../hosts/native_auth_store.zig");
const io_mod = @import("../shared/io.zig");
const js_host_auth = @import("js_host_auth.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const issuer = "https://vercel.com";
pub const client_id_env = "FX_OAUTH_CLIENT_ID";
pub const default_client_id = "cl_zzh5hiOZbwJ9bfqEcYqPIJv3TaPaEYL0";
const e2e_issuer_url_env = "FX_E2E_OAUTH_ISSUER_URL";
const schema_version: i64 = 1;
const expiry_skew_ms: i64 = 60 * 1000;
pub fn presence() host_contract.SecretStorePresence {
    if (comptime host_target.is_wasm) {
        const alloc = std.heap.c_allocator;
        var stored = (js_host_auth.oauth_session_store.load(alloc) catch return .unavailable) orelse
            return .missing;
        defer stored.deinit(alloc);
        return .present;
    }
    return native_auth_store.entry_presence(.fx_login);
}

pub fn refresh_deadline_ms(expires_at_ms: i64) i64 {
    return expires_at_ms -| expiry_skew_ms;
}

pub const DeleteResult = struct {
    session_deleted: bool = false,
    local_cleanup_failed: bool = false,
};

pub const Session = struct {
    issuer: []u8,
    client_id: []u8,
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    scope: []u8,
    token_type: []u8,
    team_slug: ?[]u8 = null,
    team_id: ?[]u8 = null,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.issuer);
        alloc.free(self.client_id);
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.scope);
        alloc.free(self.token_type);
        if (self.team_slug) |value| alloc.free(value);
        if (self.team_id) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refresh_deadline_ms(self.expires_at_ms) <= now_ms;
    }
};

pub const Mutation = if (host_target.is_wasm) HostMutation else CommonNativeMutation;

const CommonNativeMutation = struct {
    inner: native_auth_store.EntryMutation,

    pub fn deinit(self: *CommonNativeMutation) void {
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn load(self: *CommonNativeMutation, alloc: Allocator) !?Session {
        const bytes = (try self.inner.load(alloc)) orelse return null;
        defer secret.zeroAndFree(alloc, bytes);
        return parse(alloc, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                debug_trace.logf("auth", "session load failed step=parse_common_mutation err={s}", .{@errorName(err)});
                return null;
            },
        };
    }

    pub fn save(self: *CommonNativeMutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try self.inner.save(alloc, text);
    }

    pub fn delete(self: *CommonNativeMutation, alloc: Allocator) !DeleteResult {
        return switch (try self.inner.delete(alloc)) {
            .deleted => .{ .session_deleted = true },
            .missing => .{},
            .deleted_not_durable => .{
                .session_deleted = true,
                .local_cleanup_failed = true,
            },
        };
    }
};

const HostMutation = struct {
    store: js_host_auth.SessionStore = js_host_auth.oauth_session_store,
    revision: [js_host_auth.max_revision_bytes]u8 = undefined,
    revision_len: usize = 0,
    exists: bool = false,

    fn init(store: js_host_auth.SessionStore) HostMutation {
        return .{ .store = store };
    }

    pub fn deinit(self: *HostMutation) void {
        @memset(&self.revision, 0);
        self.* = undefined;
    }

    pub fn load(self: *HostMutation, alloc: Allocator) !?Session {
        var stored = (try self.store.load(alloc)) orelse {
            self.exists = false;
            self.revision_len = 0;
            return null;
        };
        defer stored.deinit(alloc);
        try self.captureStoredRevision(stored.revision);
        return @as(?Session, try parse(alloc, stored.bytes));
    }

    pub fn save(self: *HostMutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        const expected = if (self.exists) self.revision[0..self.revision_len] else null;
        const revision = try self.store.commit(alloc, text, expected);
        defer alloc.free(revision);
        try self.captureStoredRevision(revision);
    }

    pub fn delete(self: *HostMutation, _: Allocator) !DeleteResult {
        const expected = if (self.exists) self.revision[0..self.revision_len] else null;
        return switch (try self.store.remove(expected)) {
            .deleted => .{ .session_deleted = true },
            .missing => .{},
        };
    }

    fn captureRevision(self: *HostMutation, alloc: Allocator) !void {
        var stored = (try self.store.load(alloc)) orelse {
            self.exists = false;
            self.revision_len = 0;
            return;
        };
        defer stored.deinit(alloc);
        try self.captureStoredRevision(stored.revision);
    }

    fn captureStoredRevision(self: *HostMutation, revision: []const u8) !void {
        if (revision.len > self.revision.len) return error.OAuthSessionRevisionTooLarge;
        @memcpy(self.revision[0..revision.len], revision);
        self.revision_len = revision.len;
        self.exists = true;
    }
};

pub fn configuredClientId() ?[]const u8 {
    if (io_mod.getenv(client_id_env)) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
    }
    return if (default_client_id.len == 0) null else default_client_id;
}

pub fn configuredIssuerUrl() ![]const u8 {
    return selectIssuerUrl(io_mod.getenv(e2e_issuer_url_env));
}

pub fn isLoopbackE2EIssuer(url: []const u8) bool {
    return !std.mem.eql(u8, url, issuer) and isLoopbackHttpUrl(url, true);
}

pub fn validateE2EEndpoint(issuer_url: []const u8, endpoint: []const u8) !void {
    if (isLoopbackE2EIssuer(issuer_url) and !isLoopbackHttpUrl(endpoint, false)) {
        return error.InvalidE2EOAuthEndpoint;
    }
}

fn selectIssuerUrl(override: ?[]const u8) ![]const u8 {
    const raw = override orelse return issuer;
    const candidate = std.mem.trimEnd(u8, raw, "/");
    if (!isLoopbackHttpUrl(candidate, true)) return error.InvalidE2EOAuthIssuer;
    return candidate;
}

fn isLoopbackHttpUrl(url: []const u8, require_origin: bool) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null or
        (require_origin and (!uri.path.isEmpty() or uri.query != null or uri.fragment != null)))
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

pub fn load(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return loadFromHost(alloc, js_host_auth.oauth_session_store);
    return loadNative(alloc, .active);
}

pub fn loadStored(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return loadFromHost(alloc, js_host_auth.oauth_session_store);
    return loadNative(alloc, .inspect);
}

fn loadNative(alloc: Allocator, intent: @import("auth_store.zig").LoadIntent) !?Session {
    const bytes = (native_auth_store.load_entry(alloc, .fx_login, intent) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed step=common_store err={s}", .{@errorName(err)});
            return null;
        },
    }) orelse return null;
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed step=parse_common err={s}", .{@errorName(err)});
            return null;
        },
    };
}

fn loadFromHost(alloc: Allocator, store: js_host_auth.SessionStore) !?Session {
    var stored = (try store.load(alloc)) orelse return null;
    defer stored.deinit(alloc);
    return parse(alloc, stored.bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) {
        var mutation = HostMutation.init(js_host_auth.oauth_session_store);
        defer mutation.deinit();
        try mutation.captureRevision(alloc);
        return mutation.save(alloc, session);
    }
    var mutation = try beginExistingMutation() orelse return error.HomeNotSet;
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) {
        return @as(?Mutation, HostMutation.init(js_host_auth.oauth_session_store));
    }
    return .{ .inner = try native_auth_store.begin_entry_mutation(.fx_login) };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidAuthSession;
    const saved_issuer = try requiredString(object, "issuer");
    if (!std.mem.eql(u8, saved_issuer, issuer) and !isLoopbackE2EIssuer(saved_issuer)) {
        return error.InvalidAuthSession;
    }

    const expires_at_ms = try requiredInteger(object, "expires_at_ms");
    const owned_issuer = try alloc.dupe(u8, saved_issuer);
    errdefer alloc.free(owned_issuer);
    const client_id = try dupeRequiredString(alloc, object, "client_id");
    errdefer alloc.free(client_id);
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const scope = try dupeRequiredString(alloc, object, "scope");
    errdefer alloc.free(scope);
    const token_type = try dupeRequiredString(alloc, object, "token_type");
    errdefer alloc.free(token_type);
    const team_slug = try dupeOptionalString(alloc, object, "team_slug");
    errdefer if (team_slug) |value| alloc.free(value);
    const team_id = try dupeOptionalString(alloc, object, "team_id");
    errdefer if (team_id) |value| alloc.free(value);

    return .{
        .issuer = owned_issuer,
        .client_id = client_id,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = scope,
        .token_type = token_type,
        .team_slug = team_slug,
        .team_id = team_id,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"version\":1");
    try writeField(writer, "issuer", session.issuer);
    try writeField(writer, "client_id", session.client_id);
    try writeField(writer, "access_token", session.access_token);
    try writeField(writer, "refresh_token", session.refresh_token);
    try writer.print(",\"expires_at_ms\":{d}", .{session.expires_at_ms});
    try writeField(writer, "scope", session.scope);
    try writeField(writer, "token_type", session.token_type);
    if (session.team_slug) |value| try writeField(writer, "team_slug", value);
    if (session.team_id) |value| try writeField(writer, "team_id", value);
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.writeAll(",");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(":");
    try std.json.Stringify.value(value, .{}, writer);
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return alloc.dupe(u8, try requiredString(object, key));
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidAuthSession;
    return value.string;
}

fn dupeOptionalString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.InvalidAuthSession;
    return try alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .integer) return error.InvalidAuthSession;
    return value.integer;
}

const test_session_json = "{\"version\":1,\"issuer\":\"https://vercel.com\",\"client_id\":\"client\",\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1,\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\",\"team_slug\":\"team-slug\",\"team_id\":\"team-id\"}";

const HostStoreTestState = struct {
    record: ?[]const u8 = test_session_json,
    revision: []const u8 = "7",
    next_revision: []const u8 = "8",
    force_conflict: bool = false,
    commit_count: usize = 0,
    remove_count: usize = 0,
    expected_revision_matched: bool = false,
    committed_format_matched: bool = false,

    fn provider(self: *@This()) js_host_auth.SessionStore {
        return .{
            .context = self,
            .load_fn = HostStoreTestState.load,
            .commit_fn = HostStoreTestState.commit,
            .remove_fn = HostStoreTestState.remove,
        };
    }

    fn load(raw: ?*anyopaque, alloc: Allocator) !?js_host_auth.StoredSession {
        const self = state(raw);
        const record = self.record orelse return null;
        const bytes = try alloc.dupe(u8, record);
        errdefer secret.zeroAndFree(alloc, bytes);
        return .{
            .bytes = bytes,
            .revision = try alloc.dupe(u8, self.revision),
        };
    }

    fn commit(
        raw: ?*anyopaque,
        alloc: Allocator,
        bytes: []const u8,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        const self = state(raw);
        self.commit_count += 1;
        self.expected_revision_matched = expected_revision != null and
            std.mem.eql(u8, expected_revision.?, self.revision);
        self.committed_format_matched = std.mem.eql(u8, bytes, test_session_json ++ "\n");
        if (self.force_conflict) return error.OAuthSessionRevisionConflict;
        self.revision = self.next_revision;
        return alloc.dupe(u8, self.revision);
    }

    fn remove(raw: ?*anyopaque, expected_revision: ?[]const u8) !js_host_auth.RemoveOutcome {
        const self = state(raw);
        self.remove_count += 1;
        self.expected_revision_matched = expected_revision != null and
            std.mem.eql(u8, expected_revision.?, self.revision);
        if (self.force_conflict) return error.OAuthSessionRevisionConflict;
        if (self.record == null) return .missing;
        self.record = null;
        return .deleted;
    }

    fn state(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }
};

fn check_parse_allocation_failures(alloc: Allocator) !void {
    var session = try parse(alloc, test_session_json);
    defer session.deinit(alloc);
}

test "oauth session stringifies and parses" {
    var session = Session{
        .issuer = try std.testing.allocator.dupe(u8, issuer),
        .client_id = try std.testing.allocator.dupe(u8, "client"),
        .access_token = try std.testing.allocator.dupe(u8, "access"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh"),
        .expires_at_ms = 1234,
        .scope = try std.testing.allocator.dupe(u8, "openid offline_access"),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
        .team_slug = try std.testing.allocator.dupe(u8, "vercel-labs"),
        .team_id = try std.testing.allocator.dupe(u8, "team_123"),
    };
    defer session.deinit(std.testing.allocator);

    const text = try stringify(std.testing.allocator, session);
    defer secret.zeroAndFree(std.testing.allocator, text);
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(issuer, parsed.issuer);
    try std.testing.expectEqualStrings("client", parsed.client_id);
    try std.testing.expectEqualStrings("access", parsed.access_token);
    try std.testing.expectEqualStrings("vercel-labs", parsed.team_slug.?);
    try std.testing.expectEqualStrings("team_123", parsed.team_id.?);
}

test "JS host OAuth session load commit and remove preserve the native format and revision" {
    var state: HostStoreTestState = .{};
    var loaded = (try loadFromHost(std.testing.allocator, state.provider())).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("access", loaded.access_token);

    var mutation = HostMutation.init(state.provider());
    defer mutation.deinit();
    var current = (try mutation.load(std.testing.allocator)).?;
    defer current.deinit(std.testing.allocator);
    try mutation.save(std.testing.allocator, current);
    try std.testing.expectEqual(@as(usize, 1), state.commit_count);
    try std.testing.expect(state.expected_revision_matched);
    try std.testing.expect(state.committed_format_matched);

    const deleted = try mutation.delete(std.testing.allocator);
    try std.testing.expect(deleted.session_deleted);
    try std.testing.expect(!deleted.local_cleanup_failed);
    try std.testing.expectEqual(@as(usize, 1), state.remove_count);
    try std.testing.expect(state.expected_revision_matched);
}

test "JS host OAuth session revision conflict does not take session ownership" {
    var state = HostStoreTestState{ .force_conflict = true };
    var mutation = HostMutation.init(state.provider());
    defer mutation.deinit();
    var current = (try mutation.load(std.testing.allocator)).?;
    defer current.deinit(std.testing.allocator);
    const access_token = current.access_token.ptr;

    try std.testing.expectError(
        error.OAuthSessionRevisionConflict,
        mutation.save(std.testing.allocator, current),
    );
    try std.testing.expectEqual(access_token, current.access_token.ptr);
    try std.testing.expectEqualStrings("access", current.access_token);
    try std.testing.expectEqual(@as(usize, 1), state.commit_count);
}

test "oauth session parse cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_parse_allocation_failures, .{});
}

test "oauth session parse rejects non-object JSON" {
    try std.testing.expectError(error.InvalidAuthSession, parse(std.testing.allocator, "[]"));
}

test "oauth session rejects invalid saved issuers" {
    try std.testing.expectError(
        error.InvalidAuthSession,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"issuer\":\"https://example.com\",\"client_id\":\"client\",\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1234,\"scope\":\"openid\",\"token_type\":\"Bearer\"}",
        ),
    );
}

test "oauth session treats near-expiry as expired" {
    var session = Session{
        .issuer = try std.testing.allocator.dupe(u8, issuer),
        .client_id = try std.testing.allocator.dupe(u8, "client"),
        .access_token = try std.testing.allocator.dupe(u8, "access"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh"),
        .expires_at_ms = 100_000,
        .scope = try std.testing.allocator.dupe(u8, "openid"),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
    };
    defer session.deinit(std.testing.allocator);
    try std.testing.expect(session.expired(50_000));
    try std.testing.expect(!session.expired(1));
    try std.testing.expect(session.expired(std.math.maxInt(i64)));
}

test "oauth E2E issuer override accepts loopback HTTP only" {
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123",
        try selectIssuerUrl("http://127.0.0.1:43123"),
    );
    try std.testing.expectEqualStrings(
        "http://localhost:43123",
        try selectIssuerUrl("http://localhost:43123"),
    );
    try std.testing.expectError(
        error.InvalidE2EOAuthIssuer,
        selectIssuerUrl("https://example.com"),
    );
    try std.testing.expectError(
        error.InvalidE2EOAuthIssuer,
        selectIssuerUrl("http://127.0.0.1:43123@evil.example"),
    );
    try validateE2EEndpoint(
        "http://127.0.0.1:43123",
        "http://localhost:43123/oauth/token",
    );
    try std.testing.expectError(
        error.InvalidE2EOAuthEndpoint,
        validateE2EEndpoint("http://127.0.0.1:43123", "https://example.com/oauth/token"),
    );
}
