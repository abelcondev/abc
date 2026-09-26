const provider_set = @import("../core/gateway/provider_set.zig");
const gateway = @import("gateway.zig");

pub const native = provider_set.Set{
    .configured_fn = @import("../gateway/chat_completions.zig").bundle,
    .gateway = gateway.provider_bundle,
};
