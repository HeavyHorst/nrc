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

test("IANA wall times skip DST gaps and choose the earliest folded instant", () => {
  assert.equal(api.zonedNanos("2026-03-29T02:30", "Europe/Berlin"), 0n);
  assert.equal(api.zonedNanos("2026-10-25T02:30", "Europe/Berlin"), BigInt(Date.parse("2026-10-25T00:30Z")) * 1000000n);
  const instant = api.zonedNanos("2026-10-20T11:00", "Asia/Kathmandu");
  assert.equal(api.zonedValue(instant, "Asia/Kathmandu"), "2026-10-20T11:00");
});

test("v2 serialization retains recurrence, participants and sparse exceptions", () => {
  const data = { version: 2, title: "Standup", start_at: "1792486800000000000", end_at: "", description: "", assignee: "", project: "", url: "", timezone: "Europe/Berlin", repeat: "weekly", weekdays: [1, 3], until: "2026-12-31", participants: ["alex"], conference: "nrc", exceptions: [{ at: "1792486800000000000", cancelled: false, participants: [] }] };
  const parsed = api.parse({ assetType: 12, preview: JSON.stringify(data) });
  assert.deepEqual(JSON.parse(api.serialize(parsed)), data);
  assert.equal(api.validate(parsed), "");
  assert.match(api.validate({ ...parsed, endAt: parsed.startAt + 86400000000001n }), /24 HOURS/);
  assert.match(api.validate({ ...parsed, weekdays: [] }), /WEEKDAY/);
});
