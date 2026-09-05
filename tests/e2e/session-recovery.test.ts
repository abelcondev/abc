import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;

function savedFileHashes(root: string): Record<string, string> {
  const hashes: Record<string, string> = {};
  function visit(directory: string, prefix = "") {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.name === "session.lock") continue;
      const relative = join(prefix, entry.name);
      if (entry.isDirectory()) visit(join(directory, entry.name), relative);
      else hashes[relative] = createHash("sha256")
        .update(readFileSync(join(directory, entry.name)))
        .digest("hex");
    }
  }
  visit(root);
  return hashes;
}

function createFixture(prefix: string) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  return {
    root,
    home: realpathSync(home),
    workspace: realpathSync(workspace),
  };
}

function gatewayEnv(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "session-recovery-test-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
  };
}

async function createSavedSession(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
): Promise<string> {
  const created = await runFx(
    ["ask", "--json", "--auto", "Create the first saved turn."],
    {
      cwd: fixture.workspace,
      env: gatewayEnv(fixture, gateway),
      timeoutMs: TIMEOUT,
    },
  );
  expect(created.code).toBe(0);
  expect(created.stderr).toBe("");
  return JSON.parse(created.stdout).session_id;
}

async function continueSession(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
  sessionId: string,
  latest = false,
) {
  return runFx(
    [
      "ask",
      "--json",
      "--auto",
      ...(latest ? ["--resume", "last"] : ["--resume-id", sessionId]),
      "Continue after recovery.",
    ],
    {
      cwd: fixture.workspace,
      env: gatewayEnv(fixture, gateway),
      timeoutMs: TIMEOUT,
    },
  );
}

describe("session recovery", () => {
  test("healthy current conversation needs no recovery or migration", async () => {
    const fixture = createFixture("fx-session-current-healthy-");
    const gateway = startFakeGateway([fakeGatewayFinalText("SAVED_HEALTHY")]);
    try {
      const id = await createSavedSession(fixture, gateway);
      const source = join(fixture.home, ".fx", "sessions", id);
      const before = savedFileHashes(source);
      const result = await runFx(["session", "recover", id, "--json"], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(result.code).toBe(1);
      expect(result.stderr).toBe("");
      expect(JSON.parse(result.stdout).code).toBe("SessionRecoveryNotNeeded");
      expect(savedFileHashes(source)).toEqual(before);
      expect(readdirSync(join(fixture.home, ".fx", "sessions"))).toEqual([id]);
      expect(gateway.requests).toHaveLength(1);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  for (const { checkpointedTurn, missingUsage, fullCoverage } of [
    { checkpointedTurn: false, missingUsage: false, fullCoverage: false },
    { checkpointedTurn: true, missingUsage: false, fullCoverage: false },
    { checkpointedTurn: false, missingUsage: true, fullCoverage: false },
    { checkpointedTurn: false, missingUsage: false, fullCoverage: true },
  ]) {
    test(`current conversation recovery preserves exact checkpoints and artifacts with open=${checkpointedTurn} missing usage=${missingUsage} full coverage=${fullCoverage}`, async () => {
      const fixture = createFixture("fx-session-current-copy-");
      const responses = [
        fakeShellRun("saved-effect", "printf 'ONCE_RECOVERY_731\\n' >> effect.log; printf 'RESULT_RECOVERY_982\\n'"),
        fakeGatewayFinalText("WORK_SAVED"),
      ];
      const gateway = startFakeGateway(responses);
      try {
        const created = await runFx(["ask", "--json", "--full-access", "Save one command result."], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(created.code).toBe(0);
        const id = JSON.parse(created.stdout).session_id;
        const source = join(fixture.home, ".fx", "sessions", id);
        const eventPath = join(source, "events.jsonl");
        const metadataPath = join(source, "session.json");
        const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
        metadata.title = "Recovered work keeps its chosen title";
        writeFileSync(metadataPath, JSON.stringify(metadata), { mode: 0o600 });
        if (missingUsage) rmSync(join(source, "usage-v2.json"));
        const records = readFileSync(eventPath, "utf8").trimEnd().split("\n").map(JSON.parse);
        if (fullCoverage) records[0].event.user.work_id = "covered-recovery-work";
        const stored = records.find((record) => record.event.tool_result).event.tool_result;
        const coverage = fullCoverage ? records[records.length - 1].seq : 1;
        const append = (event: object) => records.push({
          schema_version: 1, seq: records.length + 1, timestamp_ms: Date.now(), event,
        });
        append({ context_checkpoint: { covers_through_seq: coverage, summary: "<context_handoff>Saved command completed.</context_handoff>" } });
        append({ context_checkpoint: { covers_through_seq: coverage, summary: "<context_handoff>Retain the completed command and its result.</context_handoff>" } });
        if (checkpointedTurn) {
          append({ user: { text: "Keep the already completed stored read.", work_id: "checkpointed-recovery-work" } });
          append({ tool_call: { call_id: "checkpointed-read", tool_name: "read_tool_result", arguments_json: JSON.stringify({ handle: stored.artifact_ref }) } });
          append({ tool_result: { ...stored, call_id: "checkpointed-read", tool_name: "read_tool_result" } });
          append({ context_checkpoint: { covers_through_seq: 1, summary: "<context_handoff>Checkpointed read is already complete.</context_handoff>" } });
        }
        const prefix = records.map((record) => JSON.stringify(record)).join("\n") + "\n";
        writeFileSync(eventPath, prefix + "invalid CORRUPT_TAIL_MUST_NOT_REPLAY\n", { mode: 0o600 });
        const before = savedFileHashes(source);
        const recovered = await runFx(["session", "recover", id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(recovered.code).toBe(0);
        expect(recovered.stderr).toBe("");
        const result = JSON.parse(recovered.stdout);
        expect(result).toMatchObject({ kind: "session_recovery", source_id: id, status: "recovered" });
        expect(result.recovered_id).not.toBe(id);
        expect(gateway.requests).toHaveLength(2);
        expect(savedFileHashes(source)).toEqual(before);
        const target = join(fixture.home, ".fx", "sessions", result.recovered_id);
        expect(JSON.parse(readFileSync(join(target, "session.json"), "utf8")).title).toBe(metadata.title);
        const targetEvents = readFileSync(join(target, "events.jsonl"), "utf8");
        expect(targetEvents.startsWith(prefix)).toBe(true);
        expect(targetEvents).not.toContain("CORRUPT_TAIL_MUST_NOT_REPLAY");
        const suffix = targetEvents.slice(prefix.length);
        if (checkpointedTurn) expect(JSON.parse(suffix).event).toEqual({ interrupted: expect.objectContaining({ reason: "failed" }) });
        else expect(suffix).toBe("");
        for (const [path, digest] of Object.entries(before)) {
          if (path.startsWith("tool-results/") || path.startsWith("logs/commands/")) {
            expect(savedFileHashes(target)[path]).toBe(digest);
          }
        }

        responses.push(
          fakeGatewayToolCall("read-recovered", "read_tool_result", { request: { handle: stored.artifact_ref, query: "RESULT_RECOVERY_982" } }),
          fakeGatewayFinalText("RECOVERED_CONTINUATION_SAVED"),
        );
        const tracePath = join(fixture.root, "continue.trace.log");
        const continued = await runFx(["ask", "--json", "--full-access", "--resume-id", result.recovered_id, "Read the retained result. Do not repeat completed commands."], {
          cwd: fixture.workspace,
          env: { ...gatewayEnv(fixture, gateway), FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "tool,session,agent" },
          timeoutMs: TIMEOUT,
        });
        expect(continued.code).toBe(0);
        expect(JSON.parse(continued.stdout)).toMatchObject({ output: "RECOVERED_CONTINUATION_SAVED", tool_calls: [{ name: "read_tool_result", status: "success" }] });
        expect(gateway.requests).toHaveLength(4);
        const executionStarts = readFileSync(tracePath, "utf8").split("\n")
          .filter((line) => line.includes("[tool] event=execution_start "));
        expect(executionStarts).toHaveLength(1);
        expect(executionStarts[0]).toContain("call_id=read-recovered name=read_tool_result");
        const after = readFileSync(join(target, "events.jsonl"), "utf8").trimEnd().split("\n").map(JSON.parse);
        const readResult = after.find((record) => record.event.tool_result?.call_id === "read-recovered").event.tool_result;
        expect(readResult.status).toBe("success");
        expect(readFileSync(join(target, "tool-results", readResult.artifact_ref), "utf8")).toContain("RESULT_RECOVERY_982");
        expect(readFileSync(join(fixture.workspace, "effect.log"), "utf8")).toBe("ONCE_RECOVERY_731\n");
        expect(savedFileHashes(source)).toEqual(before);
        const inspected = await runFx(["session", "--id", result.recovered_id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(inspected.code).toBe(0);
        expect(inspected.stderr).toBe("");
        expect(inspected.stdout).toContain("RECOVERED_CONTINUATION_SAVED");
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  for (const tail of ["", "invalid tail\n"]) {
    test(`current recovery excludes checkpoint splitting a call/result pair with tail=${tail.length > 0}`, async () => {
      const fixture = createFixture("fx-session-current-cut-");
      const responses = [fakeShellRun("cut-call", "printf 'CUT_RESULT_619\\n'"), fakeGatewayFinalText("CUT_SAVED")];
      const gateway = startFakeGateway(responses);
      try {
        const created = await runFx(["ask", "--json", "--full-access", "Save one result."], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(created.code).toBe(0);
        const id = JSON.parse(created.stdout).session_id;
        const source = join(fixture.home, ".fx", "sessions", id);
        const eventPath = join(source, "events.jsonl");
        const prefix = readFileSync(eventPath, "utf8");
        const records = prefix.trimEnd().split("\n").map(JSON.parse);
        const callSeq = records.find((record) => record.event.tool_call).seq;
        appendFileSync(eventPath, JSON.stringify({ schema_version: 1, seq: records.at(-1).seq + 1, timestamp_ms: Date.now(), event: {
          context_checkpoint: { covers_through_seq: callSeq, summary: "INVALID_SPLIT_CHECKPOINT" },
        } }) + "\n" + tail);
        const before = savedFileHashes(source);
        const recovered = await runFx(["session", "recover", id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(recovered.code).toBe(0);
        expect(recovered.stderr).toBe("");
        const result = JSON.parse(recovered.stdout);
        expect(result.status).toBe("recovered");
        const target = join(fixture.home, ".fx", "sessions", result.recovered_id);
        expect(readFileSync(join(target, "events.jsonl"), "utf8")).toBe(prefix);
        expect(savedFileHashes(source)).toEqual(before);
        const inspected = await runFx(["session", "--id", result.recovered_id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(inspected.code).toBe(0);
        expect(inspected.stderr).toBe("");
        expect(inspected.stdout).toContain("CUT_SAVED");
        responses.push(fakeGatewayFinalText("CUT_CONTINUED"));
        const continued = await continueSession(fixture, gateway, result.recovered_id);
        expect(continued.code).toBe(0);
        expect(JSON.parse(continued.stdout).output).toBe("CUT_CONTINUED");
        expect(gateway.requests).toHaveLength(3);
        expect(savedFileHashes(source)).toEqual(before);
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  for (const damage of ["metadata", "private-child", "private-marker", "first-record", "missing-result", "changed-result"] as const) {
    test(`current conversation recovery refuses ${damage} without publishing a copy`, async () => {
      const fixture = createFixture("fx-session-current-refusal-");
      const gateway = startFakeGateway([
        fakeShellRun("retained-result", "printf 'REQUIRED_RESULT_619\\n'"),
        fakeGatewayFinalText("RESULT_SAVED"),
      ]);
      try {
        const created = await runFx(["ask", "--json", "--full-access", "Save a result."], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(created.code).toBe(0);
        const id = JSON.parse(created.stdout).session_id;
        const source = join(fixture.home, ".fx", "sessions", id);
        const eventPath = join(source, "events.jsonl");
        const committed = readFileSync(eventPath, "utf8");
        if (damage === "metadata" || damage === "private-child") {
          const metadataPath = join(source, "session.json");
          const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
          if (damage === "metadata") metadata.id = "different-session";
          else metadata.subagent_child = true;
          writeFileSync(metadataPath, JSON.stringify(metadata), { mode: 0o600 });
        } else if (damage === "private-marker") {
          mkdirSync(join(source, "subagent"), { recursive: true, mode: 0o700 });
          writeFileSync(join(source, "subagent", "owner.json"), "{}", { mode: 0o600 });
          appendFileSync(eventPath, "invalid tail\n");
        } else if (damage === "first-record") {
          writeFileSync(eventPath, "[" + committed.slice(1), { mode: 0o600 });
        } else {
          appendFileSync(eventPath, "invalid tail\n");
          const record = committed.trimEnd().split("\n").map(JSON.parse)
            .find((frame) => frame.event.tool_result).event.tool_result;
          const artifactPath = join(source, "tool-results", record.artifact_ref);
          if (damage === "missing-result") rmSync(artifactPath);
          else {
            const bytes = readFileSync(artifactPath);
            bytes[0] ^= 1;
            writeFileSync(artifactPath, bytes);
          }
        }
        const before = savedFileHashes(source);
        const result = await runFx(["session", "recover", id, "--json"], {
          cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(1);
        expect(result.stderr).toBe("");
        expect(JSON.parse(result.stdout).code).toBe(damage === "private-child" || damage === "private-marker" ? "SessionNotFound" : "SessionRecoveryBoundaryInvalid");
        expect(savedFileHashes(source)).toEqual(before);
        const sessionRoot = join(fixture.home, ".fx", "sessions");
        expect(readdirSync(sessionRoot).filter((name) => existsSync(join(sessionRoot, name, "session.json")))).toEqual([id]);
        expect(gateway.requests).toHaveLength(2);
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  test.skipIf(!tmuxAvailable())("resume picker discovers a checkpoint from an unfinished first turn", async () => {
    const fixture = createFixture("fx-session-first-checkpoint-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
      fakeGatewayFinalText("CHECKPOINT_TURN_RECOVERED"),
    ]);
    let tui: TmuxSession | null = null;
    try {
      const sessionId = await createSavedSession(fixture, gateway);
      const eventsPath = join(fixture.home, ".fx", "sessions", sessionId, "events.jsonl");
      const checkpoint = [
        { user: { text: "unfinished first request", images: [], work_id: null } },
        { context_checkpoint: { covers_through_seq: 1, summary: "<context_handoff>FIRST_CHECKPOINT_FACT</context_handoff>" } },
      ].map((event, index) => JSON.stringify({
        schema_version: 1, seq: index + 1, timestamp_ms: Date.now(), event,
      })).join("\n") + "\n";
      writeFileSync(eventsPath, checkpoint, { mode: 0o600 });
      const listed = await runFx(["sessions", "--json"], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(listed.code).toBe(0);
      expect(JSON.parse(listed.stdout).sessions.map((entry: { id: string }) => entry.id))
        .toContain(sessionId);
      expect(JSON.parse(listed.stdout).sessions[0].history_len).toBe(0);
      expect(JSON.parse(listed.stdout).sessions[0]).not.toHaveProperty("has_checkpoint");
      expect(readFileSync(eventsPath, "utf8")).toBe(checkpoint);

      const stderrPath = join(fixture.root, "tui.stderr");
      tui = await TmuxSession.create({ cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), stderrPath });
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("/resume");
      await tui.waitForText("Create the first saved turn.", TIMEOUT);
      expect(readFileSync(eventsPath, "utf8")).toBe(checkpoint);
      await tui.sendKeys("Enter");
      await tui.waitForText("unfinished first request", TIMEOUT);
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("Continue after checkpoint.");
      await tui.waitForPane(() => readFileSync(eventsPath, "utf8").includes("CHECKPOINT_TURN_RECOVERED"), TIMEOUT);
      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain("FIRST_CHECKPOINT_FACT");
    } finally {
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test("latest resume discovers and repairs a partial final JSONL record", async () => {
    const fixture = createFixture("fx-session-partial-record-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
      fakeGatewayFinalText("PARTIAL_RECORD_RECOVERED"),
    ]);
    try {
      const sessionId = await createSavedSession(fixture, gateway);
      const sessionDir = join(fixture.home, ".fx", "sessions", sessionId);
      const eventsPath = join(sessionDir, "events.jsonl");
      const committed = readFileSync(eventsPath, "utf8");
      appendFileSync(eventsPath, '{"schema_version":1,"partial-tail"');

      const listed = await runFx(["sessions", "--json"], {
        cwd: fixture.workspace,
        env: gatewayEnv(fixture, gateway),
        timeoutMs: TIMEOUT,
      });
      expect(listed.code).toBe(0);
      expect(listed.stderr).toBe("");
      expect(JSON.parse(listed.stdout).sessions.map((entry: { id: string }) => entry.id))
        .toContain(sessionId);
      expect(readFileSync(eventsPath, "utf8")).toBe(committed + '{"schema_version":1,"partial-tail"');

      const resumed = await continueSession(fixture, gateway, sessionId, true);
      expect(resumed.code).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(JSON.parse(resumed.stdout).session_id).toBe(sessionId);
      expect(JSON.parse(resumed.stdout).output).toBe("PARTIAL_RECORD_RECOVERED");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).not.toContain("partial-tail");

      const repaired = readFileSync(eventsPath, "utf8");
      expect(repaired.startsWith(committed)).toBe(true);
      expect(repaired).not.toContain("partial-tail");
      const files = readdirSync(sessionDir, { withFileTypes: true })
        .filter((entry) => entry.isFile())
        .map((entry) => entry.name)
        .sort();
      expect(files).toEqual([
        "events.jsonl",
        "permissions.json",
        "session.json",
        "session.lock",
        "usage-v2.json",
      ]);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  for (const partialNextRecord of [false, true]) {
    test(`writable resume truncates an unfinished turn with partial next record=${partialNextRecord}`, async () => {
      const fixture = createFixture("fx-session-unfinished-turn-");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("FIRST_TURN_SAVED"),
        fakeGatewayFinalText("UNFINISHED_TURN_RECOVERED"),
      ]);
      try {
        const sessionId = await createSavedSession(fixture, gateway);
        const eventsPath = join(
          fixture.home,
          ".fx",
          "sessions",
          sessionId,
          "events.jsonl",
        );
        const committed = readFileSync(eventsPath, "utf8");
        const lines = committed.trimEnd().split("\n");
        const last = JSON.parse(lines[lines.length - 1]!);
        appendFileSync(eventsPath, JSON.stringify({
          schema_version: 1,
          seq: last.seq + 1,
          timestamp_ms: Date.now(),
          event: {
            user: {
              text: "DANGLING_USER_MUST_NOT_REPLAY",
              images: [],
              work_id: null,
            },
          },
        }) + "\n");
        if (partialNextRecord) appendFileSync(eventsPath, '{"schema_version":1,"event":');

        const resumed = await continueSession(fixture, gateway, sessionId);
        expect(resumed.code).toBe(0);
        expect(resumed.stderr).toBe("");
        expect(JSON.parse(resumed.stdout).output).toBe("UNFINISHED_TURN_RECOVERED");
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1]!.body).not.toContain(
          "DANGLING_USER_MUST_NOT_REPLAY",
        );
        expect(readFileSync(eventsPath, "utf8")).not.toContain(
          "DANGLING_USER_MUST_NOT_REPLAY",
        );
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  test("committed-history corruption fails closed without rewriting JSONL", async () => {
    const fixture = createFixture("fx-session-middle-corruption-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
    ]);
    try {
      const sessionId = await createSavedSession(fixture, gateway);
      const eventsPath = join(
        fixture.home,
        ".fx",
        "sessions",
        sessionId,
        "events.jsonl",
      );
      const committed = readFileSync(eventsPath, "utf8");
      const corrupted = `[${committed.slice(1)}`;
      writeFileSync(eventsPath, corrupted, { mode: 0o600 });

      const detail = await runFx(
        ["session", "--id", sessionId, "--json"],
        {
          cwd: fixture.workspace,
          env: { HOME: fixture.home },
          timeoutMs: TIMEOUT,
        },
      );
      expect(detail.code).toBe(1);
      expect(detail.stderr).toBe("");
      expect(JSON.parse(detail.stdout)).toMatchObject({
        code: "SessionNotFound",
      });
      expect(readFileSync(eventsPath, "utf8")).toBe(corrupted);
      expect(gateway.requests).toHaveLength(1);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);
});
