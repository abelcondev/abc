//! Built-in connection definitions for common OpenAI-compatible providers.
//!
//! Presets make `FX_PROVIDER=<id>` work with only the provider's API key in the
//! environment. A `providers.<id>` entry in settings.json replaces the preset
//! of the same id entirely. Endpoints and model ids follow each provider's
//! public documentation and may drift; override them in settings when needed.

const std = @import("std");
const configured_provider = @import("configured_provider.zig");
const types = @import("../shared/types.zig");

const Definition = configured_provider.Definition;
const ModelMetadata = configured_provider.ModelMetadata;
const ReasoningEffort = types.ReasoningEffort;

const on_off = [_]ReasoningEffort{ ReasoningEffort.literal("none"), ReasoningEffort.literal("high") };
const low_medium_high = [_]ReasoningEffort{ ReasoningEffort.literal("low"), ReasoningEffort.literal("medium"), ReasoningEffort.literal("high") };

fn preset(
    comptime id: []const u8,
    comptime base_url: []const u8,
    comptime env: ?[]const u8,
    comptime options: struct {
        reasoning_format: configured_provider.ReasoningFormat = .reasoning_effort,
        tool_choice_mode: configured_provider.ToolChoiceMode = .send,
        default_model: ?[]const u8 = null,
        models: []const ModelMetadata = &.{},
    },
) Definition {
    return .{
        .id = id,
        .protocol = .@"openai-chat-completions",
        .base_url = base_url,
        .auth = if (env) |name| .{ .bearer = name } else .none,
        .tool_choice_mode = options.tool_choice_mode,
        .reasoning_format = options.reasoning_format,
        .default_model = options.default_model,
        .model_metadata = options.models,
    };
}

pub const definitions = [_]Definition{
    preset("deepseek", "https://api.deepseek.com/v1", "DEEPSEEK_API_KEY", .{
        .reasoning_format = .thinking,
        .default_model = "deepseek-chat",
        .models = &.{
            .{ .id = "deepseek-chat", .context_window = 128_000, .max_output_tokens = 8_192, .supports_tool_use = true },
            .{ .id = "deepseek-reasoner", .context_window = 128_000, .max_output_tokens = 64_000, .supports_tool_use = true },
        },
    }),
    preset("qwen", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "DASHSCOPE_API_KEY", .{
        .reasoning_format = .enable_thinking,
        .default_model = "qwen3-coder-plus",
        .models = &.{
            .{ .id = "qwen3-coder-plus", .context_window = 1_000_000, .max_output_tokens = 65_536, .supports_tool_use = true },
            .{ .id = "qwen3-coder-flash", .context_window = 1_000_000, .max_output_tokens = 65_536, .supports_tool_use = true },
            .{ .id = "qwen-max", .context_window = 262_144, .max_output_tokens = 32_768, .supports_tool_use = true },
            .{ .id = "qwen-plus", .context_window = 1_000_000, .max_output_tokens = 32_768, .supports_tool_use = true, .reasoning_efforts = &on_off },
        },
    }),
    preset("qwen-cn", "https://dashscope.aliyuncs.com/compatible-mode/v1", "DASHSCOPE_API_KEY", .{
        .reasoning_format = .enable_thinking,
        .default_model = "qwen3-coder-plus",
    }),
    preset("moonshot", "https://api.moonshot.ai/v1", "MOONSHOT_API_KEY", .{
        .reasoning_format = .none,
        .default_model = "kimi-k2-turbo-preview",
    }),
    preset("moonshot-cn", "https://api.moonshot.cn/v1", "MOONSHOT_API_KEY", .{
        .reasoning_format = .none,
        .default_model = "kimi-k2-turbo-preview",
    }),
    preset("zai", "https://api.z.ai/api/paas/v4", "ZAI_API_KEY", .{
        .reasoning_format = .thinking,
        .default_model = "glm-4.6",
        .models = &.{
            .{ .id = "glm-4.6", .context_window = 200_000, .max_output_tokens = 128_000, .supports_tool_use = true, .reasoning_efforts = &on_off },
        },
    }),
    preset("zhipu", "https://open.bigmodel.cn/api/paas/v4", "ZHIPUAI_API_KEY", .{
        .reasoning_format = .thinking,
        .default_model = "glm-4.6",
    }),
    preset("minimax", "https://api.minimax.io/v1", "MINIMAX_API_KEY", .{
        .reasoning_format = .none,
        .default_model = "MiniMax-M2",
    }),
    preset("openrouter", "https://openrouter.ai/api/v1", "OPENROUTER_API_KEY", .{
        .reasoning_format = .openrouter,
    }),
    preset("openai", "https://api.openai.com/v1", "OPENAI_API_KEY", .{}),
    preset("anthropic", "https://api.anthropic.com/v1", "ANTHROPIC_API_KEY", .{ .reasoning_format = .none }),
    preset("gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "GEMINI_API_KEY", .{}),
    preset("xai", "https://api.x.ai/v1", "XAI_API_KEY", .{}),
    preset("mistral", "https://api.mistral.ai/v1", "MISTRAL_API_KEY", .{ .reasoning_format = .none }),
    preset("groq", "https://api.groq.com/openai/v1", "GROQ_API_KEY", .{}),
    preset("together", "https://api.together.xyz/v1", "TOGETHER_API_KEY", .{ .reasoning_format = .none }),
    preset("fireworks", "https://api.fireworks.ai/inference/v1", "FIREWORKS_API_KEY", .{ .reasoning_format = .none }),
    preset("siliconflow", "https://api.siliconflow.com/v1", "SILICONFLOW_API_KEY", .{ .reasoning_format = .enable_thinking }),
    preset("ollama", "http://localhost:11434/v1", null, .{ .reasoning_format = .none }),
    preset("lmstudio", "http://localhost:1234/v1", null, .{ .reasoning_format = .none }),
    preset("llamacpp", "http://localhost:8080/v1", null, .{ .reasoning_format = .none }),
    preset("vllm", "http://localhost:8000/v1", null, .{ .reasoning_format = .none }),
};

/// The first preset, in list order, whose API key variable is set and
/// non-empty. Local presets without a key are never detected.
pub fn detect(getenv: *const fn ([]const u8) ?[]const u8) ?*const Definition {
    for (&definitions) |*definition| {
        const env = switch (definition.auth) {
            .none => continue,
            .bearer => |name| name,
        };
        const value = getenv(env) orelse continue;
        if (std.mem.trim(u8, value, " \t\r\n").len != 0) return definition;
    }
    return null;
}

/// Returns a static preset; the pointer stays valid for the whole process.
pub fn get(id: []const u8) ?*const Definition {
    for (&definitions) |*definition| {
        if (std.mem.eql(u8, definition.id, id)) return definition;
    }
    return null;
}

test "provider presets are valid connection definitions" {
    for (definitions, 0..) |definition, index| {
        try configured_provider.validate_id(definition.id);
        for (definitions[0..index]) |prior| try std.testing.expect(!std.mem.eql(u8, prior.id, definition.id));
        try std.testing.expect(!std.mem.endsWith(u8, definition.base_url, "/"));
        if (definition.default_model) |model| try configured_provider.validate_model_id(model);
        for (definition.model_metadata) |metadata| {
            try configured_provider.validate_model_id(metadata.id);
            if (metadata.context_window != null and metadata.max_output_tokens != null) {
                try std.testing.expect(metadata.max_output_tokens.? < metadata.context_window.?);
            }
        }
    }
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", get("deepseek").?.auth.bearer);
    try std.testing.expect(get("ollama").?.auth == .none);
    try std.testing.expect(get("missing") == null);
}

test "provider preset detection follows list order and ignores blank keys" {
    const Env = struct {
        fn only_qwen(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "DEEPSEEK_API_KEY")) return "  ";
            if (std.mem.eql(u8, name, "DASHSCOPE_API_KEY")) return "sk-qwen";
            if (std.mem.eql(u8, name, "OPENROUTER_API_KEY")) return "sk-or";
            return null;
        }
        fn none(_: []const u8) ?[]const u8 {
            return null;
        }
    };
    try std.testing.expectEqualStrings("qwen", detect(Env.only_qwen).?.id);
    try std.testing.expect(detect(Env.none) == null);
}
