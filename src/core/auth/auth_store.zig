const std = @import("std");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const StoredSource = enum {
    stored_key,
    fx_login,
    chatgpt_subscription,
    grok_subscription,
};

pub const StoreState = enum {
    empty,
    legacy,
    current,
    malformed_current,
};

pub const LoadIntent = enum {
    inspect,
    active,
};

pub const LoadDecision = enum {
    missing,
    use_legacy,
    migrate_legacy,
    use_current,
    reject_current,
};

pub fn decide_load(state: StoreState, intent: LoadIntent) LoadDecision {
    return switch (state) {
        .empty => .missing,
        .legacy => if (intent == .inspect) .use_legacy else .migrate_legacy,
        .current => .use_current,
        .malformed_current => .reject_current,
    };
}

const slot_count = std.meta.fields(StoredSource).len;

pub const Document = struct {
    slots: [slot_count]?[]u8 = [_]?[]u8{null} ** slot_count,

    pub fn deinit(self: *Document, alloc: Allocator) void {
        for (&self.slots) |*slot| {
            if (slot.*) |value| secret.zeroAndFree(alloc, value);
            slot.* = null;
        }
        self.* = .{};
    }

    pub fn get(self: *const Document, source: StoredSource) ?[]const u8 {
        return self.slots[@intFromEnum(source)];
    }

    pub fn replaced(
        self: *const Document,
        alloc: Allocator,
        source: StoredSource,
        value: []const u8,
    ) !Document {
        if (source == .stored_key) {
            try validate_entry(alloc, source, value);
            return self.transformed(alloc, source, value);
        }
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, value, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAuthDocument,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidAuthDocument;
        const canonical = try stringify_value(alloc, parsed.value);
        defer secret.zeroAndFree(alloc, canonical);
        return self.transformed(alloc, source, canonical);
    }

    pub fn removed(
        self: *const Document,
        alloc: Allocator,
        source: StoredSource,
    ) !Document {
        return self.transformed(alloc, source, null);
    }

    pub fn eql(self: *const Document, other: Document) bool {
        for (std.meta.tags(StoredSource)) |source| {
            const left = self.get(source);
            const right = other.get(source);
            if (left == null or right == null) {
                if (left != null or right != null) return false;
                continue;
            }
            if (!std.mem.eql(u8, left.?, right.?)) return false;
        }
        return true;
    }

    pub fn parse(alloc: Allocator, bytes: []const u8) !Document {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAuthDocument,
        };
        defer parsed.deinit();
        if (parsed.value != .object or parsed.value.object.count() != 2) {
            return error.InvalidAuthDocument;
        }
        const version = parsed.value.object.get("version") orelse return error.InvalidAuthDocument;
        if (version != .integer or version.integer != 2) return error.InvalidAuthDocument;
        const credentials = parsed.value.object.get("credentials") orelse return error.InvalidAuthDocument;
        if (credentials != .object) return error.InvalidAuthDocument;

        var document: Document = .{};
        errdefer document.deinit(alloc);
        var iterator = credentials.object.iterator();
        while (iterator.next()) |item| {
            const source = std.meta.stringToEnum(StoredSource, item.key_ptr.*) orelse
                return error.InvalidAuthDocument;
            if (item.value_ptr.* != .object or item.value_ptr.object.count() != 1) {
                return error.InvalidAuthDocument;
            }
            const value = if (source == .stored_key) value: {
                const secret_value = item.value_ptr.object.get("secret") orelse
                    return error.InvalidAuthDocument;
                if (secret_value != .string or secret_value.string.len == 0) {
                    return error.InvalidAuthDocument;
                }
                break :value try alloc.dupe(u8, secret_value.string);
            } else value: {
                const session_value = item.value_ptr.object.get("session") orelse
                    return error.InvalidAuthDocument;
                if (session_value != .object) return error.InvalidAuthDocument;
                break :value try stringify_value(alloc, session_value);
            };
            document.slots[@intFromEnum(source)] = value;
        }
        return document;
    }

    pub fn stringify(self: *const Document, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try out.writer.writeAll("{\"version\":2,\"credentials\":{");
        var wrote_entry = false;
        for (std.meta.tags(StoredSource)) |source| {
            const value = self.get(source) orelse continue;
            try validate_entry(alloc, source, value);
            if (wrote_entry) try out.writer.writeByte(',');
            wrote_entry = true;
            try std.json.Stringify.value(@tagName(source), .{}, &out.writer);
            if (source == .stored_key) {
                try out.writer.writeAll(":{\"secret\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
                try out.writer.writeByte('}');
            } else {
                try out.writer.writeAll(":{\"session\":");
                try out.writer.writeAll(value);
                try out.writer.writeByte('}');
            }
        }
        try out.writer.writeAll("}}\n");
        return out.toOwnedSlice();
    }

    fn transformed(
        self: *const Document,
        alloc: Allocator,
        changed_source: StoredSource,
        replacement: ?[]const u8,
    ) !Document {
        var next: Document = .{};
        errdefer next.deinit(alloc);

        for (std.meta.tags(StoredSource)) |source| {
            const value = if (source == changed_source) replacement else self.get(source);
            if (value) |bytes| next.slots[@intFromEnum(source)] = try alloc.dupe(u8, bytes);
        }
        return next;
    }
};

fn validate_entry(alloc: Allocator, source: StoredSource, value: []const u8) !void {
    if (value.len == 0) return error.InvalidAuthDocument;
    if (source == .stored_key) return;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAuthDocument,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthDocument;
}

fn stringify_value(alloc: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn check_parse_allocation_failures(alloc: Allocator) !void {
    var document = try Document.parse(
        alloc,
        "{\"version\":2,\"credentials\":{\"stored_key\":{\"secret\":\"key\"},\"fx_login\":{\"session\":{\"version\":1}}}}",
    );
    defer document.deinit(alloc);
}

test "replacing one stored credential preserves the original and unrelated sources" {
    const alloc = std.testing.allocator;
    const empty: Document = .{};

    var gateway = try empty.replaced(alloc, .stored_key, "gateway-secret");
    defer gateway.deinit(alloc);
    var with_codex = try gateway.replaced(alloc, .chatgpt_subscription, "{\"version\":1}");
    defer with_codex.deinit(alloc);
    var replaced_codex = try with_codex.replaced(alloc, .chatgpt_subscription, "{\"version\":2}");
    defer replaced_codex.deinit(alloc);

    try std.testing.expectEqualStrings("gateway-secret", gateway.get(.stored_key).?);
    try std.testing.expect(gateway.get(.chatgpt_subscription) == null);
    try std.testing.expectEqualStrings("gateway-secret", with_codex.get(.stored_key).?);
    try std.testing.expectEqualStrings("{\"version\":1}", with_codex.get(.chatgpt_subscription).?);
    try std.testing.expectEqualStrings("gateway-secret", replaced_codex.get(.stored_key).?);
    try std.testing.expectEqualStrings("{\"version\":2}", replaced_codex.get(.chatgpt_subscription).?);
}

test "removing one stored credential is idempotent and preserves unrelated sources" {
    const alloc = std.testing.allocator;
    const empty: Document = .{};

    var gateway = try empty.replaced(alloc, .fx_login, "{\"version\":1}");
    defer gateway.deinit(alloc);
    var with_grok = try gateway.replaced(alloc, .grok_subscription, "{\"version\":1}");
    defer with_grok.deinit(alloc);
    var removed = try with_grok.removed(alloc, .grok_subscription);
    defer removed.deinit(alloc);
    var removed_again = try removed.removed(alloc, .grok_subscription);
    defer removed_again.deinit(alloc);

    try std.testing.expectEqualStrings("{\"version\":1}", removed.get(.fx_login).?);
    try std.testing.expect(removed.get(.grok_subscription) == null);
    try std.testing.expect(removed.eql(removed_again));
}

test "version two auth document round trips every stored source" {
    const alloc = std.testing.allocator;
    var document: Document = .{};
    defer document.deinit(alloc);

    const fixtures = [_]struct { source: StoredSource, value: []const u8 }{
        .{ .source = .stored_key, .value = "gateway-secret" },
        .{ .source = .fx_login, .value = "{\"version\":1,\"access_token\":\"vercel\"}" },
        .{ .source = .chatgpt_subscription, .value = "{\"version\":1,\"access_token\":\"codex\"}" },
        .{ .source = .grok_subscription, .value = "{\"version\":1,\"access_token\":\"grok\"}" },
    };
    for (fixtures) |fixture| {
        const next = try document.replaced(alloc, fixture.source, fixture.value);
        document.deinit(alloc);
        document = next;
    }

    const encoded = try document.stringify(alloc);
    defer secret.zeroAndFree(alloc, encoded);
    var decoded = try Document.parse(alloc, encoded);
    defer decoded.deinit(alloc);

    try std.testing.expect(document.eql(decoded));
}

test "stored session replacement canonicalizes insignificant JSON whitespace" {
    const alloc = std.testing.allocator;
    const empty: Document = .{};
    var document = try empty.replaced(
        alloc,
        .fx_login,
        "{\"version\":1,\"access_token\":\"token\"}\n",
    );
    defer document.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"access_token\":\"token\"}",
        document.get(.fx_login).?,
    );
}

test "auth document rejects malformed or unknown version two state" {
    const alloc = std.testing.allocator;
    const invalid = [_][]const u8{
        "{}",
        "{\"version\":1,\"credentials\":{}}",
        "{\"version\":2,\"credentials\":[]}",
        "{\"version\":2,\"credentials\":{\"stored_key\":{\"secret\":\"\"}}}",
        "{\"version\":2,\"credentials\":{\"fx_login\":\"not-an-object\"}}",
        "{\"version\":2,\"credentials\":{\"unknown\":{}}}",
    };
    for (invalid) |bytes| {
        try std.testing.expectError(error.InvalidAuthDocument, Document.parse(alloc, bytes));
    }
}

test "auth document parse cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_parse_allocation_failures,
        .{},
    );
}

test "load decision keeps inspection pure and migrates only active legacy state" {
    const cases = [_]struct {
        state: StoreState,
        intent: LoadIntent,
        expected: LoadDecision,
    }{
        .{ .state = .empty, .intent = .inspect, .expected = .missing },
        .{ .state = .empty, .intent = .active, .expected = .missing },
        .{ .state = .legacy, .intent = .inspect, .expected = .use_legacy },
        .{ .state = .legacy, .intent = .active, .expected = .migrate_legacy },
        .{ .state = .current, .intent = .inspect, .expected = .use_current },
        .{ .state = .current, .intent = .active, .expected = .use_current },
        .{ .state = .malformed_current, .intent = .inspect, .expected = .reject_current },
        .{ .state = .malformed_current, .intent = .active, .expected = .reject_current },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, decide_load(case.state, case.intent));
    }
}

test "auth document parser handles arbitrary bytes" {
    try std.testing.fuzz({}, fuzz_auth_document, .{
        .corpus = &.{
            "",
            "{}",
            "{\"version\":2,\"credentials\":{}}",
            "{\"version\":2,\"credentials\":{\"stored_key\":{\"secret\":\"key\"}}}",
        },
    });
}

fn fuzz_auth_document(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var document = Document.parse(std.testing.allocator, buffer[0..len]) catch return;
    defer document.deinit(std.testing.allocator);

    const encoded = try document.stringify(std.testing.allocator);
    defer secret.zeroAndFree(std.testing.allocator, encoded);
    var reparsed = try Document.parse(std.testing.allocator, encoded);
    defer reparsed.deinit(std.testing.allocator);
    try std.testing.expect(document.eql(reparsed));
}
