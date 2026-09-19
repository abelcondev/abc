import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { contentText, isRuntimeOverlayMessage } from "./conditional-guidance-oracle";
import { fakeGatewayFinalText, fakeGatewayToolCall, startDynamicFakeGateway } from "./tmux-helpers";

// Prompt-cache stability contract for gateway models. fx advertises
// providerOptions.gateway.caching="auto"; provider-side caching reuses the
// longest unchanged leading span of the request, so per-step volatile runtime
// context must ride at the END of the message list. If it ever moves back
// into the leading instruction prefix, a mid-turn change (like the git
// worktree flipping dirty after fx edits a file) silently invalidates the
// entire conversation history cache and every later step re-processes it.

const MODEL = "openai/gpt-5";
const TIMEOUT = 30_000;

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function createGitWorkspace() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-prompt-cache-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  // Keep the index at or below 32 entries so fx's bounded dirty check is
  // active: this is the path where an fx edit flips git_worktree to dirty.
  writeFileSync(join(workspace, "tracked.txt"), "ORIGINAL_CONTENT\n");
  execFileSync("git", ["init", "-q"], { cwd: workspace });
  execFileSync("git", ["config", "user.email", "fx-e2e@example.com"], { cwd: workspace });
  execFileSync("git", ["config", "user.name", "fx-e2e"], { cwd: workspace });
  execFileSync("git", ["add", "tracked.txt"], { cwd: workspace });
  execFileSync("git", ["commit", "-qm", "init"], { cwd: workspace });
  roots.push(root);
  return { home, workspace: realpathSync(workspace) };
}

type CapturedMessage = { role: string; content?: unknown };
type CapturedRequest = {
  prompt: CapturedMessage[];
  tools?: unknown;
  providerOptions?: { gateway?: { caching?: string } };
};

function messageKey(message: CapturedMessage): string {
  return JSON.stringify(message);
}

function messageText(message: CapturedMessage): string {
  return contentText(message.content);
}

const isRuntimeContextMessage = isRuntimeOverlayMessage;

// The previous request with its trailing runtime-context messages removed
// must be an exact leading prefix of the next request: only the volatile tail
// and newly appended step messages may differ.
function expectCachePrefixPreserved(
  previous: CapturedMessage[],
  current: CapturedMessage[],
) {
  let tail = previous.length;
  while (tail > 0 && isRuntimeContextMessage(previous[tail - 1])) tail--;
  const overlayCount = previous.length - tail;
  expect(overlayCount).toBeGreaterThan(0);
  for (const message of previous.slice(tail)) {
    expect(message.role).toBe("user");
  }
  const stablePrefix = previous.slice(0, tail).map(messageKey);
  const currentHead = current.slice(0, tail).map(messageKey);
  expect(currentHead).toEqual(stablePrefix);
  // Runtime context stays out of the leading system instruction block.
  expect(current.slice(0, tail).some(isRuntimeContextMessage)).toBe(false);
}

async function runEditTurn(): Promise<CapturedRequest[]> {
  const fixture = createGitWorkspace();
  const agentRequests: CapturedRequest[] = [];
  const gateway = startDynamicFakeGateway((raw) => {
    const body = JSON.parse(raw);
    if (Array.isArray(body.prompt) && body.prompt.length > 2) {
      agentRequests.push(body as CapturedRequest);
    }
    const toolMessages = (raw.match(/"role":"tool"/g) ?? []).length;
    if (toolMessages === 0) {
      return fakeGatewayToolCall("call_write", "write_file", {
        path: "tracked.txt",
        content: "WROTE_TRACKED_CONTENT\n",
      });
    }
    if (toolMessages === 1) {
      return fakeGatewayToolCall("call_read", "read_file", { path: "tracked.txt" });
    }
    return fakeGatewayFinalText("done");
  });
  gateways.push(gateway);

  const result = await runFx(["ask", "Update tracked.txt then read it back"], {
    cwd: fixture.workspace,
    timeoutMs: TIMEOUT,
    env: {
      HOME: fixture.home,
      AI_GATEWAY_API_KEY: "fake-prompt-cache-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: MODEL,
      FX_PERMISSION_MODE: "full-access",
      FX_AUTO_UPGRADE: "0",
      FX_SOUND: "0",
      NO_COLOR: "1",
    },
  });
  expect(result.code).toBe(0);
  expect(agentRequests.length).toBeGreaterThanOrEqual(3);
  return agentRequests;
}

test("gateway requests advertise auto prompt caching with byte-stable tools", async () => {
  const requests = await runEditTurn();
  for (const request of requests) {
    expect(request.providerOptions?.gateway?.caching).toBe("auto");
  }
  const toolJson = requests.map((request) => JSON.stringify(request.tools ?? []));
  for (const tools of toolJson.slice(1)) {
    expect(tools).toBe(toolJson[0]);
  }
});

test("mid-turn git dirty flip preserves the cached history prefix", async () => {
  const requests = await runEditTurn();

  // The fixture's write_file must actually flip the worktree state, otherwise
  // the prefix assertions below are vacuous.
  const sawDirtyFlip = requests.some((request, index) => {
    if (index === 0) return false;
    const before = requests[index - 1].prompt.map(messageText).join("\n");
    const after = request.prompt.map(messageText).join("\n");
    return before.includes("git_worktree: unknown") && after.includes("git_worktree: dirty");
  });
  expect(sawDirtyFlip).toBe(true);

  for (let i = 1; i < requests.length; i++) {
    expectCachePrefixPreserved(requests[i - 1].prompt, requests[i].prompt);
  }
});
