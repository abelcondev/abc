```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent CLI written in Zig: a small native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal.

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Get started

Sign in with one of:

- `fx login`: Vercel AI Gateway
- `fx login codex`: ChatGPT subscription (OpenAI Codex OAuth)
- `fx login grok`: Grok subscription (xAI OAuth)
- `fx setup`: AI Gateway API key

Then start the interactive shell from a project:

```bash
cd your_project
fx
```

Or make a one-shot request:

```bash
fx ask "explain the changes in this repository"
```

Inside the shell, run `/help` to browse interactive commands.

## Documentation

The full manual lives at [fx.sh/docs](https://fx.sh/docs). Start from the page that matches what you are doing:

| I want to... | Read |
| --- | --- |
| Install, sign in, run a first session | [Quick start](https://fx.sh/docs), [Installation](https://fx.sh/docs/getting-started/installation), [Authentication](https://fx.sh/docs/getting-started/authentication) |
| Save, resume, and compact conversations | [Sessions](https://fx.sh/docs/using-fx/sessions) |
| Look up a command or flag | [CLI reference](https://fx.sh/docs/using-fx/cli), [Slash commands](https://fx.sh/docs/using-fx/slash-commands) |
| Pick or change models | [Models](https://fx.sh/docs/configure-fx/models) |
| Use Ollama, OpenRouter, or another OpenAI-compatible endpoint | [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) |
| Control tool permissions and automatic review | [Permissions](https://fx.sh/docs/configure-fx/permissions) |
| Configure settings and environment variables | [Configuration](https://fx.sh/docs/configure-fx/configuration) |
| Add skills, MCP servers, or subagents | [Skills](https://fx.sh/docs/capabilities/skills), [MCP](https://fx.sh/docs/capabilities/mcp), [Subagents](https://fx.sh/docs/capabilities/subagents) |
| Embed fx in an app or editor | [Embedding fx](https://fx.sh/docs/lib), [ACP server](https://fx.sh/docs/using-fx/acp) |

Agents can read any page as Markdown by appending `.md` to its URL, or fetch the [combined documentation file](https://fx.sh/llms-full.txt) ([index](https://fx.sh/llms.txt)).

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama and gateways such as OpenRouter, in `~/.fx/settings.json`, then select one for the profile or a single invocation:

```bash
fx provider local
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx ask "review this change"
```

See [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) for connection JSON, model metadata, and behavior details.

## MCP forms

In the interactive shell, an MCP form with a single select-one field and up to three options submits in the same prompt; every other form keeps a separate review step. See [MCP](https://fx.sh/docs/capabilities/mcp) for server setup.

## Themes

fx ships with `fx-dark` and `fx-light` and follows your terminal's light or dark mode. Pin a variant with `FX_THEME=light` or `FX_THEME=dark`, or drop a VS Code format theme at `~/.fx/themes/<name>.json` and select it with `FX_THEME=<name>`. See [Configuration](https://fx.sh/docs/configure-fx/configuration) for all environment variables.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The SDK is published to npm as [libfx](https://www.npmjs.com/package/libfx). See the [WebAssembly SDK](sdk/README.md) and the runnable Node.js, browser, Next.js, and Nuxt [examples](examples/README.md). The WebAssembly SDK is experimental.

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
