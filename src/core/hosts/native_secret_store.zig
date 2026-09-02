const std = @import("std");
const builtin = @import("builtin");
const auth_store = @import("../auth/auth_store.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("host.zig");
const keychain = @import("native_keychain.zig");
const native_auth_store = @import("native_auth_store.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

/// Names the backend that answers on this platform so operators can tell where a
/// stored key lives without knowing how the backend is selected.
const backend_label = if (builtin.os.tag == .macos) "macOS Keychain" else "profile file";

const LoadError = host.SecretStoreLoadError;
const StoreError = host.SecretStoreWriteError;

pub const provider: host.SecretStore = .{
    .backend_label = backend_label,
    .is_disabled_fn = isDisabledCallback,
    .presence_fn = presenceCallback,
    .load_fn = loadCallback,
    .load_stored_fn = loadStoredCallback,
    .store_fn = storeCallback,
    .store_interactive_fn = storeInteractiveCallback,
};

/// The disable switch is named for the macOS backend, so its reader stays there.
fn isDisabled() bool {
    return keychain.isDisabled();
}

/// Returns the stored key, or null when no key is stored. An error means the store
/// could not be read, which callers must keep distinct from absence.
fn load(alloc: Allocator) LoadError!?[]u8 {
    return loadWithIntent(alloc, .active);
}

fn loadStored(alloc: Allocator) LoadError!?[]u8 {
    return loadWithIntent(alloc, .inspect);
}

fn loadWithIntent(
    alloc: Allocator,
    intent: auth_store.LoadIntent,
) LoadError!?[]u8 {
    return native_auth_store.load_entry(alloc, .stored_key, intent) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AuthDocumentInsecure => error.StoredKeyInsecure,
        else => error.StoredKeyUnreadable,
    };
}

fn store(alloc: Allocator, value: []const u8) StoreError!void {
    if (value.len == 0) return error.StoredKeyWriteFailed;
    var mutation = native_auth_store.begin_entry_mutation(.stored_key) catch |err| {
        return writeFailed("begin_auth_store", err);
    };
    defer mutation.deinit();
    mutation.save(alloc, value) catch |err| return writeFailed("commit_auth_store", err);
}

/// Let the platform credential store own terminal input when it supports a
/// secure prompt, keeping plaintext out of the fx process.
fn storeInteractive() StoreError!bool {
    if (comptime builtin.os.tag == .macos) {
        keychain.storeInteractive() catch |err| return writeFailed("keychain_interactive", err);
        const alloc = std.heap.c_allocator;
        const value = (keychain.load(alloc) catch |err| return writeFailed("keychain_interactive_readback", err)) orelse
            return writeFailed("keychain_interactive_readback", error.KeychainItemNotFound);
        defer secret.zeroAndFree(alloc, value);
        var mutation = native_auth_store.begin_entry_mutation(.stored_key) catch |err| {
            return writeFailed("keychain_interactive_begin", err);
        };
        defer mutation.deinit();
        mutation.save(alloc, value) catch |err| return writeFailed("keychain_interactive_commit", err);
        return true;
    }
    return false;
}

fn isDisabledCallback(_: ?*anyopaque) bool {
    return isDisabled();
}

fn presenceCallback(_: ?*anyopaque) host.SecretStorePresence {
    if (isDisabled()) return .missing;
    return native_auth_store.entry_presence(.stored_key);
}

fn loadCallback(_: ?*anyopaque, alloc: Allocator) LoadError!?[]u8 {
    return load(alloc);
}

fn loadStoredCallback(_: ?*anyopaque, alloc: Allocator) LoadError!?[]u8 {
    return loadStored(alloc);
}

fn storeCallback(
    _: ?*anyopaque,
    alloc: Allocator,
    value: []const u8,
) StoreError!void {
    return store(alloc, value);
}

fn storeInteractiveCallback(_: ?*anyopaque) StoreError!bool {
    return storeInteractive();
}

fn writeFailed(step: []const u8, err: anyerror) StoreError {
    debug_trace.logf("stored_key", "store failed step={s} err={s}", .{ step, @errorName(err) });
    return error.StoredKeyWriteFailed;
}

test "stored key backend label names the platform store" {
    if (comptime builtin.os.tag == .macos) {
        try std.testing.expectEqualStrings("macOS Keychain", backend_label);
    } else {
        try std.testing.expectEqualStrings("profile file", backend_label);
    }
    try std.testing.expectEqualStrings(backend_label, provider.backend_label);
}

test "stored key rejects an empty value" {
    try std.testing.expectError(error.StoredKeyWriteFailed, store(std.testing.allocator, ""));
}
