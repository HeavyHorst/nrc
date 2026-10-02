import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./appointments.js", import.meta.url), "utf8");
const listeners = {};
const document = { addEventListener: (name, fn) => { listeners[name] = fn; }, getElementById: () => null, querySelector: () => null };
const window = { NRCAssets: { AssetType: { Appointment: 12 } } };
vm.runInNewContext(source, { window, document, Date, Intl, BigInt, Number, String, JSON, URL, Set, TextEncoder });
const api = window.NRCAppointments;

test("empty asset payloads remain plain even when the compression codec is ready", () => {
  const assets = fs.readFileSync(new URL("./assets.js", import.meta.url), "utf8");
  const context = { assetTextEncoder: new TextEncoder(), MAX_PAYLOAD_LENGTH: 65535,
    PayloadEncoding: { Plain: 0, Zstd: 1 }, zstdStreamCodec: { compress() { throw new Error("empty payload must not be compressed"); } } };
  vm.runInNewContext(assets.slice(assets.indexOf("function encodeAssetPayloadForWire("), assets.indexOf("function decodeAssetPayloadFromWire(")), context);
  const wire = context.encodeAssetPayloadForWire("");
  assert.equal(wire.payloadEncoding, 0);
  assert.equal(wire.payloadRawLen, 0);
  assert.equal(wire.payloadBytes.length, 0);
});

test("appointment preview decoding follows the version 1 plain JSON contract", () => {
  const asset = { assetType: 12, preview: JSON.stringify({ version: 1, title: "Review", start_at: "100", end_at: "200", description: "Agenda", assignee: "rene", project: "NRC", url: "https://meet.example/1" }) };
  const parsed = api.parse(asset);
  assert.equal(parsed.title, "Review"); assert.equal(parsed.startAt, 100n); assert.equal(parsed.endAt, 200n);
  assert.equal(api.parse({ ...asset, preview: JSON.stringify({ version: 1, title: "Review", start_at: "200", end_at: "100" }) }), null);
});

test("editor validation enforces field sizes, timestamps and safe meeting URLs", () => {
  const valid = { title: "Review", assignee: "rene", startAt: 100n, endAt: 0n, description: "", project: "", url: "" };
  assert.equal(api.validate(valid), "");
  assert.match(api.validate({ ...valid, title: "" }), /TITLE/);
  assert.equal(api.validate({ ...valid, assignee: "" }), "");
  assert.match(api.validate({ ...valid, assignee: "a".repeat(33) }), /ASSIGNEE/);
  assert.equal(api.validate({ ...valid, project: "p".repeat(128) }), "");
  assert.match(api.validate({ ...valid, description: "é".repeat(1025) }), /DESCRIPTION/);
  assert.match(api.validate({ ...valid, startAt: -1n }), /START/);
  assert.match(api.validate({ ...valid, startAt: 9223372036854775808n }), /START/);
  assert.match(api.validate({ ...valid, endAt: 100n }), /AFTER START/);
  assert.match(api.validate({ ...valid, url: "not a url" }), /URL/);
  assert.match(api.validate({ ...valid, url: "javascript:alert(1)" }), /HTTP/);
  assert.deepEqual(JSON.parse(api.serialize(valid)), { version: 1, title: "Review", start_at: "100", end_at: "", description: "", assignee: "rene", project: "", url: "" });
});
