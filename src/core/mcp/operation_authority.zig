const std = @import("std");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const access_policy = @import("access_policy.zig");
const Allocator = std.mem.Allocator;

/// Owns one current live-authority snapshot for an MCP operation. It is
/// resolved before catalog or connection locks are acquired and may be
/// refreshed after preliminary effects before returning a result.
pub const Guard = struct {
    alloc: Allocator,
    access: tool_mcp_runtime.Access,
    runtime_generation: u64,
    live_view: ?tool_mcp_runtime.ResolvedLiveView = null,

    pub fn init(
        alloc: Allocator,
        access: tool_mcp_runtime.Access,
        runtime_generation: u64,
    ) !Guard {
        var guard = Guard{
            .alloc = alloc,
            .access = access,
            .runtime_generation = runtime_generation,
        };
        errdefer guard.deinit();
        try guard.refresh();
        return guard;
    }

    pub fn deinit(self: *Guard) void {
        if (self.live_view) |*view| view.deinit(self.alloc);
        self.live_view = null;
    }

    pub fn refresh(self: *Guard) !void {
        self.deinit();
        self.live_view = try resolveLiveAuthority(
            self.alloc,
            self.access,
            self.runtime_generation,
        );
    }

    pub fn authorize(self: *const Guard, target: access_policy.Target) !void {
        switch (self.access) {
            .unrestricted => return,
            .disabled => return error.McpAccessDenied,
            .scoped => |scope| {
                const live = self.live_view orelse return error.McpAuthorityChanged;
                if (access_policy.authorize(scope.captured.*, live.view, target) != .allow) {
                    return error.McpAuthorityChanged;
                }
            },
        }
    }

    pub fn refreshAndAuthorize(
        self: *Guard,
        target: access_policy.Target,
    ) !void {
        try self.refresh();
        try self.authorize(target);
    }

    pub fn allows(self: *const Guard, target: access_policy.Target) bool {
        self.authorize(target) catch return false;
        return true;
    }
};

pub fn authorizeLiveAccess(
    alloc: Allocator,
    access: tool_mcp_runtime.Access,
    runtime_generation: u64,
    target: access_policy.Target,
) !?tool_mcp_runtime.ResolvedLiveView {
    var live = try resolveLiveAuthority(alloc, access, runtime_generation);
    errdefer if (live) |*view| view.deinit(alloc);
    switch (access) {
        .unrestricted => {},
        .disabled => unreachable,
        .scoped => |scope| {
            if (access_policy.authorize(scope.captured.*, live.?.view, target) != .allow) {
                return error.McpAuthorityChanged;
            }
        },
    }
    return live;
}

pub fn resolveLiveAuthority(
    alloc: Allocator,
    access: tool_mcp_runtime.Access,
    runtime_generation: u64,
) !?tool_mcp_runtime.ResolvedLiveView {
    return switch (access) {
        .unrestricted => null,
        .disabled => error.McpAccessDenied,
        .scoped => |scope| scoped: {
            if (scope.admission_authority_generation == 0 or
                scope.captured.runtime_generation != runtime_generation)
            {
                return error.McpAuthorityChanged;
            }
            var live = try scope.live.resolve(alloc);
            errdefer live.deinit(alloc);
            if (live.authority_generation == 0 or
                live.authority_generation != scope.admission_authority_generation)
            {
                return error.McpAuthorityChanged;
            }
            if (scope.action_authority_generation != 0 and
                (live.action_authority_generation == 0 or
                    live.action_authority_generation != scope.action_authority_generation))
            {
                return error.McpAuthorityChanged;
            }
            break :scoped live;
        },
    };
}
