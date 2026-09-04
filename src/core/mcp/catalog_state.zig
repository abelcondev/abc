const std = @import("std");
const feature_cache = @import("feature_cache.zig");
const resources_feature = @import("features/resources.zig");
const prompts_feature = @import("features/prompts.zig");
const mcp_contract = @import("mcp_contract.zig");
const Allocator = std.mem.Allocator;
const freeOwnedStrings = mcp_contract.freeOwnedStrings;

pub const McpTool = struct {
    original_name: []const u8,
    prefixed_name: []u8,
    title: ?[]u8 = null,
    description: []u8,
    input_schema_json: []u8,
    output_schema_json: ?[]u8 = null,
    icons_json: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,
    tags: []const []u8,
};

pub const ToolCatalogSnapshot = struct {
    tools: std.ArrayList(McpTool) = .empty,
    metadata: ?feature_cache.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = true,

    pub fn deinit(self: *ToolCatalogSnapshot, alloc: Allocator) void {
        freeTools(alloc, self.tools.items);
        self.tools.deinit(alloc);
        self.* = .{};
    }
};

pub const ResourceCatalogSnapshot = struct {
    catalog: ?resources_feature.ResourceCatalog = null,
    metadata: ?feature_cache.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    pub fn deinit(self: *ResourceCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

pub const ResourceTemplateCatalogSnapshot = struct {
    catalog: ?resources_feature.TemplateCatalog = null,
    metadata: ?feature_cache.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    pub fn deinit(self: *ResourceTemplateCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

pub const PromptCatalogSnapshot = struct {
    catalog: ?prompts_feature.Catalog = null,
    metadata: ?feature_cache.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    pub fn deinit(self: *PromptCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

pub const ResourceReadCacheEntry = struct {
    uri: []u8,
    result: resources_feature.ReadResult,
    metadata: feature_cache.SnapshotMetadata,
    auth_generation: u64,

    pub fn deinit(self: *ResourceReadCacheEntry, alloc: Allocator) void {
        alloc.free(self.uri);
        self.result.deinit(alloc);
        self.* = undefined;
    }
};

pub const ServerCapabilities = struct {
    resources: bool = false,
    resources_list_changed: bool = false,
    resources_subscribe: bool = false,
    prompts: bool = false,
    prompts_list_changed: bool = false,
    completion: bool = false,

    pub fn exposesFeatures(self: ServerCapabilities) bool {
        return self.resources or self.prompts or self.completion;
    }
};

pub fn freeTools(alloc: Allocator, tools: []const McpTool) void {
    for (tools) |tool| {
        alloc.free(tool.original_name);
        alloc.free(tool.prefixed_name);
        if (tool.title) |value| alloc.free(value);
        alloc.free(tool.description);
        alloc.free(tool.input_schema_json);
        if (tool.output_schema_json) |value| alloc.free(value);
        if (tool.icons_json) |value| alloc.free(value);
        if (tool.annotations_json) |value| alloc.free(value);
        if (tool.metadata_json) |value| alloc.free(value);
        freeOwnedStrings(alloc, tool.tags);
    }
}
