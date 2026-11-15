import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

function harness() {
  let now = 0, serial = 0, response;
  let socket = { readyState: 1 };
  const timers = new Map(), sent = [], dispatched = [], window = {};
  vm.runInNewContext(fs.readFileSync(new URL("./db-retry.js", import.meta.url), "utf8"), {
    window, ArrayBuffer, DataView, performance: { now: () => now }, Math: { random: () => 0 },
    setTimeout: (fn, delay) => { timers.set(++serial, { fn, at: now + delay }); return serial; },
    clearTimeout: id => timers.delete(id),
  });
  const retry = window.NRCDBRetry.create({ getSocket: () => socket,
    send: packet => sent.push(packet), dispatch: packet => dispatched.push(packet), decode: () => response });
  const packet = new ArrayBuffer(16);
  new DataView(packet).setUint16(0, 21);
  retry.track(packet, 7);
  return { retry, packet, sent, dispatched, timers,
    disconnect() { socket = { readyState: 1 }; },
    refusal(code = "db_connection_overloaded", originOpcode = 21, correlationId = 7) {
      response = { errorMsg: code, originOpcode, correlationId };
      const view = new DataView(new ArrayBuffer(16)); view.setUint16(0, 104);
      return retry.receive(view);
    },
    advance(ms) {
      const end = now + ms;
      for (;;) {
        const next = [...timers].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        timers.delete(next[0]); now = next[1].at; next[1].fn();
      }
      now = end;
    },
  };
}

for (const [code, base] of [["db_connection_overloaded", 50], ["db_worker_overloaded", 150]]) {
  test(`${code}: three bounded retries with copied bytes and exponential backoff`, () => {
    const h = harness(), original = h.packet.slice(0);
    new Uint8Array(h.packet)[15] = 99;
    for (let i = 0; i < 3; i++) {
      assert.equal(h.refusal(code), true);
      assert.equal(h.refusal(code), true, "duplicate refusal does not add a timer");
      h.advance(base * 2 ** i - 1);
      assert.equal(h.sent.length, i);
      h.advance(1);
      assert.deepEqual(h.sent[i], original);
    }
    assert.equal(h.refusal(code), false);
    h.advance(5000);
    assert.equal(h.sent.length, 3);
    assert.equal(h.timers.size, 0);
  });
}

test("only matching explicit refusals retry; success and terminal errors cancel retries", () => {
  const h = harness();
  assert.equal(h.refusal(undefined, 22), false);
  assert.equal(h.refusal(undefined, 21, 8), false);
  h.advance(100);
  assert.equal(h.sent.length, 0);
  assert.equal(h.refusal(), true);
  const success = new DataView(new ArrayBuffer(2048));
  success.setUint16(0, 131); success.setUint32(2044, 7);
  assert.equal(h.retry.receive(success), false);
  h.advance(5000);
  assert.equal(h.sent.length, 0);
  assert.equal(h.refusal(), false);
  const other = harness();
  assert.equal(other.refusal("not authorized"), false);
  assert.equal(other.refusal(), false);
});

test("no timeout replay, no replay after socket replacement, clear cancels scheduled retries", () => {
  for (const action of [h => h.advance(2000), h => h.disconnect(), h => h.retry.clear()]) {
    const h = harness(); action(h);
    assert.equal(h.refusal(), false);
    h.advance(5000); assert.equal(h.sent.length, 0);
  }
  const h = harness(); h.refusal(); h.retry.clear(); h.advance(5000);
  assert.equal(h.sent.length, 0);
});

test("tracking memory is bounded; expiry does not retry unknown outcomes", () => {
  const h = harness();
  for (let i = 1; i <= 129; i++) h.retry.track(h.packet, i);
  assert.equal(h.refusal(undefined, 21, 129), false);
  h.advance(2000);
  assert.equal(h.sent.length, 0);
  assert.equal(h.timers.size, 0);
  h.retry.track(new ArrayBuffer(8 * 1024 * 1024 + 1), 7);
  assert.equal(h.refusal(), false);
});

test("task mutation refusals use the legacy task-list error envelope", () => {
  const window = {};
  const context = { window, ArrayBuffer, DataView, Uint8Array, TextDecoder, TextEncoder,
    performance, setTimeout, clearTimeout, console };
  for (const file of ["protocol.js", "frames.js", "db-retry.js"]) {
    vm.runInNewContext(fs.readFileSync(new URL(file, import.meta.url), "utf8"), context);
  }
  const socket = { readyState: 1 };
  const retry = window.NRCDBRetry.create({ getSocket: () => socket, send() {}, dispatch() {}, decode: window.NRCFrames.decodeServerFrame });
  try {
    const packet = new ArrayBuffer(8); new DataView(packet).setUint16(0, 20);
    retry.track(packet, 73);
    const code = new TextEncoder().encode("db_connection_overloaded");
    const response = new DataView(new ArrayBuffer(19 + code.length));
    response.setUint16(0, 134); response.setUint16(13, code.length);
    new Uint8Array(response.buffer, 15, code.length).set(code);
    response.setUint32(15 + code.length, 73);
    assert.equal(retry.receive(response), true);
  } finally { retry.clear(); }
});
