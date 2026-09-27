//! API keys saved with `fx login <provider>` for configured connections.
//!
//! macOS keeps each key in the login Keychain under the service
//! `FX_PROVIDER_KEY_<id>`; other platforms (or a disabled Keychain) use an
//! owner-only file at `~/.fx/provider-keys/<id>`. An exported environment
//! variable always takes precedence over a saved key. Keys saved while the
//! fork was named abc (service `ABC_PROVIDER_KEY_<id>`) move to the current
//! service the first time they are read.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const keychain = @import("../hosts/native_keychain.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");
const configured_provider = @import("../config/configured_provider.zig");

const Allocator = std.mem.Allocator;

const keys_dir_name = "provider-keys";
const max_key_bytes: usize = 16 * 1024;

pub const Error = Allocator.Error || error{
    InvalidProviderKey,
    ProviderKeyStorageUnavailable,
    ProviderKeyReadFailed,
    ProviderKeyWriteFailed,
};

/// Where `store` puts keys right now.
pub fn backendLabel() []const u8 {
    return if (useKeychain()) "macOS Keychain" else "profile file ~/.fx/provider-keys";
}

fn useKeychain() bool {
    return builtin.os.tag == .macos and keychain.isAvailable() and !keychain.isDisabled();
}

fn serviceName(buffer: []u8, id: []const u8) Error![]const u8 {
    configured_provider.validate_id(id) catch return error.InvalidProviderKey;
    return std.fmt.bufPrint(buffer, "FX_PROVIDER_KEY_{s}", .{id}) catch error.InvalidProviderKey;
}

fn legacyServiceName(buffer: []u8, id: []const u8) Error![]const u8 {
    configured_provider.validate_id(id) catch return error.InvalidProviderKey;
    return std.fmt.bufPrint(buffer, "ABC_PROVIDER_KEY_{s}", .{id}) catch error.InvalidProviderKey;
}

/// Reads a key saved under the abc-era service and moves it to `service`.
fn migrateLegacyKeychain(alloc: Allocator, id: []const u8, service: []const u8) Error!?[]u8 {
    var buffer: [128]u8 = undefined;
    const legacy = try legacyServiceName(&buffer, id);
    const key = (keychain.loadService(alloc, legacy) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    }) orelse return null;
    keychain.storeService(service, key) catch return key;
    _ = keychain.deleteService(alloc, legacy) catch false;
    return key;
}

/// A key must be one line of visible ASCII, like an HTTP bearer token.
pub fn validate(value: []const u8) Error!void {
    if (value.len == 0 or value.len > max_key_bytes) return error.InvalidProviderKey;
    for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidProviderKey;
}

/// Whether a connection can authenticate now: no auth needed, its key
/// variable is exported, or a key was saved for it.
pub fn available(alloc: Allocator, definition: *const configured_provider.Definition) bool {
    const env = switch (definition.auth) {
        .none => return true,
        .bearer => |name| name,
    };
    if (io_mod.getenv(env)) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len != 0) return true;
    }
    const saved = load(alloc, definition.id) catch return false;
    if (saved) |key| {
        secret.zeroAndFree(alloc, key);
        return true;
    }
    return false;
}

/// Returns an owned key or null. Callers zero and free it with `alloc`.
pub fn load(alloc: Allocator, id: []const u8) Error!?[]u8 {
    // Unit tests never touch the user's Keychain or profile.
    if (builtin.is_test) return null;
    var buffer: [128]u8 = undefined;
    const service = try serviceName(&buffer, id);
    if (useKeychain()) {
        const key = keychain.loadService(alloc, service) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProviderKeyReadFailed,
        };
        return key orelse try migrateLegacyKeychain(alloc, id, service);
    }
    return loadFile(alloc, id);
}

pub fn store(alloc: Allocator, id: []const u8, value: []const u8) Error!void {
    try validate(value);
    var buffer: [128]u8 = undefined;
    const service = try serviceName(&buffer, id);
    if (useKeychain()) {
        keychain.storeService(service, value) catch return error.ProviderKeyWriteFailed;
        return;
    }
    return storeFile(alloc, id, value);
}

/// Returns whether a saved key existed.
pub fn delete(alloc: Allocator, id: []const u8) Error!bool {
    var buffer: [128]u8 = undefined;
    const service = try serviceName(&buffer, id);
    if (useKeychain()) {
        return keychain.deleteService(alloc, service) catch error.ProviderKeyWriteFailed;
    }
    var dir = openKeysDir(false) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.ProviderKeyStorageUnavailable,
    };
    defer dir.close(io_mod.getIo());
    dir.deleteFile(io_mod.getIo(), id) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.ProviderKeyWriteFailed,
    };
    return true;
}

fn openKeysDir(create: bool) !std.Io.Dir {
    const home = io_mod.getenv("HOME") orelse return error.ProviderKeyStorageUnavailable;
    var home_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{});
    defer home_dir.close(io_mod.getIo());
    if (create) {
        var root = try io_mod.openOrCreateVerifiedPrivateDirFromDir(home_dir, profile_paths.root_dir_name);
        defer root.close();
        const keys = try io_mod.openOrCreateVerifiedPrivateDir(&root, keys_dir_name);
        return keys.dir;
    }
    var root = try home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{ .follow_symlinks = false });
    defer root.close(io_mod.getIo());
    return root.openDir(io_mod.getIo(), keys_dir_name, .{ .follow_symlinks = false });
}

fn loadFile(alloc: Allocator, id: []const u8) Error!?[]u8 {
    var dir = openKeysDir(false) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.ProviderKeyStorageUnavailable,
    };
    defer dir.close(io_mod.getIo());
    const bytes = dir.readFileAlloc(io_mod.getIo(), id, alloc, .limited(max_key_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProviderKeyReadFailed,
    };
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) {
        secret.zeroAndFree(alloc, bytes);
        return null;
    }
    const key = try alloc.dupe(u8, trimmed);
    secret.zeroAndFree(alloc, bytes);
    return key;
}

fn storeFile(alloc: Allocator, id: []const u8, value: []const u8) Error!void {
    _ = alloc;
    var dir = openKeysDir(true) catch return error.ProviderKeyStorageUnavailable;
    defer dir.close(io_mod.getIo());
    var file = dir.createFile(io_mod.getIo(), id, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch return error.ProviderKeyWriteFailed;
    defer file.close(io_mod.getIo());
    file.writeStreamingAll(io_mod.getIo(), value) catch return error.ProviderKeyWriteFailed;
}

test "provider keys accept bearer-shaped values only" {
    try validate("sk-abc123");
    try std.testing.expectError(error.InvalidProviderKey, validate(""));
    try std.testing.expectError(error.InvalidProviderKey, validate("sk abc"));
    try std.testing.expectError(error.InvalidProviderKey, validate("sk-\n"));
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("FX_PROVIDER_KEY_deepseek", try serviceName(&buffer, "deepseek"));
    try std.testing.expectError(error.InvalidProviderKey, serviceName(&buffer, "../etc"));
}
