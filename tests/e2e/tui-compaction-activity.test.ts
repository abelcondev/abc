import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// The shared tmux helper imports eval helpers; do not load repository dotenv files.
process.env.FX_E2E_DISABLE_DOTENV = "1";
const {
  FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewayFinalText,
  heldFakeGatewayFinalText, startDynamicFakeGateway, hasEmptyComposer,
  tmuxAvailable,
} = await import("./tmux-helpers");

const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const HEAD = "HISTORY_HEAD_29b7";
const TAIL = "HISTORY_TAIL_16d3";
const HANDOFF = `INTERNAL_HANDOFF_4e12: preserve ${HEAD} and ${TAIL}; follow the latest user request.`;
const FOLLOWUP = "FOLLOWUP_OK_732c";
const REOPEN = "REOPEN_OK_492a";
const ACTIVITY = /Compacting \((?:\d+h)?(?:\d+m)?\d+s\)/;
const COMPACTION_OUTPUT = /Compacting|compaction|Context compacted|No context to compact|Your existing context was kept|Synthetic summary rejection|INTERNAL_HANDOFF_4e12/i;

type Trigger = "manual" | "auto" | "overflow" | "ordinary";
type Outcome = "success" | "cancel" | "empty" | "provider-error";

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function checkpoints(bytes: Buffer): number {
  return bytes.toString().trim().split("\n").filter(Boolean)
    .map((line) => JSON.parse(line)).filter((frame) => frame.event?.context_checkpoint).length;
}

async function until(predicate: () => boolean, label: string, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await Bun.sleep(20);
  }
}

async function fixture(trigger: Trigger, outcome: Outcome = "success", longResume = false) {
  // Ctrl+O includes the recording path; keep it free of forbidden notice words.
  const root = mkdtempSync(join(tmpdir(), "fx-activity-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
    model: FAKE_GATEWAY_MODEL, auto_upgrade: false, startup_scrollback: false,
  }));
  // Failure attempts need an older exchange outside the retained suffix, but
  // must leave the next ordinary request below the automatic pressure threshold.
  const seedTurns = trigger === "manual" && outcome !== "success" ? 3 : 1;
  const lines = seedTurns > 1 ? 400 : trigger === "ordinary" ? 2 : trigger === "auto" || longResume ? 18_000 : 1600;
  const seedReply = (turn: number) => `${turn === 1 ? HEAD : `HISTORY_MIDDLE_${turn}`}\n${"history alpha beta gamma delta sample line\n".repeat(lines)}SEED_DONE_${turn}${turn === seedTurns ? `\n${TAIL}` : ""}`;
  const summaryHold = heldFakeGatewayFinalText();
  const ordinaryHold = heldFakeGatewayFinalText();
  let phase: "seed" | "attempt" | "followup" | "reopen" = "seed";
  let summaries = 0;
  let ordinary = 0;
  let overflowSent = false;
  let terminal: InstanceType<typeof TmuxSession> | undefined;
  const requests: object[] = [];
  const gateway = startDynamicFakeGateway((raw) => {
    const request = JSON.parse(raw);
    const summary = request.toolChoice?.type === "none" && request.tools?.length === 0;
    requests.push({ phase, summary, at: Date.now(), bytes: raw.length,
      head: raw.includes(HEAD), tail: raw.includes(TAIL), handoff: raw.includes("INTERNAL_HANDOFF_4e12"),
      followup: raw.includes("Follow the latest request.") || raw.includes("Recover with another request."),
      reopen: raw.includes("Continue after reopening.") || raw.includes("Check the reopened context."),
    });
    if (summary) {
      summaries++;
      if (phase === "attempt" && outcome === "provider-error") {
        return Response.json({ error: { message: "Synthetic summary rejection" } }, { status: 400 });
      }
      if (phase === "attempt" && summaries === 1) return summaryHold.response;
      // Each chunk/retry needs a fresh Response, not a consumed held body.
      return fakeGatewayFinalText(phase === "attempt" && outcome === "empty" ? "" : HANDOFF);
    }
    ordinary++;
    if (phase === "seed") return fakeGatewayFinalText(seedReply(ordinary));
    if (phase === "attempt") {
      if (trigger === "overflow" && !overflowSent) {
        overflowSent = true;
        return Response.json({ error: {
          type: "invalid_request_error", code: "context_length_exceeded",
          message: "This model's maximum context length is 128000 tokens. The request exceeds the context window.",
        } }, { status: 400 });
      }
      return ordinaryHold.response;
    }
    return fakeGatewayFinalText(phase === "reopen" ? REOPEN : FOLLOWUP);
  }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    TERM: "xterm-256color", AI_GATEWAY_API_KEY: "synthetic-compaction-key",
    FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_SKIP_ONBOARDING: "1",
    FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  let sessionId = "";
  let eventsPath = "";
  let initial = Buffer.alloc(0);
  let launchIndex = 0;
  const stderrPaths: string[] = [];
  const tapes: string[] = [];
  async function cli(args: string[]) {
    const child = Bun.spawn([binary, ...args], { cwd: workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => child.kill(), 30_000);
    try {
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      expect(code).toBe(0);
      expect(stderr).toBe("");
      return JSON.parse(stdout);
    } finally { clearTimeout(timer); }
  }
  async function launch() {
    const tape = join(root, `terminal-${++launchIndex}.fxtape`);
    const stderr = join(root, `terminal-${launchIndex}.stderr`);
    tapes.push(tape);
    stderrPaths.push(stderr);
    const terminalEnv = { ...env, FX_RECORD: tape, FX_DEBUG_RECORD_SILENT_BANNER: "1",
      FX_TRACE_LOG: join(root, `terminal-${launchIndex}.trace`),
      FX_TRACE_SCOPES: "input,worker,session,scroll,agent,gateway,compaction",
    };
    // Do not inherit provider overrides, credentials, shell startup or dotenv state.
    const command = `/usr/bin/env -i ${Object.entries(terminalEnv).map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)} --resume ${shellQuote(sessionId)}`;
    terminal = await TmuxSession.create({
      cmd: command, cwd: workspace, env: { HOME: home, FX_SOUND: "0" }, isolated: true,
      stderrPath: stderr, width: 90, height: 32, minimumHistoryLines: 25_000,
      startupWaitMs: 0,
    });
    // A composer can be painted while resume history is still being restored.
    // Wait for a stable frame, then acknowledge input without submitting a turn
    // or retiring the retained resume transcript before the tested /compact.
    await terminal.waitForStableComposer(20_000);
    await terminal.sendLiteral("startup-input-handshake");
    await terminal.waitForText("startup-input-handshake", 5000);
    await terminal.sendKeys("C-u");
    await terminal.waitForComposer(5000);
    return terminal;
  }
  function durable() {
    const bytes = readFileSync(eventsPath);
    expect(bytes.subarray(0, initial.length).equals(initial)).toBe(true);
    return checkpoints(bytes);
  }
  async function close() {
    if (!terminal) return;
    expect(terminal.paneStatus()).toEqual({ dead: false, status: null });
    await terminal.sendText("/quit");
    expect(await terminal.waitForSessionEnd(5000)).toBe(true);
    await terminal.kill();
    terminal = undefined;
    for (const path of stderrPaths) expect(readFileSync(path, "utf8")).toBe("");
  }
  async function cleanup(passed: boolean) {
    if (!passed) {
      writeFileSync(join(root, "requests.json"), JSON.stringify({
        trigger, outcome, phase, seedTurns, summaries, ordinary, overflowSent, requests,
        paneStatus: terminal?.paneStatus(),
      }, null, 2));
      if (terminal) writeFileSync(join(root, "failure.scrollback.ansi"), await terminal.captureFullScrollbackEscapes());
      console.error(`compaction evidence retained: ${root}; phase=${phase}, summaries=${summaries}, ordinary=${ordinary}`);
    }
    summaryHold.dispose();
    ordinaryHold.dispose();
    await terminal?.kill();
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
  }
  try {
    for (let turn = 1; turn <= seedTurns; turn++) {
      const reply = await cli(["ask", "--json", "--auto", ...(sessionId ? ["--resume", sessionId] : []), `Seed ordinary historical turn ${turn}.`]);
      if (sessionId) expect(reply.session_id).toBe(sessionId);
      else sessionId = reply.session_id;
      expect(sessionId).toBeTruthy();
      expect(ordinary).toBe(turn);
      expect(summaries).toBe(0);
    }
    eventsPath = join(home, ".fx/sessions", sessionId, "events.jsonl");
    initial = readFileSync(eventsPath);
    expect(initial.toString()).toContain(HEAD);
    expect(initial.toString()).toContain(TAIL);
    expect(checkpoints(initial)).toBe(0);
    expect(summaries).toBe(0);
    expect(ordinary).toBe(seedTurns);
    phase = "attempt";
    return {
      launch, close, cleanup, durable, cli, tapes, root, seedTurns, summaryHold, ordinaryHold,
      counts: () => ({ summaries, ordinary, overflowSent }),
      phase: (value: typeof phase) => { phase = value; },
      lastRequest: () => gateway.requests.at(-1)!.body,
    };
  } catch (error) { await cleanup(false); throw error; }
}

async function assertSilent(terminal: InstanceType<typeof TmuxSession>, root: string, label: string) {
  const inline = await terminal.captureFullScrollbackEscapes();
  writeFileSync(join(root, `${label}.scrollback.ansi`), inline);
  expect(inline.length).toBeGreaterThan(0);
  expect(inline).not.toMatch(COMPACTION_OUTPUT);
  await terminal.sendKeys("C-o");
  await terminal.waitForText("Full detail", 5000);
  await terminal.sendKeys("End");
  const full = await terminal.waitForPane((pane) => pane.includes("Full detail"), 5000);
  writeFileSync(join(root, `${label}.full-transcript.txt`), full);
  expect(full).not.toMatch(COMPACTION_OUTPUT);
  await terminal.sendKeys("C-o");
  await terminal.waitForComposer(5000);
}

async function assertLive(terminal: InstanceType<typeof TmuxSession>) {
  const first = await terminal.waitForText(ACTIVITY, 10_000);
  const clock = first.match(ACTIVITY)![0];
  const markers = new Set<boolean>();
  const later = await terminal.waitForPane((pane) => {
    const rows = pane.split("\n").filter((line) => ACTIVITY.test(line));
    if (rows.length === 0) return false;
    expect(rows).toHaveLength(1);
    expect(rows[0]).not.toMatch(/[↑↓]|tokens|chunk|%/i);
    markers.add(rows[0].includes("•"));
    return markers.size === 2 && !rows[0].includes(clock);
  }, 5000);
  expect(later.match(/Compacting/g)).toHaveLength(1);
}

describe.skipIf(!tmuxAvailable())("tui: compaction activity", () => {
  for (const trigger of ["manual", "auto", "overflow"] as const) {
    test(`${trigger}: held summary is transient, commits once released, and resumes ordinary work`, async () => {
      const f = await fixture(trigger, "success", trigger === "manual");
      let passed = false;
      try {
        const terminal = await f.launch();
        // First interaction after a long resume; do not retire the resume source with a prompt.
        await terminal.sendText(trigger === "manual" ? "/compact" : "Continue the current turn.");
        await until(() => f.counts().summaries === 1, "first summary request");
        await assertLive(terminal);
        expect(f.durable()).toBe(0);
        expect(f.counts().ordinary).toBe(f.seedTurns + (trigger === "overflow" ? 1 : 0));
        if (trigger === "manual") {
          await terminal.sendKeys("C-o");
          await terminal.waitForText("Full detail", 5000);
          expect(await terminal.capturePane()).not.toMatch(COMPACTION_OUTPUT);
          await terminal.sendKeys("C-o");
          await terminal.waitForText(ACTIVITY, 5000);
          await terminal.resizeWindow(52, 24);
          await terminal.waitForText(ACTIVITY, 5000);
          await terminal.resizeWindow(90, 32);
        }
        f.summaryHold.release(HANDOFF);
        await until(() => f.durable() > 0, "acknowledged checkpoint");
        if (trigger === "manual") {
          await terminal.waitForPane((pane) => !ACTIVITY.test(pane) && hasEmptyComposer(pane), 10_000);
          expect(f.counts().ordinary).toBe(f.seedTurns);
          expect(f.counts().summaries).toBeGreaterThan(1);
        } else {
          await until(() => f.counts().ordinary === f.seedTurns + (trigger === "overflow" ? 2 : 1), "ordinary request after compaction");
          const pane = await terminal.waitForText(/Thinking \(/, 10_000);
          expect(pane).not.toMatch(ACTIVITY);
          expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
          f.ordinaryHold.release("CURRENT_TURN_OK_f713");
          await terminal.waitForPane((pane) => pane.includes("CURRENT_TURN_OK_f713") && hasEmptyComposer(pane), 10_000);
        }
        expect(f.counts().overflowSent).toBe(trigger === "overflow");
        expect(f.durable()).toBe(1);
        const before = f.counts();
        f.phase("followup");
        await terminal.sendText("Follow the latest request.");
        await terminal.waitForPane((pane) => pane.includes(FOLLOWUP) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...before, ordinary: before.ordinary + 1 });
        expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
        await assertSilent(terminal, f.root, "completed");
        await f.close();
        f.phase("reopen");
        const reopened = await f.launch();
        await reopened.sendText("Continue after reopening.");
        await reopened.waitForPane((pane) => pane.includes(REOPEN) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...before, ordinary: before.ordinary + 2 });
        expect(f.durable()).toBe(1);
        expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
        await assertSilent(reopened, f.root, "reopened");
        await f.close();
        for (const tape of f.tapes) {
          const replay = await f.cli(["replay", tape, "--json"]);
          expect(replay.frame_count).toBeGreaterThan(0);
          expect(replay.stdout_bytes).toBeGreaterThan(0);
        }
        passed = true;
      } finally { await f.cleanup(passed); }
    }, 120_000);
  }

  for (const outcome of ["cancel", "empty", "provider-error"] as const) {
    test(`manual ${outcome}: scoped feedback preserves history and permits later input and reopen`, async () => {
      const f = await fixture("manual", outcome);
      let passed = false;
      try {
        const terminal = await f.launch();
        await terminal.sendText("/compact");
        await until(() => f.counts().summaries > 0, "summary boundary");
        if (outcome !== "provider-error") {
          await assertLive(terminal);
          expect(f.durable()).toBe(0);
          if (outcome === "cancel") await terminal.sendKeys("Escape");
          else f.summaryHold.release("");
        }
        const feedback = outcome === "cancel"
          ? "Compaction cancelled. Try /compact again when ready."
          : "Compaction failed. Try /compact again.";
        await terminal.waitForPane((pane) => !ACTIVITY.test(pane) && pane.includes(feedback) && hasEmptyComposer(pane), 15_000);
        expect(f.durable()).toBe(0);
        expect(f.counts().ordinary).toBe(f.seedTurns);
        expect(f.counts().summaries).toBe(outcome === "empty" ? 2 : 1);
        const afterFailure = f.counts();
        if (outcome === "cancel") f.summaryHold.dispose();
        await terminal.sendKeys("Escape");
        await terminal.waitForPane((pane) => !/compact/i.test(pane) && hasEmptyComposer(pane), 5000);
        await assertSilent(terminal, f.root, "failed");
        f.phase("followup");
        await terminal.sendText("Recover with another request.");
        await terminal.waitForPane((pane) => pane.includes(FOLLOWUP) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...afterFailure, ordinary: f.seedTurns + 1 });
        expect(f.lastRequest()).toContain(HEAD);
        expect(f.lastRequest()).toContain(TAIL);
        expect(f.lastRequest()).not.toContain("INTERNAL_HANDOFF_4e12");
        expect(f.durable()).toBe(0);
        await f.close();
        f.phase("reopen");
        const reopened = await f.launch();
        await reopened.sendText("Check the reopened context.");
        await reopened.waitForPane((pane) => pane.includes(REOPEN) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...afterFailure, ordinary: f.seedTurns + 2 });
        expect(f.lastRequest()).toContain(HEAD);
        expect(f.lastRequest()).toContain(TAIL);
        expect(f.lastRequest()).not.toContain("INTERNAL_HANDOFF_4e12");
        expect(f.durable()).toBe(0);
        await assertSilent(reopened, f.root, "failed-reopen");
        await f.close();
        passed = true;
      } finally { await f.cleanup(passed); }
    }, 90_000);
  }

  test("ordinary held request remains Thinking without compaction or extra requests", async () => {
    const f = await fixture("ordinary");
    let passed = false;
    try {
      const terminal = await f.launch();
      await terminal.sendText("Ordinary control request.");
      await until(() => f.counts().ordinary === 2, "ordinary held request");
      await terminal.waitForText(/Thinking \(/, 5000);
      expect(f.counts().summaries).toBe(0);
      expect(f.durable()).toBe(0);
      f.ordinaryHold.release("ORDINARY_CONTROL_OK_727a");
      await terminal.waitForPane((pane) => pane.includes("ORDINARY_CONTROL_OK_727a") && hasEmptyComposer(pane), 10_000);
      expect(f.counts().ordinary).toBe(2);
      await assertSilent(terminal, f.root, "control");
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 60_000);
});
