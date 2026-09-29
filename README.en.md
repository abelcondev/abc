# fx

[Español](README.md) | **English**

A fast coding agent for your terminal that works with **any model you want**:
DeepSeek, Qwen, Kimi, GLM, MiniMax, OpenRouter, OpenAI, Gemini, or a local
model on Ollama, LM Studio, llama.cpp or vLLM.

fx is a hard fork of [fx](https://github.com/vercel-labs/fx) (commit `59bf437`)
that drops the dependency on the Vercel AI Gateway and adds **Jev**, an
independent checker that keeps the agent honest.

> Status: experimental, under active development. See [PROPOSAL.md](PROPOSAL.md).

## Contents

- [Why fx](#why-fx)
- [Quickstart](#quickstart)
- [How it works](#how-it-works)
- [Providers and models](#providers-and-models)
- [Jev: the agent's checker](#jev-the-agents-checker)
- [SDD: specs before big changes](#sdd-specs-before-big-changes)
- [TDD: tests first](#tdd-tests-first)
- [Permissions and project rules](#permissions-and-project-rules)
- [Where settings live](#where-settings-live)
- [Reference](#reference)

## Why fx

- **Your model, your bill.** Bring any OpenAI-compatible provider, or run fully
  local. No gateway in the middle.
- **Tool calls that actually work.** A tolerant stream reader handles the quirks
  of non-OpenAI models (odd finish reasons, missing `[DONE]`, unindexed tool
  deltas) that break tool calls and subagents in other agents.
- **A second opinion on every turn.** Jev checks that big changes have a plan,
  that "done" means done, and that claims are backed by real tool output.
- **Specs that stay up to date.** Optional SDD keeps a light `sdd/` folder of
  rules and change proposals, and flags when code contradicts them.
- **Native and fast.** A single Zig binary with millisecond startup. Keys are
  stored in the macOS Keychain.

## Quickstart

**1. Install** (macOS, Apple Silicon or Intel):

```bash
curl -fsSL https://raw.githubusercontent.com/abelcondev/fx/main/install.sh | sh
```

This installs into `~/.local/bin`. `FX_INSTALL_DIR` changes the folder and
`FX_VERSION=v0.1.0` pins a release. On other platforms, [build from source](#build-from-source).
fx uses the `fx` name and `~/.fx` folder, so uninstall the original Vercel fx first.

**2. Connect a provider** (the key is saved in the Keychain):

```bash
fx login deepseek        # or qwen, openrouter, moonshot, zai, ...
```

Local models need no key: `fx provider ollama` (or `lmstudio`, `llamacpp`, `vllm`).

**3. Start working:**

```bash
cd my-project
fx                       # interactive session
fx ask "explain this repository"   # one request, no session
```

That's it. The rest is optional: pick a model with `/model`, turn on
[Jev](#jev-the-agents-checker), and turn on [SDD](#sdd-specs-before-big-changes)
per project.

To update later, run `fx update`.

## How it works

```
   you ──► fx (agent loop) ──► your model (DeepSeek, Qwen, local, ...)
              │    ▲
              │    └── tool results: files, shell, web, subagents
              ▼
        permissions      ← what the agent may do without asking
        Jev (optional)   ← is there a plan? is it really done?
        SDD (optional)   ← does this change need a spec or a proposal?
```

The model does the work. fx runs the tools, enforces permissions, and, when you
turn them on, asks Jev and SDD to check the work at key moments.

## Providers and models

### Pick a provider

```bash
fx login <preset>        # save the key and select that provider
fx provider <preset>     # switch provider
fx logout <preset>       # forget the key
fx status                # show provider, model, credentials, permissions
```

Inside a session, `/provider` lists the presets and switches between them.

You can also skip `login` and export the key. An exported variable wins over a
saved one:

```bash
export DEEPSEEK_API_KEY=...
FX_PROVIDER=deepseek fx
```

With no provider selected, fx picks the first preset whose key variable is set.

### Built-in presets

| Preset | API key variable | Endpoint |
| --- | --- | --- |
| `deepseek` | `DEEPSEEK_API_KEY` | api.deepseek.com (`deepseek-flash`, `deepseek-v4-pro`; verified end to end) |
| `qwen`, `qwen-cn` | `DASHSCOPE_API_KEY` | DashScope compatible mode (intl / China) |
| `qwen-plan` | `QWEN_TOKEN_PLAN_API_KEY` | Model Studio Token Plan, Singapore (`sk-sp-…` plan key; qwen3.8, GLM and DeepSeek models; verified end to end) |
| `moonshot`, `moonshot-cn` | `MOONSHOT_API_KEY` | Kimi (intl / China) |
| `zai`, `zhipu` | `ZAI_API_KEY`, `ZHIPUAI_API_KEY` | GLM (Z.ai / BigModel) |
| `minimax` | `MINIMAX_API_KEY` | api.minimax.io |
| `muse` | `MUSE_API_KEY` | Meta Model API, api.meta.ai (`muse-spark-1.3`, `muse-spark-1.3-contributor`; works with a Muse Code plan key; verified end to end) |
| `openrouter` | `OPENROUTER_API_KEY` | openrouter.ai |
| `openai`, `anthropic`, `gemini`, `xai`, `mistral` | `<NAME>_API_KEY` | vendor OpenAI-compatible endpoints |
| `groq`, `together`, `fireworks`, `siliconflow` | `<NAME>_API_KEY` | vendor OpenAI-compatible endpoints |
| `ollama`, `lmstudio`, `llamacpp`, `vllm` | none | localhost default ports |

Preset endpoints and model ids follow each provider's public docs and may drift.
To change one, define a provider with the same name (see below).

### Choose a model

```bash
fx models                # models the provider reports
fx --model deepseek-v4-pro --effort high
```

Inside a session, `/model` picks the model and its reasoning effort, and the
choice is saved. `FX_MODEL` overrides it for one shell. When the provider's
`GET /models` reports `context_window`, `max_output_tokens`, effort levels or
input types, fx picks them up automatically.

### Add your own provider

Any OpenAI-compatible endpoint works. Add it to `~/.fx/settings.json`:

```jsonc
{
  "providers": {
    "my-provider": {
      "protocol": "openai-chat-completions",
      "base_url": "https://api.example.com/v1",
      "auth": { "type": "bearer", "env": "MY_PROVIDER_API_KEY" },
      "default_model": "my-model"
    }
  }
}
```

Then `fx provider my-provider`. Plain `http://` works for localhost and private
networks (RFC 1918, Tailscale, `.local`). All fields are in
[Provider fields](#provider-fields).

## Jev: the agent's checker

[Jev](https://docs.typesafe.ai) is TypeSafe AI's decision model. It **does not
write code**. It answers short, typed questions ("is this plan complete?",
"is every claim backed by a tool result?") with calibrated probabilities. fx
asks it at key points of each turn, so a second, independent model checks the
work model.

### What Jev does in a turn

```
 you: "add partial payments"
   │
   ▼
 ┌────────────────────── agent turn ──────────────────────┐
 │                                                        │
 │  agent asks you a question                             │
 │     └─► ASK: Jev answers it if the context settles it, │
 │              otherwise it still goes to you            │
 │                                                        │
 │  first file change of the turn                         │
 │     ├─► PLAN: big request? hold until the agent writes │
 │     │         a plan with steps and acceptance checks  │
 │     └─► SDD:  (if on) fix / spec / change route        │
 │                                                        │
 │  each edit or command (opt-in)                         │
 │     └─► ACTION: on-task? no unrequested damage?        │
 │                                                        │
 │  subagent without a model (opt-in)                     │
 │     └─► ROUTING: Jev picks a light or heavy model      │
 │                                                        │
 │  agent says "done"                                     │
 │     ├─► STOP:  work really done? claims backed by      │
 │     │          tool output? if not, the agent          │
 │     │          continues once and verifies             │
 │     └─► DRIFT: (if SDD on) code contradicts a spec     │
 │                rule? the agent updates it              │
 └────────────────────────────────────────────────────────┘
   │
   ▼
 answer
```

In plain words:

| Check | What it prevents | Default |
| --- | --- | --- |
| **Plan** | Large changes started without a clear plan. Small requests pass. Held at most twice per turn. | on |
| **Ask** | Asking you things the code already answers (for example, a pinned version). Preferences still go to you. | on |
| **Stop** | "Done!" when the work isn't done, or claims ("tests pass") that no tool output shows. | on |
| **Drift** | Specs and decision records going stale after a change. Only with SDD on. | on |
| **SDD routing** | Big changes without a proposal. Only with SDD on. | on |
| **Action** | Deleting, overwriting, publishing or leaving the project when you didn't ask. Adds ~0.5s per call. | off |
| **Routing** | Using an expensive model for a trivial subagent task. | off |

Jev never replaces the permission system, it adds to it. Held calls show as
"Held" in the transcript, not "Failed". If Jev is unreachable or has no key,
the turn goes on normally.

### Set up Jev

Get a key at [TypeSafe AI](https://docs.typesafe.ai), then:

```bash
fx jev key       # paste the key (saved in the Keychain)
fx jev check     # one live call to confirm it works
fx jev on        # enable it for new sessions
fx jev           # status: checks, thresholds, key source
fx jev off       # turn it off
```

Inside a session, `/jev on` and `/jev off` switch it and save the choice.

**Optional: model routing.** Let Jev choose the subagent model per task:

```json
"jev": {
  "enabled": true,
  "routing": {
    "light": { "model": "deepseek-flash", "effort": "low" },
    "heavy": { "model": "deepseek-v4-pro" }
  }
}
```

**Optional: drift in CI.** `fx jev drift [<git-range>]` checks a diff against
your specs or decision records and exits non-zero when one may be out of date.

Every decision Jev makes is logged to `~/.fx/sessions/<id>/decisions.jsonl`.
All options are in [Jev settings](#jev-settings).

## SDD: specs before big changes

SDD (spec-driven development) keeps a small, living description of how your
project behaves, and makes the agent propose big changes before coding them.
**Small fixes go straight through, no paperwork.**

It is off by default and turned on **per project**. It needs Jev on.

### Turn it on

```bash
cd my-project
fx sdd on        # this project only; others stay free
fx sdd           # status: specs, open changes, checks that run
fx sdd off
```

The status line shows `sdd` while it's on. Commit the `sdd/` folder with your
code.

### What it creates

```
sdd/
├── specs/                        how the system behaves TODAY
│   └── bookings.md               each "## " heading is one rule
└── changes/                      one file per proposed change
    └── 2026-09-27-partial-payments.md
```

A change file is short. fx owns the front matter:

```markdown
---
status: proposed
specs: [bookings]
---
# Partial payments

## Why
## What
## Tasks
- [ ] Schema
## Notes
```

### How a request is routed

Before the first file change, Jev sorts the request into one of three routes:

```
                     your request
                          │
          ┌───────────────┼──────────────────┐
          ▼               ▼                  ▼
        FIX             SPEC              CHANGE
   no rule changes   small change to   schema, money, auth, AI
                     an existing rule  pipeline, new screen,
                                       or substantial work
          │               │                  │
          ▼               ▼                  ▼
     just code it   code + update the   write a proposal in
                    rule in the same    sdd/changes/, wait for
                    change              your "yes", then code
```

- Unclear requests come back to you as a question.
- Say "skip the spec" (or "no hagas propuesta") to force a fix.
- Shipping finished work (commit, push, PR, release notes) is never routed.

### Life of a change

```
  proposed ──(you approve)──► approved ──(you close)──► done
     │                           │
  agent writes            agent codes, ticks tasks,
  the proposal            writes the new rules into sdd/specs
```

Approve by replying "yes" / "sí, dale", or with `/sdd approve`. Close with
`/sdd done`. Only you approve and close: if the agent runs those commands
itself, fx holds them.

```bash
fx sdd new <slug>          # start a change file by hand
fx sdd approve [<name>]    # proposed → approved
fx sdd done [<name>]       # approved → done
```

After turns that change files, the drift check compares the code with each rule
in `sdd/specs` and asks the agent to update rules the code now contradicts.

## TDD: tests first

TDD is an SDD add-on. With it, behavior changes (spec and change routes, and
bug fixes) must start with a failing test.

```bash
fx sdd tdd on       # test-first
fx sdd tdd strict   # also: every changed rule must be cited by a test
fx sdd tdd off
```

### What fx enforces

```
  1. RED      change a test, run it, see it FAIL
                  │   (source edits are held until this happens)
                  ▼
  2. CODE     change the source
                  │
                  ▼
  3. GREEN    run the tests again, see them PASS
                  │   (the answer is held until this happens)
                  ▼
  4. JEV      would the new test fail without this behavior?
```

fx reads this from the turn's own tool output, so the agent can't just claim
it. It recognizes `bun test`, `npm test`, `pytest`, `go test`, `cargo test`,
`zig build test` and others. For anything else, set `"test": "<command>"` under
`sdd` in the settings.

In **strict** mode, a test cites the rule it covers:

```ts
// spec: bookings › Balance is the outstanding amount
test("subtracts payments", () => { ... });
```

A rule whose heading ends in `(manual)`, or a change with `tdd: manual`, is
checked in the running app instead. A fix or spec update that grows past 8
source files is held once so the agent can propose a change instead.

## Permissions and project rules

**Permissions.** `/permissions` switches between:

| Mode | Behavior |
| --- | --- |
| `ask` | Confirm sensitive actions |
| `auto` | A security review decides |
| `full-access` | No fx checks |

`fx ask --auto` or `--full-access` apply to a single run.

**Project rules.** fx reads `AGENTS.md` at the project root, plus
`~/.fx/AGENTS.md` for rules that apply everywhere. Keep it short: what the app
is, the stack, and conventions the code doesn't show (reply language, package
manager, where tests live).

## Where settings live

| What | Where | Override |
| --- | --- | --- |
| Provider keys, Jev key | macOS Keychain (`fx login`, `fx jev key`) | `DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`, `TYPESAFE_API_KEY`, ... |
| Provider, model, permissions, Jev | `~/.fx/settings.json` | `FX_PROVIDER`, `FX_MODEL`, `FX_PERMISSION_MODE`, `FX_JEV=on\|off` |
| SDD and TDD, per project | `~/.fx/settings.json` → `workspaces["<path>"].sdd` | `FX_SDD=on\|off` |
| Project defaults safe to commit | `<project>/.fx.json` | |
| Sessions and Jev's decision log | `~/.fx/sessions/<id>/` (`decisions.jsonl`) | |

Outside macOS, saved keys go to an owner-only file under `~/.fx/provider-keys`.
Jev and SDD settings live only in your profile: a project's `.fx.json` cannot
turn them on.

## Reference

### Build from source

Requires Zig 0.16.0.

```bash
zig build                              # builds zig-out/bin/fx
zig build test                         # runs the unit tests
zig build test -Dtest-filter="preset"  # runs a subset
./zig-out/bin/fx                       # starts an interactive session
```

### Provider fields

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

### Jev settings

Under `jev` in `~/.fx/settings.json`:

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
| `thresholds.stop` | Minimum probability each completion check must reach (default `0.5`) |
| `routing.<name>` | `model`, optional `effort`, and `description` for a subagent route |

`TYPESAFE_API_KEY`, `FX_JEV=on|off`, `FX_JEV_MODEL` and `FX_JEV_BASE_URL`
override the saved values.

Routes: `light` and `heavy` have built-in descriptions; other names need a
`description`. Routing needs at least two routes with models from the active
provider.

Drift sources: `sdd/specs` (each `## ` rule checked on its own), or one
Markdown file per decision in `sdd/decisions`, `docs/decisions`, `docs/adr` or
`decisions` (front matter `title`/`status`/`description` optional). Each record
is flagged once per session.

`fx jev eval [stop|plan|action|ask|routing|sdd]` runs labeled cases through the
same questions and thresholds as the live checks, so threshold or model changes
can be tested before use.

### SDD settings

Per workspace in `~/.fx/settings.json` → `workspaces["<path>"].sdd`:
`enabled`, `tdd` (`off`, `on`, `strict`) and `test` (a custom test command).
A top-level `"sdd": {"enabled": true}` sets a default for every workspace.
`FX_SDD=on|off` overrides it for one shell or CI run.

### Web search

The `web_search` tool works with any provider once a search API is set:

| Backend | Variable |
| --- | --- |
| Tavily | `TAVILY_API_KEY` (supports allowed/blocked domains) |
| Brave Search API | `BRAVE_API_KEY` |
| SearXNG (self-hosted, JSON format enabled) | `FX_SEARXNG_URL=http://host:8080` |

With several set, they're preferred in that order; `FX_WEB_SEARCH_BACKEND`
pins one. `web_fetch` works without any setup.

### What changed from upstream fx

- A lenient stream reader tolerates common OpenAI-compatible deviations (tool
  calls finished with `stop`, missing `[DONE]`, unindexed tool deltas, vendor
  finish reasons) while still rejecting unknown tools and malformed arguments.
- Provider presets, reasoning controls and model discovery for configured
  providers.
- Jev decisions and the SDD and TDD processes.
- The Codex and Grok subscription providers were removed.
- Provider keys are saved per preset in the Keychain (`FX_PROVIDER_KEY_<id>`)
  or `~/.fx/provider-keys`.
- `fx upgrade` and automatic upgrades are disabled; use `fx update`.

The original README is kept at [docs/UPSTREAM_README.md](docs/UPSTREAM_README.md).
Parts of it (Vercel login, gateway routing, Slack) do not apply to this fork.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). This fork is not
affiliated with or endorsed by Vercel, Inc.
