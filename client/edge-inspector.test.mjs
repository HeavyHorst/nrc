import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const notesSource = fs.readFileSync(new URL("./notes.js", import.meta.url), "utf8");
const tasksSource = fs.readFileSync(new URL("./tasks.js", import.meta.url), "utf8");

function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.notEqual(start, -1, `${name} must exist`);
  let depth = 0;
  let started = false;
  for (let index = start; index < source.length; index++) {
    if (source[index] === "{") { depth++; started = true; }
    if (source[index] === "}" && --depth === 0 && started) return source.slice(start, index + 1);
  }
  assert.fail(`Could not extract ${name}`);
}

function loadEdgeHandlers() {
  const renders = [];
  const window = {
    NRCEdges: { TargetType: { Asset: 1, Task: 2 } },
    NRCLinksUI: { renderLinks: (entity, type) => renders.push([entity.convId, type]) },
  };
  const context = vm.createContext({ window, console: { log() {} } });
  vm.runInContext(`
    let sharedNoteAsset = null;
    let sharedNoteEdges = [];
    let currentDetailNote = null;
    let currentDetailTask = null;
    function renderSharedNoteView() {}
    function fetchSharedLinkedNotePreviews() {}
    function loadSharedNoteEdges() {}
    ${extractFunction(notesSource, "renderNoteLinks")}
    ${extractFunction(notesSource, "handleNoteEdgeChanged")}
    ${extractFunction(tasksSource, "handleTaskEdgeChanged")}
    globalThis.edgeInspectorTest = {
      setNote: (note) => { currentDetailNote = note; },
      setTask: (task) => { currentDetailTask = task; },
      note: handleNoteEdgeChanged,
      task: handleTaskEdgeChanged,
    };
  `, context);
  return { handlers: context.edgeInspectorTest, renders };
}

for (const action of ["all", "cache"]) test(`${action} edge updates refresh both open inspectors only for their matching room`, () => {
  const { handlers, renders } = loadEdgeHandlers();
  handlers.setNote({ convId: 7n, assetId: 70n });
  handlers.setTask({ convId: 7n, id: 71n });

  handlers.note({ convId: 8n }, action);
  handlers.task({ convId: 8n }, action);
  assert.deepEqual(renders, [], "another room's full snapshot must not touch either inspector");

  handlers.note({ convId: 7n }, action);
  handlers.task({ convId: 7n }, action);
  assert.deepEqual(renders, [[7n, 1], [7n, 2]]);
});
