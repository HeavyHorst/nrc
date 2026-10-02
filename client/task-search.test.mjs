import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/task-search.js"), "utf8");

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

function loadController(overrides = {}) {
  const window = {};
  const timers = [];
  const requests = [];
  const context = {
    window,
    fetch: () => { throw new Error("singleton fetch should not run"); },
    setTimeout: (callback, delay) => { timers.push({ callback, delay }); return timers.length; },
    clearTimeout: () => {},
    AbortController,
    Date,
    BigInt,
    Map,
  };
  vm.runInNewContext(fs.readFileSync("client/query-controller.js", "utf8"), context, { filename: "query-controller.js" });
  vm.runInNewContext(source, context, { filename: "task-search.js" });

  const values = {
    roomId: 7n,
    filters: { status: 3, assignee: "me", color: 5, project: "nrc", blocked: true, overdue: true, search: "history" },
    loaded: new Map(),
    ...overrides,
  };
  const controller = window.createTaskSearchController({
    fetchImpl: (url, options) => {
      const pending = deferred();
      requests.push({ url, options, pending });
      return pending.promise;
    },
    setTimer: context.setTimeout,
    clearTimer: context.clearTimeout,
    now: () => 1234,
    getSearchUrl: () => "/search",
    getWorkspace: () => "workspace-1",
    getRoomId: () => values.roomId,
    getNickname: () => "rene",
    getFilters: () => values.filters,
    getLoadedTasks: () => values.loaded,
    onChange: () => {},
  });
  return { controller, requests, timers, values };
}

function searchResponse(results, stale = false) {
  return {
    ok: true,
    headers: { get: (name) => name === "X-NRC-Search-Version" ? "typed-v1" : null },
    json: async () => ({ results, stale }),
  };
}

const flushAsync = () => new Promise((resolve) => setImmediate(resolve));

function taskResult(id, overrides = {}) {
  return {
    entity: { type: "task", id: String(id), conv_id: "0" },
    preview: "Completed Mixed-Case History",
    metadata: {
      task: {
        status: 3,
        order_index: 2,
        assignee: "rene",
        priority: 200,
        color: 5,
        project: "nrc",
        blocked_by: "42",
        due_at: 100,
        created_at: 50,
        ...overrides,
      },
    },
  };
}

test("task search debounces and sends workspace, room, entity type, and exact filters", async () => {
  const { controller, requests, timers } = loadController();
  controller.update({ debounce: true });
  assert.equal(controller.getState().mode, "loading");
  assert.equal(requests.length, 0);
  assert.equal(timers[0].delay, 250);
  timers[0].callback();
  assert.equal(requests.length, 1);
  const body = JSON.parse(requests[0].options.body);
  assert.deepEqual(body, {
    workspace: "workspace-1",
    query: "history",
    conv_id: "0",
    top_n: 100,
    filters: {
      entity_types: ["task"],
      task: {
        statuses: [3],
        assignees: ["rene"],
        colors: [5],
        projects: ["nrc"],
        blocked: true,
        overdue_before: 1234000000,
      },
    },
  });
  requests[0].pending.resolve(searchResponse([]));
  await requests[0].pending.promise;
});

test("All searches every task status while Open excludes Done", () => {
  const { controller, requests } = loadController({
    filters: {
      status: null, assignee: null, color: null, project: null,
      blocked: null, overdue: null, search: "semantic",
    },
  });
  controller.update();
  assert.deepEqual(JSON.parse(requests[0].options.body).filters.task, {
    statuses: [0, 1, 2, 3],
  });

  const open = loadController({
    filters: {
      status: "open", assignee: null, color: null, project: null,
      blocked: null, overdue: null, search: "semantic",
    },
  });
  open.controller.update();
  assert.deepEqual(JSON.parse(open.requests[0].options.body).filters.task, {
    statuses: [0, 1, 2],
  });
});

test("unloaded Done results remain separate projections while loaded tasks win", async () => {
  const loaded = { id: 8n, convId: 0n, title: "Fresh cached title", status: 3 };
  const { controller, requests, values } = loadController({ loaded: new Map([[8n, loaded]]) });
  controller.update();
  requests[0].pending.resolve(searchResponse([taskResult(8), taskResult(9)], true));
  await flushAsync();

  const state = controller.getState();
  assert.equal(state.mode, "results");
  assert.equal(state.stale, true);
  assert.equal(state.tasks.get(8n), loaded);
  assert.equal(state.tasks.get(9n).status, 3);
  assert.equal(state.tasks.get(9n).title, "Completed Mixed-Case History");
  assert.equal(state.tasks.get(9n).__searchResult, true);
  assert.equal(controller.getTask(0n, 9n).id, 9n, "keyboard navigation can resolve an unloaded projection");
  assert.equal(values.loaded.has(9n), false, "search projections must not pollute the partial task cache");
});

test("new searches abort old requests and suppress stale responses", async () => {
  const { controller, requests, values } = loadController();
  controller.update();
  const firstSignal = requests[0].options.signal;
  values.filters = { ...values.filters, search: "new query" };
  controller.update();
  assert.equal(firstSignal.aborted, true);

  requests[1].pending.resolve(searchResponse([taskResult(9)]));
  await flushAsync();
  requests[0].pending.resolve(searchResponse([taskResult(8)]));
  await flushAsync();
  assert.equal(controller.getState().query, "new query");
  assert.deepEqual(Array.from(controller.getState().tasks.keys()), [9n]);
});

test("chat room changes retain workspace search scope", async () => {
  const { controller, requests, values } = loadController();
  controller.update();
  values.roomId = 8n;
  controller.onRoomSwitch();
  assert.equal(requests[0].options.signal.aborted, true);
  assert.equal(JSON.parse(requests[1].options.body).conv_id, "0");
  requests[0].pending.resolve(searchResponse([taskResult(9)]));
  await flushAsync();
  assert.equal(controller.getState().roomId, 0n);
  assert.equal(controller.getState().mode, "loading");
});

test("errors and disconnects enter explicit local-only fallback; reconnect retries", async () => {
  const { controller, requests } = loadController();
  controller.update();
  requests[0].pending.resolve({ ok: false, status: 503 });
  await flushAsync();
  assert.equal(controller.getState().mode, "fallback");

  controller.onReconnect();
  assert.equal(requests.length, 2);
  controller.onDisconnect();
  assert.equal(requests[1].options.signal.aborted, true);
  assert.equal(controller.getState().mode, "fallback");
});

test("malformed or wrong-entity responses fall back instead of claiming no matches", async () => {
  const { controller, requests } = loadController();
  controller.update();
  requests[0].pending.resolve(searchResponse([{ entity: { type: "asset", id: "9", conv_id: "7" } }]));
  await flushAsync();
  assert.equal(controller.getState().mode, "fallback");
});

test("a service without the typed capability header falls back locally", async () => {
  const { controller, requests } = loadController();
  controller.update();
  requests[0].pending.resolve({
    ok: true,
    headers: { get: () => null },
    json: async () => ({ results: [] }),
  });
  await flushAsync();
  assert.equal(controller.getState().mode, "fallback");
});
