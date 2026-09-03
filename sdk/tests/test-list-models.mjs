#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { listModels as listBrowserModels } from "../browser.js";
import { listModels as listNodeModels } from "../node.js";

for (const [surface, listModels] of [["node", listNodeModels], ["browser", listBrowserModels]]) {
  let calls = 0;
  const models = await listModels({
    apiKey: "catalog-key",
    async fetch(url, init) {
      calls += 1;
      assert.equal(String(url), "https://ai-gateway.vercel.sh/coding-agent/v1/models");
      assert.equal(init.method, "GET");
      assert.equal(new Headers(init.headers).get("authorization"), "Bearer catalog-key");
      return Response.json({
        object: "list",
        data: [
          { id: "z/model", type: "language" },
          { id: "image/model", type: "image" },
          { id: "a/model", type: "language" },
          { id: "z/model", type: "language" },
          { id: "", type: "language" },
          { nope: true },
        ],
      });
    },
  });
  assert.deepEqual(models, ["a/model", "z/model"]);
  assert.equal(calls, 1, `${surface} listModels must perform one explicit request`);

  await assert.rejects(listModels({}), (error) => error instanceof TypeError && error.message.includes("apiKey"));
  await assert.rejects(
    listModels({ apiKey: "catalog-key", fetch: async () => new Response("unavailable", { status: 503 }) }),
    (error) => error instanceof Error && error.message.includes("503") && !error.message.includes("catalog-key"),
  );
  await assert.rejects(
    listModels({ apiKey: "catalog-key", fetch: async () => Response.json({ object: "list" }) }),
    (error) => error instanceof TypeError && error.message.includes("model catalog"),
  );
  await assert.rejects(
    listModels({
      apiKey: "catalog-key",
      fetch: async () => Response.json({ object: "list", data: [] }, { headers: { "content-length": String(4 * 1024 * 1024 + 1) } }),
    }),
    (error) => error instanceof RangeError && error.message.includes("4194304"),
  );
  await assert.rejects(
    listModels({
      apiKey: "catalog-key",
      fetch: async () => new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(new Uint8Array(4 * 1024 * 1024 + 1));
        },
        cancel() {
          throw new Error("injected cancellation failure");
        },
      })),
    }),
    (error) => error instanceof RangeError && error.message.includes("4194304"),
  );
}

console.log("explicit Node and browser model discovery passed");
