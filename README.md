# abc

abc is a model-agnostic coding agent CLI written in Zig. It is a hard fork of
[fx](https://github.com/vercel-labs/fx) (commit `59bf437`) that aims to work
first-class with any OpenAI-compatible provider, such as DeepSeek, Qwen, Kimi,
GLM, MiniMax, OpenRouter, Ollama, vLLM, and llama.cpp, without depending on the
Vercel AI Gateway.

> Status: experimental, under active restructuring. See [PROPOSAL.md](PROPOSAL.md)
> for the plan.

## Build

Requires Zig 0.16.0.

```bash
zig build            # builds zig-out/bin/abc
zig build test       # runs the unit tests
./zig-out/bin/abc    # starts an interactive session
```

`abc upgrade` and automatic upgrades are disabled; rebuild from source instead.

## Configure a provider

Until the configuration directory is renamed, abc reads `~/.fx/settings.json`.
Add a named connection and select it:

```jsonc
{
  "providers": {
    "deepseek": {
      "protocol": "openai-chat-completions",
      "base_url": "https://api.deepseek.com/v1",
      "auth": { "type": "bearer", "env": "DEEPSEEK_API_KEY" },
      "tool_choice_mode": "send"
    }
  }
}
```

```bash
FX_PROVIDER=deepseek FX_MODEL=deepseek-chat ./zig-out/bin/abc ask "explain this repository"
```

## Upstream documentation

The original fx README is kept at [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md)
for reference. Parts of it (Vercel login, gateway routing, Slack) do not apply to
abc and will be removed.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). abc is not affiliated
with or endorsed by Vercel, Inc.
