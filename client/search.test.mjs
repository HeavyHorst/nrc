import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

function fixture() {
  const window = {};
  vm.runInNewContext(readFileSync(new URL("query-controller.js", import.meta.url), "utf8"), { window, AbortController, setTimeout, clearTimeout });
  const scope = { workspace: "one", room: 7n };
  const timers = [];
  const requests = [];
  const results = [];
  const errors = [];
  const options = {
    getWorkspace: () => scope.workspace, getRoomId: () => scope.room, getSearchUrl: () => "/search",
    setTimer: (fn) => { timers.push(fn); return timers.length; }, clearTimer: () => {},
    fetchImpl: (url, init) => new Promise((resolve, reject) => requests.push({ url, init, resolve, reject })),
  };
  const controller = window.NRCSearch.createController(options);
  const callbacks = { onResult: (data) => results.push(data), onError: (error) => errors.push(error) };
  return { controller, scope, timers, requests, results, errors, callbacks, second: () => window.NRCSearch.createController(options) };
}
const flush = () => new Promise(setImmediate);
const response = (results = []) => ({ ok: true, headers: { get: () => "typed-v1" }, json: async () => ({ results }) });

test("shared search scopes legacy and typed requests and keeps controllers independent", async () => {
  const f = fixture();
  f.controller.search({ query: "note", asset_types: [5], top_n: 10 }, f.callbacks);
  f.second().search({ query: "task", filters: { entity_types: ["task"] } }, f.callbacks);
  assert.equal(f.requests[0].init.signal.aborted, false);
  assert.equal(JSON.parse(f.requests[0].init.body).conv_id, "0");
  f.requests[0].resolve({ ok: true, json: async () => ({ results: null }) });
  f.requests[1].resolve(response());
  await flush();
  assert.equal(f.results.length, 2);
  assert.equal(f.errors.length, 0);
});

test("debounced old queries and cancelled searches never send, even if their timers run", () => {
  const f = fixture();
  f.controller.search({ query: "old" }, { ...f.callbacks, debounce: 250 });
  f.controller.search({ query: "new" }, { ...f.callbacks, debounce: 250 });
  f.timers[0]();
  assert.equal(f.requests.length, 0);
  f.controller.cancel();
  f.timers[1]();
  assert.equal(f.requests.length, 0);
});

test("only workspace changes suppress late success and failures; chat navigation preserves search", async () => {
  for (const field of ["room", "workspace"]) {
    for (const fails of [false, true]) {
      const f = fixture();
      f.controller.search({ query: "old" }, f.callbacks);
      f.scope[field] = field === "room" ? 8n : "two";
      if (fails) f.requests[0].reject(new Error("late failure"));
      else f.requests[0].resolve(response());
      await flush();
      assert.equal(f.results.length + f.errors.length, field === "workspace" ? 0 : 1);
    }
  }
});

test("new queries win, malformed results and missing typed capability report errors", async () => {
  const f = fixture();
  f.controller.search({ query: "old" }, f.callbacks);
  f.controller.search({ query: "new" }, f.callbacks);
  assert.equal(f.requests[0].init.signal.aborted, true);
  f.requests[1].resolve(response([{ preview: "latest" }]));
  f.requests[0].resolve(response([{ preview: "old" }]));
  await flush();
  assert.equal(f.results.length, 1);
  assert.equal(f.results[0].results[0].preview, "latest");
  f.controller.search({ query: "bad" }, f.callbacks);
  f.requests[2].resolve(response({ invalid: true }));
  await flush();
  f.controller.search({ query: "typed", filters: { entity_types: ["task"] } }, f.callbacks);
  f.requests[3].resolve({ ok: true, headers: { get: () => null } });
  await flush();
  assert.equal(f.errors.length, 2);
});
