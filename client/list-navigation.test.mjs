import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const window = {};
const source = fs.readFileSync(path.resolve("client/list-navigation.js"), "utf8");
vm.runInNewContext(source, { window }, { filename: "list-navigation.js" });

const { resolveAdjacent, sameCompoundIdentity, isKeyboardViewActive } = window.NRCListNavigation;
const row = (convId, id) => ({ convId, id });
const identity = (value) => ({ convId: value.convId, id: value.id });

test("adjacent navigation enters an unselected list at the requested boundary", () => {
  const rows = [row("1", "10"), row("1", "20")];
  assert.equal(resolveAdjacent(rows, null, 1, identity, sameCompoundIdentity).row.id, "10");
  assert.equal(resolveAdjacent(rows, null, -1, identity, sameCompoundIdentity).row.id, "20");
});

test("adjacent navigation follows current row order and clamps at boundaries", () => {
  const first = row("1", "10");
  const middle = row("1", "20");
  const last = row("1", "30");
  assert.equal(resolveAdjacent([first, middle, last], identity(middle), 1, identity, sameCompoundIdentity).row, last);
  assert.equal(resolveAdjacent([last, middle, first], identity(middle), 1, identity, sameCompoundIdentity).row, first);
  const boundary = resolveAdjacent([first, middle, last], identity(last), 1, identity, sameCompoundIdentity);
  assert.equal(boundary.status, "boundary");
  assert.equal(boundary.row, last);
});

test("missing and empty selections do not jump to another row", () => {
  const rows = [row("1", "10")];
  assert.equal(resolveAdjacent([], null, 1, identity, sameCompoundIdentity).status, "empty");
  assert.equal(resolveAdjacent(rows, { convId: "1", id: "99" }, 1, identity, sameCompoundIdentity).status, "missing-selection");
  assert.equal(resolveAdjacent(rows, { convId: "2", id: "10" }, 1, identity, sameCompoundIdentity).status, "missing-selection");
});

test("keyboard handlers activate only for their visible view", () => {
  assert.equal(isKeyboardViewActive("reminders", "reminders", true, true, true), true);
  assert.equal(isKeyboardViewActive("kanban", "reminders", true, true, true), false);
  assert.equal(isKeyboardViewActive("notes", "reminders", true, true, true), false);
  assert.equal(isKeyboardViewActive("reminders", "reminders", false, true, true), false);
  assert.equal(isKeyboardViewActive("reminders", "reminders", true, false, true), false);
  assert.equal(isKeyboardViewActive("reminders", "reminders", true, true, false), false);
});
