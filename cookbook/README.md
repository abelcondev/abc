# libfx cookbook

Small applications built with [libfx](https://fx.sh/docs/lib). Each example keeps
the agent calls in its entry point. Start with the one that matches your runtime.

- [Node.js readline chat](node-chat): one agent, a prompt loop, and streamed text.
- [Browser agent](browser-agent): WebAssembly with a plain HTML form.
- [Next.js App Router](nextjs-agent): a React form and a streaming route handler.
- [Nuxt](nuxt-agent): a Vue form and a streaming Nitro route.

Use Node.js 24 and an [AI Gateway API key](https://vercel.com/docs/ai-gateway/authentication-and-byok).
The examples pin libfx 0.0.8. They do not use the CLI's built-in tools.

## Run an example

Clone this repository, then open the example directory:

```sh
git clone https://github.com/vercel-labs/fx.git
cd fx/cookbook/node-chat
npm install
```

Create `.env.local` in that directory:

```sh
AI_GATEWAY_API_KEY=your-key
```

Run `npm run chat` for the readline example. Type `/exit` to quit.
Run `npm run dev` for its browser demo, Next.js, or Nuxt. Those web handlers start
a new agent per request; the readline and browser WebAssembly examples keep one
conversation open.

For the browser example, run `npx vercel dev` from `browser-agent/`. This runs Vite
and the local `/api/gateway` function together. `npm run dev` by itself serves only
the frontend. WebAssembly needs a browser with [JSPI support](https://fx.sh/docs/lib/webassembly#check-runtime-support).

Keep the sibling `shared/` directory when copying a web example. It contains the
public-demo model and transport policy, not another agent framework.

## Deploy a public demo

Create a Vercel project for each example, with its directory as the project root.
Enable **Include source files outside of the Root Directory in the Build Step**
so the project can load `cookbook/shared/`. Use Node.js 24.

Set `AI_GATEWAY_API_KEY` as a server-only environment variable. Use a dedicated
Gateway key with a daily budget. Never place a provider credential in a browser
bundle or a `NEXT_PUBLIC_` variable.

Before making the demo public, configure a Vercel Firewall rule that rate-limits
`POST /api/*` by IP. The hosted examples use 10 requests per minute per project.
The shared transport restricts generation to GPT-4.1 nano, 512 output tokens, a
32 KiB request body, and a 30-second timeout. The key budget is the shared spend
boundary; the last in-flight requests may finish after it is reached.

These guards protect anonymous demos. Replace them with your app's authentication
and usage policy when adapting the examples.

## Tests

From the repository root:

```sh
node --test cookbook/shared/gateway.test.mjs
```

Build the browser, Next.js, and Nuxt examples with `npm run build` in their
directories. Run each example with a real key before publishing changes.
