const provider_set = @import("../core/gateway/provider_set.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const gateway = @import("gateway.zig");
const chat_completions = @import("../gateway/chat_completions.zig");
const web_search_api = @import("web_search_api.zig");

const gateway_bundle = blk: {
    var bundle = gateway.provider_bundle;
    bundle.fx_search = web_search_api.withFallback(gateway.default_web_search_provider);
    break :blk bundle;
};

/// Configured connections get the web_search tool whenever a search API is set.
fn configuredBundle(definition: *const configured_provider.Definition) provider_set.Bundle {
    var bundle = chat_completions.bundle(definition);
    bundle.capabilities.fx_search = web_search_api.available();
    return bundle;
}

pub const native = provider_set.Set{
    .configured_fn = configuredBundle,
    .gateway = gateway_bundle,
};
