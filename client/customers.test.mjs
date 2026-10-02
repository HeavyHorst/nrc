import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./customers.js", import.meta.url), "utf8");
function load(fetch) {
  const elements = new Map();
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, { hidden: true, open: false });
      return elements.get(id);
    },
    addEventListener() {},
  };
  const window = { NRCViewManager: { getActiveView: () => "chat" }, NRCEdges: { RelationType: { RelatedTo: 2, MemberOf: 7 } } };
  vm.runInNewContext(source, { window, document, fetch, console, queueMicrotask, TextEncoder, setTimeout, clearTimeout });
  return { api: window.NRCCustomers, elements };
}

test("customer view defaults denied and only accepts a literal true capability", async () => {
  for (const result of [false, "true", 1, undefined, true]) {
    const { api, elements } = load(async () => ({ ok: true, json: async () => ({ customers: result }) }));
    assert.equal(api.isEnabled(), false);
    await api.refreshAccess();
    assert.equal(api.isEnabled(), result === true);
    assert.equal(elements.get("customersBtn").hidden, result !== true);
  }
});

test("feature request is uncached, fails closed and stale allow cannot undo newer denial", async () => {
  let release;
  let requests = 0;
  const { api } = load(async (url, options) => {
    assert.equal(url, "/api/features");
    assert.equal(options.cache, "no-store");
    assert.equal(options.credentials, "same-origin");
    if (++requests === 1) return new Promise(resolve => { release = resolve; });
    throw new Error("offline");
  });
  const old = api.refreshAccess();
  await api.refreshAccess();
  release({ ok: true, json: async () => ({ customers: true }) });
  await old;
  assert.equal(api.isEnabled(), false);
});

test("contact metadata needs no company ID and rejects incompatible records", () => {
  const { api } = load();
  const parse = (assetType, metadata) => api.metadata({ assetType, preview: JSON.stringify(metadata) });
  assert.equal(parse(9, { version: 1, title: "Alice" }).title, "Alice");
  assert.equal(parse(10, { version: 1, title: "Call" }).title, "Call");
  assert.equal(parse(8, { version: 2, title: "Future" }), null);
  assert.equal(parse(8, { version: 1, title: {} }), null);
  assert.equal(api.metadata({ preview: "broken" }), null);
});

test("company links use member-of asset endpoints in either direction, with exact IDs", () => {
  const { api } = load();
  const company = 18446744073709551614n;
  const person = company - 1n;
  const edge = { sourceType: 1, sourceId: person, targetType: 1, targetId: company, relation: 7 };
  assert.equal(api.isCompanyLink(edge, company, person), true);
  assert.equal(api.isCompanyLink({ ...edge, sourceId: company, targetId: person }, company, person), true);
  assert.equal(api.isCompanyLink(edge, company, company), false);
  assert.equal(api.isCompanyLink({ ...edge, sourceType: 2 }, company, person), false);
  assert.equal(api.isCompanyLink({ ...edge, targetType: 2 }, company, person), false);
  assert.equal(api.isCompanyLink({ ...edge, relation: 2 }, company, person), false);
});
