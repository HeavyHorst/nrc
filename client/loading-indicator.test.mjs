import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./loading-indicator.js", import.meta.url), "utf8");

test("loading feedback starts at 150 ms, not on an immediate or fast read", t => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const window = {};
  vm.runInNewContext(source, { window, setTimeout, clearTimeout });
  let paints = 0;
  const indicator = window.createLoadingIndicator(() => paints++);
  assert.equal(indicator.update(true), false);
  t.mock.timers.tick(100);
  assert.equal(indicator.update(false), false);
  t.mock.timers.tick(100);
  assert.equal(paints, 0, "a completed fast read must not flash later");

  indicator.update(true);
  t.mock.timers.tick(149);
  assert.equal(indicator.update(true), false, "repaints do not restart the loading delay");
  t.mock.timers.tick(1);
  assert.equal(indicator.update(true), true);
  assert.equal(paints, 1);
  assert.equal(indicator.update(false), false, "completion hides feedback immediately");
});

test("cancelled reads cannot reveal the indicator of a replacement read", () => {
  const callbacks = [];
  const window = {};
  vm.runInNewContext(source, { window,
    setTimeout: fn => { callbacks.push(fn); return callbacks.length; }, clearTimeout() {} });
  let paints = 0;
  const indicator = window.createLoadingIndicator(() => paints++);
  indicator.update(true);
  indicator.update(false);
  indicator.update(true);
  callbacks[0](); // Simulate a cancelled callback already queued by the browser.
  assert.equal(indicator.update(true), false);
  assert.equal(paints, 0);
  callbacks[1]();
  assert.equal(indicator.update(true), true);
  assert.equal(paints, 1);
});
