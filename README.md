# fx (fork)

This fx is a model-agnostic coding agent CLI written in Zig. It is a hard fork of
[fx](https://github.com/vercel-labs/fx) (commit `59bf437`) that works first-class
with any OpenAI-compatible provider, such as DeepSeek, Qwen, Kimi, GLM, MiniMax,
OpenRouter, Ollama, vLLM, and llama.cpp, without depending on the Vercel AI
Gateway.

It keeps the `fx` name, binary, `~/.fx` profile, and `FX_*` variables, so it
replaces an installed upstream fx: uninstall the original before using it.

> Status: experimental, under active restructuring. See [PROPOSAL.md](PROPOSAL.md)
> for the plan.

## Install (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/abelcondev/abc/main/install.sh | sh
```

Installs the latest release for Apple Silicon or Intel into `~/.local/bin`
(`FX_INSTALL_DIR` changes it, `FX_VERSION=v0.1.0` pins a release). Other
platforms can build from source. Later, `fx update` installs the newest
release over the running binary.

Open `fx` in a project and run `/provider`: pick a preset, paste its API key
when asked (saved in the macOS Keychain), then choose a model with `/model`.

## Build

Requires Zig 0.16.0.

```bash
zig build                              # builds zig-out/bin/fx
zig build test                         # runs the unit tests
zig build test -Dtest-filter="preset"  # runs a subset
./zig-out/bin/fx                      # starts an interactive session
```

`fx upgrade` and automatic upgrades are disabled; rebuild from source instead.

## Use a provider preset

Built-in presets need only the provider's API key in the environment:

```bash
export DEEPSEEK_API_KEY=...
FX_PROVIDER=deepseek ./zig-out/bin/fx ask "explain this repository"

export DASHSCOPE_API_KEY=...
FX_PROVIDER=qwen FX_MODEL=qwen3-coder-plus ./zig-out/bin/fx
```

Or save the key once instead of exporting it (macOS Keychain, or an
owner-only file under `~/.fx/provider-keys` elsewhere):

```bash
./zig-out/bin/fx login deepseek      # prompts for the key, then selects deepseek
echo "$KEY" | ./zig-out/bin/fx login qwen
./zig-out/bin/fx logout deepseek
```

An exported variable takes precedence over a saved key. With no provider
selected, fx picks the first preset whose key variable is exported.

Inside a session, `/provider` lists the presets and switches between them, and
`fx models` lists the models the provider reports at `GET /models`.

| Preset | API key variable | Endpoint |
| --- | --- | --- |
| `deepseek` | `DEEPSEEK_API_KEY` | api.deepseek.com (`deepseek-flash`, `deepseek-v4-pro`; verified end to end) |
| `qwen`, `qwen-cn` | `DASHSCOPE_API_KEY` | DashScope compatible mode (intl / China) |
| `qwen-plan` | `QWEN_TOKEN_PLAN_API_KEY` | Model Studio Token Plan, Singapore (`sk-sp-…` plan key; qwen3.8, GLM and DeepSeek models; verified end to end) |
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
| SearXNG (self-hosted, JSON format enabled) | `FX_SEARXNG_URL=http://host:8080` |

With several set, they are preferred in that order; `FX_WEB_SEARCH_BACKEND`
pins one. `web_fetch` works without any configuration.

## Jev decisions

[Jev](https://docs.typesafe.ai) is TypeSafe AI's decision model. It does not
write code; it answers typed questions with calibrated probabilities. fx uses
it as an independent check on the agent, next to whatever model does the work.

```bash
fx jev key       # paste a TypeSafe API key (saved in the Keychain)
fx jev check     # one live call to confirm the key works
fx jev on        # enable for new sessions (writes jev.enabled)
fx jev eval      # run the labeled calibration cases against live Jev
fx jev           # show status
fx jev off
```

Inside a session, `/jev` shows the status and `/jev on` or `/jev off` switches
it for the current session and saves the choice.

**Plan before changes.** Before the first file change (`write_file` or
`edit_file`) of a turn, Jev rates how substantial the request is. Trivial and
small requests pass. For a substantial one, the change is held until the
agent has stated a plan with steps and checkable acceptance criteria that
covers the request without unrequested extra work. A turn is held at most
twice, then changes go through.

**Answering settled questions.** When the agent asks a multiple-choice
question in a session, Jev answers it only when the request or what the agent
already found settles the answer (for example, a pinned dependency). Choices
that are a matter of preference, or that the user asked to make, still go to
the user. The agent is told the answer came from Jev so it can mention it.

**Action check (opt-in, `gates.action`).** Before each file change or shell
command, Jev checks that it is a step toward the request and does not delete,
overwrite, publish, or reach outside the project in a way the user did not ask
for. Held calls return the reason to the agent. It complements, never
replaces, the permission system, and adds about half a second per call.

**Model routing (opt-in, `routing`).** When the agent starts a temporary
subagent without naming a model, Jev picks one of your routes for the task:

```json
"jev": {
  "enabled": true,
  "routing": {
    "light": { "model": "deepseek-flash", "effort": "low" },
    "heavy": { "model": "deepseek-v4-pro" }
  }
}
```

`light` and `heavy` have built-in descriptions; other route names need a
`description`. Routes need at least two entries and models from the active
provider.

**Completion check.** When the agent finishes a turn that asked for work, fx
sends Jev the request, the final answer and the turn's tool results. If Jev
cannot confirm that the requested work was carried out, or that every claim in
the answer is backed by a tool result, the agent continues once with the
reasons and is asked to verify before answering again. Questions, small talk
and answers that report a blocker or ask the user pass through. If Jev is
unreachable or has no key, the turn finishes normally.

`fx jev eval [stop|plan|action|ask|routing]` runs labeled cases through the
same questions, code and thresholds as the live gates and prints each answer,
so threshold or model changes can be checked before use.

**Spec drift.** `fx jev drift [<git-range>] [--dir <path>]` checks a diff
(default: uncommitted changes) against the project's decision records
(`sdd/decisions`, `docs/decisions`, `docs/adr` or `decisions`, one Markdown file
each, front matter `title`/`status`/`description` optional). Jev first picks
the decisions the diff touches, then reads them and flags the ones the change
contradicts. It exits non-zero when any decision may be out of date, so it can
run in CI.

The same check runs at the end of a session turn that changed files, when the
workspace has a decisions directory (`gates.drift`, default on). If the
uncommitted changes contradict a record, the agent is asked to update the
record (or fix the code) before answering. Each record is flagged once per
session.

Every decision is recorded in `~/.fx/sessions/<id>/decisions.jsonl` with Jev's
answers, the threshold and the outcome (the state sent to Jev is not stored).

Settings live under `jev` in `~/.fx/settings.json` only; project `.fx.json`
files cannot set them.

| Field | Meaning |
| --- | --- |
| `enabled` | Turn Jev decisions on (default `false`) |
| `model` | Jev model (default `jev-latest`) |
| `gates.ask` | Let Jev answer questions the context already settles (default `true`) |
| `gates.plan` | Require a plan before changes on substantial requests (default `true`) |
| `gates.drift` | Flag decision records a turn's changes contradict (default `true`) |
| `gates.action` | Check file changes and shell commands (default `false`) |
| `gates.stop` | Run the completion check (default `true`) |
| `thresholds.ask` | Minimum confidence and grounding for answering (default `0.8`) |
| `thresholds.plan` | Minimum probability the plan checks must reach (default `0.5`) |
| `thresholds.action` | Unrequested-damage probability that holds an action (default `0.6`) |
| `routing.<name>` | `model`, optional `effort`, and `description` for a subagent route |
| `thresholds.stop` | Minimum probability each completion check must reach (default `0.5`) |

`TYPESAFE_API_KEY`, `FX_JEV=on|off`, `FX_JEV_MODEL` and `FX_JEV_BASE_URL`
override the saved values.

## Configure a connection

Settings live in `~/.fx/settings.json` (per project: `.fx.json`). Environment
variables use the `FX_` prefix.

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
| `default_model` | Model used when `FX_MODEL` and saved preferences do not pick one |
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
- Provider API keys are saved per preset in the Keychain (`FX_PROVIDER_KEY_<id>`)
  or `~/.fx/provider-keys`.

## Upstream documentation

The original fx README is kept at [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md)
for reference. Parts of it (Vercel login, gateway routing, Slack) do not apply to
this fork.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). This fork is not affiliated
with or endorsed by Vercel, Inc.
