import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./customers.js", import.meta.url), "utf8");
test("review queue discovers pending contacts without company membership and leaves legacy contacts alone", () => {
  const { api } = load();
  const asset = (assetType, data) => ({ assetType, preview: JSON.stringify({ version: 1, title: "Imported", ...data }) });
  assert.equal(api.needsReview(asset(9, { source: "email", review_status: "pending" })), true);
  assert.equal(api.needsReview(asset(9, { review_status: "reviewed" })), false);
  assert.equal(api.needsReview(asset(9, {})), false);
  assert.equal(api.needsReview(asset(8, { review_status: "pending" })), false);
});
function load(fetch) {
  const elements = new Map();
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, { hidden: true, open: false, value: '', innerHTML: '', setAttribute() {}, setState() {}, contains() { return false; }, remove() {} });
      return elements.get(id);
    },
    addEventListener() {},
  };
  const window = { NRCViewManager: { getActiveView: () => "chat" }, NRCLinksUI: { isPickerVisible: () => false }, createLoadingIndicator: () => ({ update: () => false }), NRCEdges: { RelationType: { RelatedTo: 2, MemberOf: 7 } } };
  vm.runInNewContext(source, { window, document, fetch, console, queueMicrotask, TextEncoder, setTimeout, clearTimeout });
  return { api: window.NRCCustomers, elements, window };
}

test("live pending contacts enter review without reload, deduplicate and leave after review or deletion", async () => {
  const { api, elements, window } = load(async () => ({ ok: true, json: async () => ({ customers: true }) }));
  await api.refreshAccess();
  window.NRCViewManager.getActiveView = () => "customers";
  const contact = { convId: 0n, assetId: 88n, assetType: 9, preview: JSON.stringify({ version: 1, title: "Email arrival", source: "email", review_status: "pending" }) };
  api.onAssetChanged(contact); api.onAssetChanged(contact);
  await Promise.resolve();
  assert.match(elements.get("customersList").innerHTML, /NEW CONTACTS \/ 1/);
  assert.match(elements.get("customersList").innerHTML, /data-review-contact="88"/);
  api.onAssetChanged({ ...contact, preview: JSON.stringify({ version: 1, title: "Email arrival", review_status: "reviewed" }) });
  await Promise.resolve();
  assert.doesNotMatch(elements.get("customersList").innerHTML, /data-review-contact="88"/);
  api.onAssetChanged(contact); await Promise.resolve();
  api.onAssetDeleted(0n, 88n); await Promise.resolve();
  assert.match(elements.get("customersList").innerHTML, /NEW CONTACTS \/ 0/);
});

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
