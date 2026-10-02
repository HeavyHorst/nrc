import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./tasks.js", import.meta.url), "utf8");

function extractFunction(name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1);
  let depth = 0;
  let opened = false;
  for (let i = start; i < source.length; i++) {
    if (source[i] === "{") { depth++; opened = true; }
    if (source[i] === "}" && --depth === 0 && opened) return source.slice(start, i + 1);
  }
  throw new Error(`Could not extract ${name}`);
}

function loadRequestTask() {
  const sends = [];
  const sandbox = { BigInt, sends, window: {} };
  vm.runInNewContext(`
    const roomTasks = new Map();
    const pendingExactTaskRequests = new Map();
    const pendingTaskRpcs = new Map();
    const pendingTaskUpdateCorrelations = new Set();
    const taskPageState = new Map();
    let ready = true;
    function sendGetTask(convId, taskId, options) {
      if (!ready) return undefined;
      const request = { convId, taskId, options, correlationId: sends.length + 1 };
      sends.push(request);
      pendingTaskRpcs.set(request.correlationId, options);
      return request.correlationId;
    }
    ${extractFunction("requestTask")}
    ${extractFunction("clearPendingTaskRpcs")}
    this.api = { roomTasks, requestTask, clearPendingTaskRpcs, pendingTaskRpcs, setReady: (value) => { ready = value; } };
  `, sandbox);
  return { ...sandbox.api, sends };
}

test("exact task reads hit cache and preserve 64-bit IDs", () => {
  const { roomTasks, requestTask, sends } = loadRequestTask();
  const id = 9007199254740999n;
  const task = { convId: 0n, id };
  roomTasks.set(0n, new Map([[id, task]]));
  let loaded;
  assert.equal(requestTask(7n, id, { onSuccess: ({ task }) => { loaded = task; } }), task);
  assert.equal(loaded, task);
  assert.equal(sends.length, 0);
});

test("exact task reads coalesce across legacy room references and clear after errors for retry", () => {
  const { requestTask, sends } = loadRequestTask();
  const calls = [];
  const first = requestTask(7n, 42n, { onError: () => calls.push("a") });
  assert.equal(requestTask(7n, 42n, { onError: () => calls.push("b") }), first);
  const otherRoom = requestTask(8n, 42n);
  assert.equal(otherRoom, first);
  assert.equal(sends.length, 1);
  assert.equal(sends[0].convId, 0n);
  sends[0].options.onError({ message: "not found" });
  assert.deepEqual(calls, ["a", "b"]);
  assert.notEqual(requestTask(7n, 42n), first);
  assert.equal(sends.length, 2);
});

test("unavailable task transport reports failure and permits a later retry", () => {
  const f = loadRequestTask();
  f.setReady(false);
  let errors = 0;
  assert.equal(f.requestTask(7n, 42n, { onError: () => errors++ }), undefined);
  assert.equal(errors, 1);
  assert.equal(f.sends.length, 0);
  f.setReady(true);
  assert.equal(f.requestTask(7n, 42n), 1);
});

test("task disconnect notifies all subscribers even when an earlier raw callback throws", () => {
  const f = loadRequestTask();
  f.pendingTaskRpcs.set(0, { onError: () => { throw new Error("expected callback failure"); } });
  let errors = 0;
  f.requestTask(7n, 42n, { onError: () => errors++ });
  f.requestTask(7n, 42n, { onError: () => errors++ });
  f.setReady(false);
  f.clearPendingTaskRpcs();
  assert.equal(errors, 2);
  assert.equal(f.pendingTaskRpcs.size, 0);
  f.setReady(true);
  assert.equal(f.requestTask(7n, 42n), 2);
});
