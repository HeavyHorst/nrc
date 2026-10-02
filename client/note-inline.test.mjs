import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { readFile } from "node:fs/promises";

const source = await readFile(new URL("./notes.js", import.meta.url), "utf8");

function fixture() {
  let inlineOptions;
  let patchCall;
  const note = {
    convId: 0n,
    assetId: 12n,
    updatedAt: 99n,
    preview: JSON.stringify({ title: "Old", teaser: "keep", project: "P", tags: ["one"], format: "html", future: { key: 1 } }),
    payload: "not loaded by metadata",
  };
  const window = {
    NRCHTMLNotes: { normalizeFormat: value => value === "html" ? "html" : "markdown" },
    NRCDetailUI: {
      inlineField(options) { inlineOptions = options; return "<i>field</i>"; },
    },
    NRCAssets: {
      roomAssets: new Map([[0n, new Map([[12n, note]])]]),
      sendGetAsset(_room, _id, options) {
        queueMicrotask(() => options.onSuccess({ asset: window.NRCAssets.roomAssets.get(0n).get(12n) }));
        return 6;
      },
    },
    NRCTransactions: {
      sendAssetMetadataPatch(asset, preview, payload, options) {
        patchCall = { asset, preview, payload };
        queueMicrotask(() => options.onSuccess({ assetId: asset.assetId }));
        return 7;
      },
    },
  };
  const context = vm.createContext({
    window,
    document: { addEventListener() {} },
    TextEncoder,
    DOMParser: class {},
    console,
    setTimeout,
    clearTimeout,
    queueMicrotask,
  });
  vm.runInContext(source, context, { filename: "notes.js" });
  return { window, note, context, inline: () => inlineOptions, patch: () => patchCall };
}

test("fieldControl delegates title rename and metadata-only acknowledged save", async () => {
  const f = fixture();
  assert.equal(f.window.NRCNotes.fieldControl(f.note, "title", { rename: true }), "<i>field</i>");
  assert.equal(f.inline().display, "RENAME");
  assert.equal(f.inline().required, true);
  await f.inline().save("  New title  ");
  assert.equal(f.patch().payload, null, "metadata must not rewrite unloaded content or attachments");
  const preview = JSON.parse(f.patch().preview);
  assert.equal(preview.title, "New title");
  assert.equal(preview.teaser, "keep");
  assert.deepEqual(preview.future, { key: 1 });
  assert.equal(f.patch().asset.updatedAt, 99n);
});

test("fieldControl normalizes tags and rejects invalid title before writing", async () => {
  const f = fixture();
  f.window.NRCNotes.fieldControl(f.note, "tags");
  await f.inline().save(" one, two, one ");
  assert.deepEqual(JSON.parse(f.patch().preview).tags, ["one", "two"]);

  f.window.NRCNotes.fieldControl(f.note, "title");
  await assert.rejects(f.inline().save("   "), /required/);
});

test("fieldControl rejects failed ACK and does not resolve optimistically", async () => {
  const f = fixture();
  f.window.NRCTransactions.sendAssetMetadataPatch = (_asset, _preview, _payload, options) => {
    queueMicrotask(() => options.onError({ message: "conflict" }));
    return 8;
  };
  f.window.NRCNotes.fieldControl(f.note, "project");
  await assert.rejects(f.inline().save("new"), /conflict/);
});

test("note writes await authoritative reconciliation and retry with the refreshed version", async () => {
  const f = fixture();
  const reads = [];
  const writes = [];
  f.window.NRCAssets.sendGetAsset = (_room, _id, callbacks) => { reads.push(callbacks); return 1; };
  f.window.NRCTransactions.sendAssetMetadataPatch = (asset, preview, _payload, callbacks) => {
    writes.push({ asset, preview, callbacks }); return 2;
  };
  f.window.NRCNotes.fieldControl(f.note, "project");
  const save = f.inline().save;
  let finished = false;
  const first = save("Next").then(() => { finished = true; });
  assert.equal(writes.length, 0, "never compose a write before the fresh read");
  reads.shift().onSuccess({ asset: f.note });
  await Promise.resolve();
  writes[0].callbacks.onSuccess({ assetId: 12n });
  await Promise.resolve();
  assert.equal(finished, false, "transaction ACK alone is not completion");
  await assert.rejects(save("Overlap"), /IN PROGRESS/);
  const committed = { ...f.note, updatedAt: 100n, preview: writes[0].preview };
  reads.shift().onSuccess({ asset: committed });
  await first;

  const retry = save("Final");
  reads.shift().onSuccess({ asset: committed });
  await Promise.resolve();
  assert.equal(writes[1].asset.updatedAt, 100n, "stale field closures do not reuse their old version");
  writes[1].callbacks.onError({ message: "conflict" });
  await assert.rejects(retry, /conflict/);
  const afterConflict = save("Final");
  reads.shift().onSuccess({ asset: { ...committed, updatedAt: 101n } });
  await Promise.resolve();
  assert.equal(writes[2].asset.updatedAt, 101n);
  writes[2].callbacks.onSuccess({ assetId: 12n });
  await Promise.resolve();
  reads.shift().onSuccess({ asset: { ...committed, updatedAt: 102n } });
  await afterConflict;
});

test("checkbox and inline note writes exclude each other in both directions", async () => {
  const f = fixture();
  f.context.note = f.note;
  vm.runInContext('notifyNoteSaveError = () => {};', f.context);
  f.window.NRCNotes.fieldControl(f.note, "project");
  const pending = f.inline().save("Next");
  vm.runInContext('queueNoteMarkdownUpdate(note, "- [x] done");', f.context);
  assert.equal(vm.runInContext("noteMarkdownUpdates.size", f.context), 0, "refuse before creating an optimistic checkbox draft");
  await pending;

  let checkboxCallbacks;
  f.window.NRCAssets.AssetType = { Note: 5 };
  f.window.NRCAssets.sendUpdateAsset = (...args) => { checkboxCallbacks = args[6]; return 1; };
  vm.runInContext('queueNoteMarkdownUpdate(note, "- [x] done");', f.context);
  assert.equal(vm.runInContext("noteMarkdownUpdates.size", f.context), 1);
  await assert.rejects(f.inline().save("Overlap"), /IN PROGRESS/);
  checkboxCallbacks.onSuccess({ asset: f.note });
  assert.equal(vm.runInContext("noteMarkdownUpdates.size", f.context), 0);
  await f.inline().save("After checkbox");
});
