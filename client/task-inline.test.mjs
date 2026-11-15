import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("tasks.js", import.meta.url), "utf8");
function functionSource(name) {
  const start = source.indexOf(`function ${name}(`);
  let brace = source.indexOf(") {", start) + 2, depth = 0;
  for (let i = brace; i < source.length; i++) {
    if (source[i] === "{") depth++;
    if (source[i] === "}" && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`missing ${name}`);
}

function harness() {
  let options;
  const context = {
    TextEncoder,
    TaskColorNames: ["—", "ACTIVE", "BLOCKED", "READY", "DEFERRED", "TEST"],
    TaskStatusNames: ["BACKLOG", "TODO", "IN PROGRESS", "DONE", "NOTE"],
    MAX_TASK_TITLE_LENGTH: 256, MAX_ASSIGNEE_LENGTH: 32,
    MAX_EXTERNAL_REF_LENGTH: 512, MAX_PROJECT_LENGTH: 128,
    UPDATE_BLOCKED_BY_CLEAR: 0xffffffffffffffffn,
    formatDateTimeLocal: () => "", formatDueDateShort: () => "DATE", parseDateTimeLocal: () => 10n,
    escapeHtml: String, taskUpdatePromise: async (_task, patch) => patch,
    getCanonicalTask: task => task, roomTasks: new Map(), userDirectory: () => ["directory-user"],
    window: { NRCDetailUI: { inlineField(value) { options = value; return "<control>"; } },
      NRCTaskQuery: { getAssignees: () => ["indexed-user"], getProjects: () => ["Indexed project"] } },
  };
  vm.runInNewContext(`${functionSource("taskFieldSpec")}\n${functionSource("taskFieldChoices")}\n${functionSource("fieldControl")}`, context);
  return { context, getOptions: () => options };
}

const task = { id: 7n, convId: 0n, title: "A", status: 1, priority: 3, color: 0, dueAt: 0n, blockedBy: 0n };

test("fieldControl delegates a rename control to shared inline UI", () => {
  const h = harness();
  assert.equal(h.context.fieldControl(task, "title", { rename: true }), "<control>");
  assert.equal(h.getOptions().display, "RENAME");
  assert.equal(h.getOptions().required, true);
  assert.equal(h.getOptions().maxBytes, 256);
});

test("inline task validation reserves sentinels and rejects self blockers", async () => {
  const h = harness();
  h.context.fieldControl(task, "priority");
  await assert.rejects(() => h.getOptions().save("255"), /0–254/);
  h.context.fieldControl(task, "blockedBy");
  await assert.rejects(() => h.getOptions().save("#7"), /CANNOT BLOCK ITSELF/);
});

test("clearing optional fields sends explicit protocol sentinels", async () => {
  const h = harness();
  h.context.fieldControl({ ...task, project: "OLD" }, "project");
  assert.equal((await h.getOptions().save("")).project, "\x00");
  h.context.fieldControl({ ...task, dueAt: 99n }, "dueAt");
  assert.equal((await h.getOptions().save("")).dueAt, -1n);
});

test("assignee and project inline pickers include indexed and loaded task values", () => {
  const h = harness();
  h.context.roomTasks.set(0n, new Map([[1n, { assignee: "loaded-user", project: "Loaded project" }]]));
  h.context.fieldControl(task, "assignee");
  assert.deepEqual(Array.from(h.getOptions().suggestions()), ["directory-user", "indexed-user", "loaded-user"]);
  h.context.fieldControl(task, "project");
  assert.deepEqual(Array.from(h.getOptions().suggestions()), ["Indexed project", "Loaded project"]);
});

function descriptionHarness() {
  const editor = { value: "" }, sent = [], states = [], messages = [];
  const context = {
    TextEncoder, MAX_TASK_DESCRIPTION_LENGTH: 4096,
    currentDetailTask: { id: 7n, convId: 0n, description: "original" },
    taskDetailSaveGeneration: 0, taskDetailDirty: false, taskDetailSaves: new Map(),
    taskMarkdownUpdates: new Map(),
    getTaskMarkdown: task => task.description,
    getCanonicalTask: task => task,
    renderSelectedTaskMarkdown() {}, requestTask() {},
    logMessage: (_kind, message) => messages.push(message),
    showToast: message => messages.push(message),
    document: { getElementById: () => editor },
    window: { NRCDetailUI: { setSaveState: state => states.push(state) } },
    getTaskMarkdownUpdateKey: task => `${task.convId}:${task.id}`,
    snapshotTaskDetail() { context.taskDetailDirty = false; },
    sendUpdateTask(...args) {
      sent.push({ id: args[1], description: args[3], callbacks: args.at(-1) });
      return sent.length;
    },
  };
  vm.runInNewContext(functionSource("saveTaskFromDetailPanel") +
    functionSource("sendPendingTaskDetailSave") + functionSource("queueTaskMarkdownUpdate") +
    functionSource("sendPendingTaskMarkdown"), context);
  return { context, editor, sent, states, messages,
    save(value) { editor.value = value; context.saveTaskFromDetailPanel(); },
    ack(index) {
      const request = sent[index];
      request.callbacks.onSuccess({ task: { id: request.id, convId: 0n, description: request.description === "\x00" ? "" : request.description } });
    },
  };
}

test("description saves wait for the previous result and retain only the latest submitted draft", () => {
  const h = descriptionHarness();
  h.save("A"); // This request can be waiting for an overload retry.
  h.save("B");
  h.save("C");
  assert.deepEqual(h.sent.map(request => request.description), ["A"]);
  h.ack(0);
  assert.deepEqual(h.sent.map(request => request.description), ["A", "C"]);
  assert.notEqual(h.states.at(-1), "SAVED");
  h.ack(1);
  assert.equal(h.context.currentDetailTask.description, "C");
  assert.equal(h.states.at(-1), "SAVED");
});

test("description save failures retain the latest draft and other tasks can save independently", () => {
  const h = descriptionHarness();
  h.save("A"); h.save("B");
  h.sent[0].callbacks.onError();
  assert.equal(h.editor.value, "B");
  assert.equal(h.context.taskDetailDirty, true);
  assert.equal(h.states.at(-1), "FAILED");
  h.save("B");
  h.context.currentDetailTask = { id: 8n, convId: 0n, description: "other" };
  h.save("");
  assert.deepEqual(h.sent.map(request => request.id), [7n, 7n, 8n]);
  h.ack(1); // Acknowledging the previous task must not replace this editor.
  assert.equal(h.context.currentDetailTask.id, 8n);
  h.ack(2);
  assert.equal(h.context.currentDetailTask.description, "");
});

for (const outcome of ["success", "failure"]) {
  test(`checkbox and detail writes exclude each other until ${outcome}, without blocking other tasks`, () => {
    const h = descriptionHarness();
    const first = h.context.currentDetailTask;
    h.save("- [ ] saved description");
    h.context.queueTaskMarkdownUpdate(first, "- [x] conflicting checkbox");
    assert.equal(h.sent.length, 1);
    assert.match(h.messages.at(-1), /WAIT.*SAVE/);
    const other = { ...first, id: 8n };
    h.context.queueTaskMarkdownUpdate(other, "- [x] independent");
    assert.equal(h.sent.length, 2);
    if (outcome === "success") h.ack(0); else h.sent[0].callbacks.onError();
    h.context.queueTaskMarkdownUpdate(first, "- [x] checkbox after detail");
    assert.equal(h.sent.length, 3);
    h.save("new draft must stay in editor");
    assert.equal(h.sent.length, 3);
    assert.equal(h.editor.value, "new draft must stay in editor");
    assert.match(h.messages.at(-1), /WAIT.*CHECKBOX/);
    if (outcome === "success") h.ack(2); else h.sent[2].callbacks.onError();
    h.save(h.editor.value);
    assert.equal(h.sent.length, 4);
    assert.equal(h.sent[3].description, "new draft must stay in editor");
  });
}
