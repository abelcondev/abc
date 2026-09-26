# abc

abc is a model-agnostic coding agent CLI written in Zig. It is a hard fork of
[fx](https://github.com/vercel-labs/fx) (commit `59bf437`) that works first-class
with any OpenAI-compatible provider, such as DeepSeek, Qwen, Kimi, GLM, MiniMax,
OpenRouter, Ollama, vLLM, and llama.cpp, without depending on the Vercel AI
Gateway.

> Status: experimental, under active restructuring. See [PROPOSAL.md](PROPOSAL.md)
> for the plan.

## Install (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/abelcondev/abc/main/install.sh | sh
```

Installs the latest release for Apple Silicon or Intel into `~/.local/bin`
(`ABC_INSTALL_DIR` changes it, `ABC_VERSION=v0.1.0` pins a release). Other
platforms can build from source. Later, `abc update` installs the newest
release over the running binary.

Open `abc` in a project and run `/provider`: pick a preset, paste its API key
when asked (saved in the macOS Keychain), then choose a model with `/model`.

## Build

Requires Zig 0.16.0.

```bash
zig build                              # builds zig-out/bin/abc
zig build test                         # runs the unit tests
zig build test -Dtest-filter="preset"  # runs a subset
./zig-out/bin/abc                      # starts an interactive session
```

`abc upgrade` and automatic upgrades are disabled; rebuild from source instead.

## Use a provider preset

Built-in presets need only the provider's API key in the environment:

```bash
export DEEPSEEK_API_KEY=...
ABC_PROVIDER=deepseek ./zig-out/bin/abc ask "explain this repository"

export DASHSCOPE_API_KEY=...
ABC_PROVIDER=qwen ABC_MODEL=qwen3-coder-plus ./zig-out/bin/abc
```

Or save the key once instead of exporting it (macOS Keychain, or an
owner-only file under `~/.abc/provider-keys` elsewhere):

```bash
./zig-out/bin/abc login deepseek      # prompts for the key, then selects deepseek
echo "$KEY" | ./zig-out/bin/abc login qwen
./zig-out/bin/abc logout deepseek
```

An exported variable takes precedence over a saved key. With no provider
selected, abc picks the first preset whose key variable is exported.

Inside a session, `/provider` lists the presets and switches between them, and
`abc models` lists the models the provider reports at `GET /models`.

| Preset | API key variable | Endpoint |
| --- | --- | --- |
| `deepseek` | `DEEPSEEK_API_KEY` | api.deepseek.com (`deepseek-flash`, `deepseek-v4-pro`; verified end to end) |
| `qwen`, `qwen-cn` | `DASHSCOPE_API_KEY` | DashScope compatible mode (intl / China) |
| `moonshot`, `moonshot-cn` | `MOONSHOT_API_KEY` | Kimi (intl / China) |
| `zai`, `zhipu` | `ZAI_API_KEY`, `ZHIPUAI_API_KEY` | GLM (Z.ai / BigModel) |
| `minimax` | `MINIMAX_API_KEY` | api.minimax.io |
| `openrouter` | `OPENROUTER_API_KEY` | openrouter.ai |
| `openai`, `anthropic`, `gemini`, `xai`, `mistral` | `<NAME>_API_KEY` | vendor OpenAI-compatible endpoints |
| `groq`, `together`, `fireworks`, `siliconflow` | `<NAME>_API_KEY` | vendor OpenAI-compatible endpoints |
| `ollama`, `lmstudio`, `llamacpp`, `vllm` | none | localhost default ports |

Models that `GET /models` reports with `context_window`, `max_output_tokens`,
`effort.supported_levels` or `input_modalities` pick those up automatically.
Preset endpoints and model ids follow each provider's public documentation and
may drift; override a preset by defining a provider with the same name.

## Web search

The `web_search` tool works with any provider once a search API is configured:

| Backend | Variable |
| --- | --- |
| Tavily | `TAVILY_API_KEY` (supports allowed/blocked domains) |
| Brave Search API | `BRAVE_API_KEY` |
| SearXNG (self-hosted, JSON format enabled) | `ABC_SEARXNG_URL=http://host:8080` |

With several set, they are preferred in that order; `ABC_WEB_SEARCH_BACKEND`
pins one. `web_fetch` works without any configuration.

## Configure a connection

Settings live in `~/.abc/settings.json` (per project: `.abc.json`). Environment
variables use the `ABC_` prefix; the upstream `FX_` names still work as a
fallback.

```jsonc
{
  "providers": {
    "deepseek": {
      "protocol": "openai-chat-completions",
      "base_url": "https://api.deepseek.com",
      "auth": { "type": "bearer", "env": "DEEPSEEK_API_KEY" },
      "tool_choice_mode": "send",
      "default_model": "deepseek-flash",
      "reasoning_format": "thinking_effort",
      "model_metadata": {
        "deepseek-flash": { "context_window": 1048576, "max_output_tokens": 393216, "supports_tool_use": true, "reasoning_efforts": ["none", "low", "high", "max"] }
      }
    }
  }
}
```

| Field | Meaning |
| --- | --- |
| `reasoning_format` | How `--effort` is sent: `reasoning_effort` (default), `thinking`, `thinking_effort` (DeepSeek V4), `enable_thinking`, `openrouter`, or `none` |
| `model_metadata.<id>.reasoning_efforts` | Efforts the model accepts; enables the effort picker for it |
| `default_model` | Model used when `ABC_MODEL` and saved preferences do not pick one |
| `merge_system_messages` | Join adjacent system messages (default `true`) |
| `strict_stream` | Require strict OpenAI stream framing (default `false`) |
| `tool_choice_mode` | `send` forwards `tool_choice`; `omit` (default) leaves it out |

Plain `http://` endpoints are accepted for localhost and private-network hosts
(RFC 1918, Tailscale CGNAT, `.local`).

## What changed from fx

- A lenient stream reader tolerates common OpenAI-compatible deviations
  (tool calls finished with `stop`, missing `[DONE]`, unindexed tool deltas,
  vendor finish reasons) while still rejecting unknown tools and malformed
  arguments. This is what made tool calls and subagents fail on custom models.
- Reasoning controls, provider presets, and model discovery for configured
  providers.
- The Codex and Grok subscription providers were removed.
- Profile data moved from `~/.fx` to `~/.abc`.

## Upstream documentation

The original fx README is kept at [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md)
for reference. Parts of it (Vercel login, gateway routing, Slack) do not apply to
abc.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). abc is not affiliated
with or endorsed by Vercel, Inc.
