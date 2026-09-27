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

## Set up fx

A working setup takes five steps. Each can be checked on its own.

**1. Choose a provider and a model.** Save the provider's key once (macOS
Keychain) and pick the default model:

```bash
fx login deepseek            # or: fx login qwen, fx login openrouter, ...
fx                           # then /model inside the session
```

Inside a session, `/provider` switches providers and `/model` models and
reasoning effort. `fx status` prints the active provider, model, credentials
and permission mode.

**2. Choose what fx may do without asking.** `/permissions` switches between
`ask` (confirm sensitive actions), `auto` (a security review decides) and
`full-access` (no fx checks). The choice is saved in your profile;
`--auto` or `--full-access` on `fx ask` apply to one run.

**3. Tell the agent about your project.** fx reads `AGENTS.md` at the
workspace root, plus `~/.fx/AGENTS.md` for rules that apply everywhere. Keep
it short: what the app is, the stack, and conventions the code does not show
(language to reply in, package manager, where tests live).

**4. Turn on Jev** (optional, recommended). Jev checks the agent's decisions:
a plan before large changes, answers backed by evidence, questions it can
settle, and subagent models. Get a key from [TypeSafe AI](https://docs.typesafe.ai):

```bash
fx jev key                   # paste the TypeSafe key (Keychain)
fx jev check                 # one live call to confirm it works
fx jev on                    # enable it for new sessions
fx jev                       # status: gates, thresholds, key source
```

**5. Turn on spec-driven development per project** (optional, needs Jev for
its checks). From the project directory:

```bash
fx sdd on                    # this workspace only; others stay free
fx sdd tdd on                # optional: behavior changes start with a failing test
fx sdd                       # status: specs, open changes, checks that run
```

Then work as usual. Small fixes go straight through, a change to an existing
rule updates the spec in the same change, and a feature or a change to data,
money, auth or a new screen stops for a short proposal in `sdd/changes/` that
you approve by replying "yes" or with `/sdd approve`. Close a finished change
with `/sdd done`. Commit the `sdd/` folder with the code so specs and changes
travel with the project. The sections below explain each part.

**Where settings live**

| What | Where | Override |
| --- | --- | --- |
| Provider keys, Jev key | macOS Keychain (`fx login`, `fx jev key`) | `DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`, `TYPESAFE_API_KEY`, ... |
| Provider, model, permissions, Jev | `~/.fx/settings.json` | `FX_PROVIDER`, `FX_MODEL`, `FX_PERMISSION_MODE`, `FX_JEV=on\|off` |
| SDD and TDD, per project | `~/.fx/settings.json` → `workspaces["<path>"].sdd` | `FX_SDD=on\|off` |
| Project defaults safe to commit | `<project>/.fx.json` | |
| Sessions and Jev's decision log | `~/.fx/sessions/<id>/` (`decisions.jsonl`) | |

The status line shows the permission mode, the model and `sdd` while SDD is on.
Calls a Jev or SDD check holds appear as "Held" in the transcript.

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

`fx jev eval [stop|plan|action|ask|routing|sdd]` runs labeled cases through the
same questions, code and thresholds as the live gates and prints each answer,
so threshold or model changes can be checked before use.

**Spec drift.** `fx jev drift [<git-range>] [--dir <path>]` checks a diff
(default: uncommitted changes) against the project's decision records
(`sdd/specs`, where each `## ` rule is checked on its own, or `sdd/decisions`,
`docs/decisions`, `docs/adr` or `decisions`, one Markdown file each, front
matter `title`/`status`/`description` optional). Jev first picks
the decisions the diff touches, then reads them and flags the ones the change
contradicts. It exits non-zero when any decision may be out of date, so it can
run in CI.

The same check runs at the end of a session turn that changed files, when SDD
is on for the workspace (see below) and it has a decisions directory
(`gates.drift`, default on). If the uncommitted changes contradict a record,
the agent is asked to update the record (or fix the code) before answering.
Each record is flagged once per session.

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
| `gates.sdd` | With SDD on, route the first file change to fix, spec or change (default `true`) |
| `gates.action` | Check file changes and shell commands (default `false`) |
| `gates.stop` | Run the completion check (default `true`) |
| `thresholds.ask` | Minimum confidence and grounding for answering (default `0.8`) |
| `thresholds.plan` | Minimum probability the plan checks must reach (default `0.5`) |
| `thresholds.action` | Unrequested-damage probability that holds an action (default `0.6`) |
| `routing.<name>` | `model`, optional `effort`, and `description` for a subagent route |
| `thresholds.stop` | Minimum probability each completion check must reach (default `0.5`) |

`TYPESAFE_API_KEY`, `FX_JEV=on|off`, `FX_JEV_MODEL` and `FX_JEV_BASE_URL`
override the saved values.

## Spec-driven development

SDD is fx's spec-driven development process. It is off by default, so fx works
freely in every workspace until you turn it on for one:

```bash
fx sdd                   # status: specs, open changes and the checks that run
fx sdd on                # turn it on here (writes workspaces["<path>"].sdd.enabled)
fx sdd off
fx sdd new <slug>        # write sdd/changes/<yyyy-mm-dd>-<slug>.md (proposed)
fx sdd approve [<name>]  # proposed -> approved
fx sdd done [<name>]     # approved -> done
fx sdd tdd off|on|strict # test-first behavior changes (writes sdd.tdd)
```

Inside a session, `/sdd` accepts the same subcommands. The status line shows
`sdd` while it is on.

The process keeps two kinds of Markdown files under `sdd/`:

```
sdd/
  specs/reservas.md                     # how the system behaves today
  changes/2026-09-27-pagos-parciales.md # one file per change
```

A spec holds only current behavior. Every `## ` heading is one rule, and the
text under it describes the rule. A change file has a flat front matter that
only fx edits, then Why, What, an optional Wireframe for a new screen, Tasks
and Notes:

```markdown
---
status: proposed
specs: [reservas]
---
# Pagos parciales

## Why
## What
## Tasks
- [ ] Schema
## Notes
```

With Jev on, fx sorts each turn's first file change outside `sdd/` into one of
three routes, so small work skips the paperwork:

| Route | When | What happens |
| --- | --- | --- |
| fix | No rule changes | Nothing to write |
| spec | A small change to existing rules | The agent is told which rules to update in the same change |
| change | Schema, money, auth, the AI pipeline, a new screen, or substantial work | Code changes are held until a change file is approved; files under `sdd/` stay writable |

A vague request, or one Jev cannot classify, is sent back so the agent asks
you which route it is. Saying "no hagas propuesta" or "skip the spec" makes it
a fix, and so does a request that only ships finished work (commit, push, open
a PR, release notes). Files outside the workspace, such as a PR body in `/tmp`,
are never routed. A proposed change is approved by `fx sdd approve`, `/sdd approve`, or a
reply that approves it ("sí, dale", "si yes, y abre el PR"), even in a turn
that changes no code. With several proposals open, the one your reply names is
approved, else the newest. Once a change is approved, code changes go
through. Approving and closing are yours: when the agent runs `fx sdd approve`
or `fx sdd done` itself, fx holds the command. The agent ticks the change's
tasks as it works, and after the first turn that changes code under an approved
change it is asked once to write the behavior as rules in `sdd/specs`, so the
specs grow with each change. Writing files under `sdd/` never needs a plan, and
the completion check lets a turn end while a change waits for your approval.
Calls a gate holds show as "Held" in the transcript, not "Failed". `fx jev eval sdd` runs the routing against labeled cases.

**Test-first.** `fx sdd tdd on` (or `/sdd tdd on`) makes behavior changes
test-first while SDD is on: spec and change routes, and fixes that repair a
bug. Before the first source change, the turn must have changed a test and run
it failing; before the answer, a test run must pass after the last source
change. Both come from the turn's own tool results, including a runner's
`1 fail` summary when the command is piped. Jev then checks that the changed
tests would fail without the requested behavior. `fx sdd tdd strict` also
requires every changed rule to be cited by a test, and `fx sdd` reports how
many rules are:

```ts
// spec: reservas › Saldo is the outstanding balance
test("subtracts payments", () => { ... });
```

A rule whose heading ends in `(manual)`, or a change with `tdd: manual` in its
front matter, is checked in the running app instead. fx recognizes common
runners (`bun test`, `npm test`, `pytest`, `go test`, `cargo test`,
`zig build test` and others); set `"test": "<command>"` under `sdd` in the
settings for anything else. A fix or spec update that grows past 8 source files
is held once so the agent can propose a change instead.

After turns that change files, the Jev spec drift check compares the
uncommitted changes with each rule in `sdd/specs` (or with the files in
`sdd/decisions`, `docs/decisions`, `docs/adr` or `decisions` when there are no
specs) and asks the agent to update the rules the code now contradicts. With
SDD off, nothing is routed or checked automatically; `fx jev drift` still runs
on demand.

The setting lives in `~/.fx/settings.json` only, per workspace, with an
optional top-level `"sdd": {"enabled": true}` default for every workspace.
Project `.fx.json` files cannot turn it on. `FX_SDD=on|off` overrides the saved
value for one shell or CI run.

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
