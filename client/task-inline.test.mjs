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
