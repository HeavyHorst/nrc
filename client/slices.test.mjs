import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const source = fs.readFileSync(path.resolve("client/slices.js"), "utf8");

const IDLE_CONTROLLER = () => ({
  update() {}, disconnect() {}, handlePage() {}, handleProjects() {},
  getState: () => ({ mode: "idle", tasks: new Map(), total: 0 }),
});

function loadSlices(overrides = {}) {
  const sent = [];
  const baseWindow = {
    NRCAssets: {
      generateCorrelationId: () => 7,
      roomAssets: new Map(),
      sendListAssetsPagedByProject: () => 1,
      requestAsset: (convId, assetId, { onSuccess } = {}) => {
        onSuccess?.({ asset: null });
        return 1;
      },
      MAX_PREVIEW_LENGTH: 4096,
    },
    NRCEdges: {
      requestEdgePage: () => Promise.resolve({}),
      getLinkedAssetsForNote: () => [],
      getEdgesForEntity: () => [],
      sendCreateEdge: () => 1,
      sendDeleteEdge: () => 1,
      // The slice module reads the entity and relation kinds from the edge
      // module, so the stub carries the same table the protocol defines.
      TargetType: { Asset: 1, Task: 2 },
      RelationType: { References: 1, RelatedTo: 2, DependsOn: 3, Blocks: 4, DerivedFrom: 5, Supersedes: 6, MemberOf: 7 },
    },
    NRCTasks: { selectTask() {}, sendUpdateTask: () => 1 },
    createTaskQueryController: IDLE_CONTROLLER,
  };
  const { window: windowOverrides, ...rest } = overrides;
  const sandbox = {
    // The register signals a changed list through a document event; the harness
    // records it so a case can assert the signal instead of assuming it.
    document: {
      getElementById: () => null, addEventListener() {}, querySelectorAll: () => [],
      dispatched: [],
      dispatchEvent(event) { this.dispatched.push(event); },
    },
    CustomEvent: class {
      constructor(type, options) { this.type = type; this.detail = options?.detail ?? null; }
    },
    TaskViewState: { grouping: "slices" },
    serverReady: true,
    ws: { readyState: 1, send: (buffer) => sent.push(buffer) },
    WebSocket: { OPEN: 1 },
    localPacketsOut: 0,
    TextEncoder,
    TextDecoder,
    setTimeout,
    clearTimeout,
    console,
    ...rest,
    window: {
      ...baseWindow,
      ...(windowOverrides ?? {}),
      NRCAssets: { ...baseWindow.NRCAssets, ...(windowOverrides?.NRCAssets ?? {}) },
      NRCEdges: { ...baseWindow.NRCEdges, ...(windowOverrides?.NRCEdges ?? {}) },
      NRCTasks: { ...baseWindow.NRCTasks, ...(windowOverrides?.NRCTasks ?? {}) },
    },
  };
  vm.runInNewContext(source, sandbox);
  sandbox.window.NRCSlices.__sent = sent;
  sandbox.window.NRCSlices.__dispatched = sandbox.document.dispatched;
  return sandbox.window.NRCSlices;
}

// The record's fields are read when the record is written, so a test supplies
// what the user would have typed into them.
function sliceFields({ outcome = "", owner = "" } = {}) {
  return {
    document: {
      getElementById: (id) => {
        if (id === "sliceOutcome") return { value: outcome };
        if (id === "sliceOwner") return { value: owner };
        return null;
      },
      addEventListener() {},
      querySelectorAll: () => [],
      dispatchEvent() {},
    },
  };
}

// The wire layout below mirrors protocol/tasks.odin serializeTaskSliceList, so a
// change to one side without the other fails here rather than in the browser.
function encodeSliceList({ convId = 0n, success = true, hasMore = false, nextCursor = null, total = 0, assignedTasks = 0, unassignedTasks = 0, error = "", correlationId = 7, slices = [] } = {}) {
  const encoder = new TextEncoder();
  const errorBytes = encoder.encode(error);
  const encoded = slices.map((slice) => ({
    name: encoder.encode(slice.name ?? ""),
    owner: encoder.encode(slice.owner ?? ""),
    slice,
  }));
  let size = 2 + 8 + 1 + 2 + 1 + 1 + 8 + 8 + 4 + 4 + 4 + 2 + errorBytes.length + 4;
  for (const entry of encoded) size += 2 + entry.name.length + 8 + 2 + entry.owner.length + 1 + 14 + 16;
  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint16(offset, 164, false); offset += 2;
  view.setBigUint64(offset, convId, false); offset += 8;
  view.setUint8(offset, success ? 1 : 0); offset += 1;
  view.setUint16(offset, encoded.length, false); offset += 2;
  for (const entry of encoded) {
    const slice = entry.slice;
    view.setUint16(offset, entry.name.length, false); offset += 2;
    new Uint8Array(buffer, offset, entry.name.length).set(entry.name); offset += entry.name.length;
    view.setBigUint64(offset, BigInt(slice.sliceId ?? 0), false); offset += 8;
    view.setUint16(offset, entry.owner.length, false); offset += 2;
    new Uint8Array(buffer, offset, entry.owner.length).set(entry.owner); offset += entry.owner.length;
    view.setUint8(offset, slice.flags ?? 0); offset += 1;
    view.setUint16(offset, slice.backlog ?? 0, false); offset += 2;
    view.setUint16(offset, slice.todo ?? 0, false); offset += 2;
    view.setUint16(offset, slice.inProgress ?? 0, false); offset += 2;
    view.setUint16(offset, slice.done ?? 0, false); offset += 2;
    view.setUint16(offset, slice.blocked ?? 0, false); offset += 2;
    view.setUint16(offset, slice.notes ?? 0, false); offset += 2;
    view.setUint16(offset, slice.files ?? 0, false); offset += 2;
    view.setBigInt64(offset, BigInt(slice.oldestActiveAt ?? 0), false); offset += 8;
    view.setBigInt64(offset, BigInt(slice.lastMovedAt ?? 0), false); offset += 8;
  }
  view.setUint8(offset, hasMore ? 1 : 0); offset += 1;
  view.setUint8(offset, nextCursor?.closed ? 1 : 0); offset += 1;
  view.setBigInt64(offset, BigInt(nextCursor?.sortAt ?? 0), false); offset += 8;
  view.setBigUint64(offset, BigInt(nextCursor?.sliceId ?? 0), false); offset += 8;
  view.setUint32(offset, total, false); offset += 4;
  view.setUint32(offset, assignedTasks, false); offset += 4;
  view.setUint32(offset, unassignedTasks, false); offset += 4;
  view.setUint16(offset, errorBytes.length, false); offset += 2;
  new Uint8Array(buffer, offset, errorBytes.length).set(errorBytes); offset += errorBytes.length;
  view.setUint32(offset, correlationId, false); offset += 4;
  assert.equal(offset, size, "encoder must fill the declared frame exactly");
  return new DataView(buffer);
}

test("slice list request uses opcode 56 with the include_closed flag and correlation id", () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  assert.equal(slices.__sent.length, 1);
  const view = new DataView(slices.__sent[0]);
  assert.equal(view.getUint16(0, false), 56);
  assert.equal(view.getBigUint64(2, false), 0n);
  assert.equal(view.getUint8(10), 0, "closed slices are excluded by default");
  assert.equal(view.getUint8(11), 0, "no owner filter");
  assert.equal(view.getUint16(12, false), 0, "no owner");
  assert.equal(view.getUint8(14), 0, "no name filter");
  assert.equal(view.getUint16(15, false), 0, "no name");
  assert.equal(view.getUint16(17, false), 100, "the register draws a page at a time");
  assert.equal(view.getUint8(19), 0, "the first page carries no cursor");
  assert.equal(view.getUint32(20, false), 7);
  assert.equal(view.byteLength, 24, "the request is the fields it carries");

  slices.setIncludeClosed(true);
  const view2 = new DataView(slices.__sent[1]);
  assert.equal(view2.getUint8(10), 1);
  assert.equal(view2.getUint32(20, false), 7);
});

test("slice list decode reads counters, closure and the work counters", () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({
    total: 2,
    assignedTasks: 21,
    unassignedTasks: 15,
    slices: [
      { name: "Alpha", sliceId: 77n, owner: "rene", flags: 1, backlog: 1, todo: 2, inProgress: 3, done: 4, blocked: 5, notes: 6, files: 7, oldestActiveAt: 111, lastMovedAt: 222 },
      { name: "Beta", sliceId: 78n, todo: 1, lastMovedAt: 333 },
    ],
  }));

  const state = slices.getState();
  assert.equal(state.mode, "ready");
  assert.equal(state.slices.length, 2);
  assert.equal(state.total, 2);
  assert.equal(state.assignedTasks, 21);
  assert.equal(state.unassignedTasks, 15, "work without a slice is reported, not hidden");

  const alpha = state.slices[0];
  assert.equal(alpha.name, "Alpha");
  assert.equal(alpha.sliceId, 77n);
  assert.equal(alpha.owner, "rene");
  assert.equal(slices.isClosed(alpha), true);
  assert.equal(slices.taskCount(alpha), 10, "tasks are the members with a status");
  assert.equal(slices.memberCount(alpha), 23, "members are tasks, notes and files");
  assert.equal(slices.openCount(alpha), 6);
  assert.equal(alpha.blocked, 5);
  assert.equal(alpha.notes, 6);
  assert.equal(alpha.files, 7);
  assert.equal(alpha.oldestActiveAt, 111n);
  assert.equal(alpha.lastMovedAt, 222n);

  const beta = state.slices[1];
  assert.equal(beta.name, "Beta");
  assert.equal(beta.sliceId, 78n);
  assert.equal(slices.isClosed(beta), false);
  assert.equal(slices.memberCount(beta), 1);
});

test("a failed slice listing surfaces the server error instead of empty data", () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ success: false, error: "Slice listing allocation failed" }));
  const state = slices.getState();
  assert.equal(state.mode, "error");
  assert.equal(state.error, "Slice listing allocation failed");
  assert.equal(state.slices.length, 0);
});

test("a superseded slice listing is ignored", () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 999, slices: [{ name: "Stale" }] }));
  assert.equal(slices.getState().slices.length, 0, "a response for another request must not land");

  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Fresh" }] }));
  assert.equal(slices.getState().slices.length, 1);
  assert.equal(slices.getState().slices[0].name, "Fresh");
});

// The register is the whole surface on a phone and the record is a drill-in, so
// the tap that opens it must work on the preselected row too.
function sliceView({ mobile }) {
  const view = { dataset: {}, addEventListener() {}, querySelector: () => null };
  const slices = loadSlices({
    document: {
      getElementById: (id) => (id === "sliceView" ? view : null),
      addEventListener() {},
      querySelectorAll: () => [],
    },
    window: { matchMedia: () => ({ matches: mobile }) },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n }] }));
  return { slices, view };
}

test("a phone tap drills into the record even when the row is already selected", () => {
  const { slices, view } = sliceView({ mobile: true });
  assert.equal(slices.getState().selected, "Alpha", "the listing preselects its first slice");
  slices.select("Alpha");
  assert.equal(view.dataset.sliceMobileDetail, "true", "the record replaces the register");

  slices.select("Alpha");
  assert.equal(slices.getState().selected, "Alpha", "re-selecting keeps the selection");
  assert.equal(view.dataset.sliceMobileDetail, "true");
});

test("a wide viewport keeps register and record side by side", () => {
  const { slices, view } = sliceView({ mobile: false });
  slices.select("Alpha");
  assert.equal(view.dataset.sliceMobileDetail, undefined, "the drill-in belongs to phones");
});

// Deleting asks before it sends, so a test supplies the answer and the asset RPC
// the record's own controls use. `members` is the slice's task count: it is what
// the dialog has to name, and what the release has to report.
function deletableSlices({ confirmed = true, members = 1 } = {}) {
  const deleted = [];
  const dialogs = [];
  const slices = loadSlices({
    window: {
      NRCDialog: {
        confirm: (message, options) => {
          dialogs.push({ message, options });
          return Promise.resolve(confirmed);
        },
      },
      NRCAssets: {
        sendDeleteAsset: (convId, assetId, requestOptions) => {
          deleted.push({ convId, assetId, requestOptions });
          requestOptions?.onSuccess?.();
          return 1;
        },
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, todo: members }] }));
  return { slices, deleted, dialogs };
}

test("deleting a slice names what it releases before anything is sent", async () => {
  const { slices, deleted, dialogs } = deletableSlices();
  const sent = await slices.deleteSlice(slices.selectedSlice());

  assert.equal(sent, true);
  assert.equal(dialogs.length, 1, "the delete asks first");
  assert.equal(dialogs[0].options.title, "DELETE SLICE");
  assert.match(dialogs[0].message, /Delete slice “Alpha”\?/);
  assert.match(dialogs[0].message, /1 membership is released/);
  assert.match(dialogs[0].message, /The tasks, notes and files themselves stay/);

  assert.equal(deleted.length, 1, "one delete is sent");
  assert.equal(deleted[0].convId, 0n, "a slice lives in the workspace scope");
  assert.equal(deleted[0].assetId, 5n);
  assert.equal(slices.getState().selected, null, "the deleted record closes");
});

test("a declined delete sends nothing and keeps the record", async () => {
  const { slices, deleted } = deletableSlices({ confirmed: false });
  const sent = await slices.deleteSlice(slices.selectedSlice());

  assert.equal(sent, false);
  assert.equal(deleted.length, 0);
  assert.equal(slices.getState().selected, "Alpha");
});

test("an empty slice says so instead of counting memberships", async () => {
  const { slices, dialogs } = deletableSlices({ members: 0 });
  await slices.deleteSlice(slices.selectedSlice());
  assert.match(dialogs[0].message, /nothing was assigned to it/);
});

test("a slice deleted elsewhere closes its record and refreshes the register", () => {
  const { slices } = deletableSlices();
  assert.equal(slices.getState().selected, "Alpha");

  slices.onAssetDeleted(0n, 6n);
  assert.equal(slices.getState().selected, "Alpha", "another slice's delete leaves this record open");
  slices.onAssetDeleted(1n, 5n);
  assert.equal(slices.getState().selected, "Alpha", "a chat conversation's delete is not a slice delete");

  slices.onAssetDeleted(0n, 5n);
  assert.equal(slices.getState().selected, null, "the deleted slice closes its record");
});

const settleMicrotasks = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a completed note mutation refreshes the member snapshot without reloading the slice register", () => {
  const slices = loadSlices();
  const old = { convId: 0n, assetId: 12n, assetType: 5, preview: '{"title":"Old"}' };
  slices.getState().notes = { mode: "ready", assets: [old] };
  const next = { ...old, preview: '{"title":"Renamed"}' };
  slices.onAssetChanged(next, "cache", 0);
  assert.equal(slices.getState().notes.assets[0], old, "ordinary reads cannot trigger mutation refreshes");
  slices.onAssetChanged(next, "mutation", 0);
  assert.equal(slices.getState().notes.assets[0].preview, '{"title":"Renamed"}');
  assert.equal(slices.__sent.length, 0, "updating a member snapshot cannot loop through the slice listing");
});

test("a slice record changed elsewhere refreshes the register", async () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, owner: "rene" }] }));
  const before = slices.__sent.length;

  slices.onAssetChanged({ convId: 0n, assetId: 5n, assetType: 11 }, "cache", 0);
  slices.onAssetChanged({ convId: 1n, assetId: 5n, assetType: 11 }, "mutation", 0);
  slices.onAssetChanged({ convId: 0n, assetId: 6n, assetType: 2 }, "mutation", 0);
  slices.onAssetChanged({ convId: 0n, assetId: 5n, assetType: 11 }, "mutation", 99);
  await new Promise((resolve) => setTimeout(resolve, 140));
  assert.equal(slices.__sent.length, before, "cache fills and unrelated assets cannot loop back into the listing");

  slices.onAssetChanged({ convId: 0n, assetId: 5n, assetType: 11 }, "mutation", 0);
  await new Promise((resolve) => setTimeout(resolve, 140));
  assert.equal(slices.__sent.length, before + 1, "the remote slice mutation asks for a fresh listing");
});

test("a membership edge changed elsewhere refreshes the register and selected record", async () => {
  let edgeListener = null;
  let detailReads = 0;
  const slices = loadSlices({
    window: {
      NRCEdges: {
        addEdgeChangeListener: (listener) => { edgeListener = listener; },
        requestEdgePage: () => { detailReads++; return Promise.resolve({}); },
      },
    },
  });
  assert.equal(typeof edgeListener, "function", "the slice module subscribes to edge broadcasts");
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, todo: 1 }] }));
  await settleMicrotasks();
  const beforeFrames = slices.__sent.length;
  const beforeDetails = detailReads;

  edgeListener({ convId: 0n, edgeId: 9n, sourceType: 2, sourceId: 42n, targetType: 1, targetId: 5n, relation: 7 }, "created", 0);
  await new Promise((resolve) => setTimeout(resolve, 140));
  assert.equal(slices.__sent.length, beforeFrames + 1, "membership changes ask for fresh slice counters");
  assert.equal(detailReads, beforeDetails + 1, "the open slice reloads its member rows");

  const afterMembership = slices.__sent.length;
  edgeListener({ convId: 0n, edgeId: 10n, sourceId: 42n, targetId: 5n, relation: 2 }, "created", 0);
  await new Promise((resolve) => setTimeout(resolve, 140));
  assert.equal(slices.__sent.length, afterMembership, "ordinary graph edges do not refresh slices");
});

// A refresh must not take the member rows off the screen. A click whose press
// lands on the old row and whose release lands on the new one is dispatched at
// the container, where it names no member and is lost.
test("a refresh keeps the member list on screen instead of blanking it", async () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n }] }));
  assert.equal(slices.getState().members.mode, "loading", "the first read has nothing to show yet");
  await settleMicrotasks();
  assert.equal(slices.getState().members.mode, "ready");
  assert.equal(slices.getState().detailSliceId, 5n);

  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n }] }));
  assert.equal(slices.getState().members.mode, "ready", "a refresh keeps the rows that are on screen");
  assert.equal(slices.getState().detailSliceId, 5n, "the rows still belong to this slice");
});

test("a failed refresh keeps the last known list and says it is stale", async () => {
  let failing = false;
  const slices = loadSlices({
    window: {
      NRCEdges: {
        requestEdgePage: () => (failing ? Promise.reject(new Error("offline")) : Promise.resolve({})),
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, todo: 2 }] }));
  await settleMicrotasks();
  assert.equal(slices.getState().members.mode, "ready");
  assert.equal(slices.getState().refreshError, "");

  failing = true;
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, todo: 2 }] }));
  await settleMicrotasks();
  assert.equal(slices.getState().members.mode, "ready", "the reader keeps the list it can still use");
  assert.equal(slices.getState().detailSliceId, 5n);
  assert.match(slices.getState().refreshError, /last known list/);
});

test("a failed first read reports the failure instead of an empty list", async () => {
  const slices = loadSlices({
    window: { NRCEdges: { requestEdgePage: () => Promise.reject(new Error("offline")) } },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n }] }));
  await settleMicrotasks();
  assert.equal(slices.getState().members.mode, "error");
  assert.equal(slices.getState().detailSliceId, null);
  assert.equal(slices.getState().refreshError, "");
});

test("a failed member read does not expose a partially loaded record", async () => {
  const slices = loadSlices({ window: {
    NRCEdges: {
      getEdgesForEntity: () => [
        { edgeId: 1n, relation: 7, sourceType: 2, sourceId: 42n, targetType: 1, targetId: 5n },
      ],
    },
    NRCTasks: {
      requestTask: (convId, id, { onError } = {}) => {
        onError?.({ message: "Member unavailable" });
        return 1;
      },
    },
  } });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, todo: 1 }] }));
  await settleMicrotasks();

  assert.equal(slices.getState().detail.mode, "error");
  assert.equal(slices.getState().detailSliceId, null);
  assert.equal(slices.getState().detail.error, "Member unavailable");
});

test("the strip renders one mark per member and caps the row", () => {
  const slices = loadSlices();
  const marks = [
    { status: "done", blocked: false },
    { status: "inprogress", blocked: false },
    { status: "todo", blocked: true },
    { status: "backlog", blocked: false },
  ];
  const html = slices.renderStrip(marks, 24);
  assert.equal((html.match(/slice-mark"/g) ?? []).length, 1, "backlog uses the base mark class");
  assert.match(html, /slice-mark--done/);
  assert.match(html, /slice-mark--inprogress/);
  assert.match(html, /slice-mark--todo slice-mark--blocked/, "a blocked member keeps its status and gains the spike");
  assert.doesNotMatch(html, /slice-strip-overflow/);

  const capped = slices.renderStrip(marks, 2);
  assert.match(capped, /slice-strip--overflow/);
  assert.match(capped, /slice-strip-overflow">\+2</);
});

// The register holds counters, not members: its shape is the share each status
// holds, and the blocked share drawn against the whole slice. A blocked count
// cannot name the member it belongs to, so it is never drawn in a member's
// place — which is what the register's red spike used to do.
test("the register draws counters as shares, never as member marks", () => {
  const slices = loadSlices();
  const html = slices.renderShape({ backlog: 2, todo: 1, inProgress: 1, done: 1, blocked: 2 });

  assert.equal((html.match(/slice-bar-seg--(?:backlog|todo|inprogress|done)"/g) ?? []).length, 4,
    "one segment per status that has members");
  assert.match(html, /slice-bar-seg--backlog" style="--slice-share:2"/);
  assert.match(html, /slice-bar-seg--todo" style="--slice-share:1"/);
  assert.match(html, /slice-bar-seg--inprogress" style="--slice-share:1"/);
  assert.match(html, /slice-bar-seg--done" style="--slice-share:1"/);
  assert.doesNotMatch(html, /slice-mark/, "a register never draws a member");

  // Blocked is its own bar: the track is the whole slice and the red segment is
  // the share of it that is blocked.
  assert.match(html, /slice-bar--blocked/);
  assert.match(html, /slice-bar-seg--blocked" style="--slice-share:2"/);
  assert.match(html, /slice-bar-track" style="--slice-share:3"/);

  // A status without members has no segment, and a slice without a blocked
  // member has no blocked bar at all.
  const clean = slices.renderShape({ backlog: 0, todo: 1, inProgress: 0, done: 0, blocked: 0 });
  assert.doesNotMatch(clean, /slice-bar-seg--backlog/);
  assert.doesNotMatch(clean, /slice-bar--blocked/);

  // A blocked count larger than the member count cannot invent members, so the
  // share never exceeds the whole and the track that is left is empty.
  const overcounted = slices.renderShape({ backlog: 1, todo: 0, inProgress: 0, done: 0, blocked: 5 });
  assert.match(overcounted, /slice-bar-seg--blocked" style="--slice-share:1"/);
  assert.match(overcounted, /slice-bar-track" style="--slice-share:0"/);

  // A slice that carries no task members says so instead of drawing an empty bar.
  const memberless = slices.renderShape({ backlog: 0, todo: 0, inProgress: 0, done: 0, blocked: 0, notes: 2 });
  assert.match(memberless, /slice-bar--empty/);
  assert.doesNotMatch(memberless, /slice-bar-seg/);
});

// The record changes as one unit: while any read is pending, the previous DOM is
// kept inert instead of exposing counters, fields and partial member tables.
test("the record stays unchanged until the slice and all members are loaded", async () => {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        id, innerHTML: "", textContent: "", value: "", hidden: false, dataset: {},
        setAttribute() {}, getAttribute: () => null, hasAttribute: () => false,
        querySelector: () => null, querySelectorAll: () => [], contains: () => false, focus() {},
        addEventListener() {},
      });
    }
    return elements.get(id);
  };
  const slices = loadSlices({
    document: {
      activeElement: null,
      getElementById: element,
      addEventListener() {},
      querySelectorAll: () => [],
    },
    window: {
      NRCEdges: {
        requestEdgePage: () => Promise.resolve({}),
        getEdgesForEntity: () => [
          { edgeId: 1n, relation: 7, sourceType: 2, sourceId: 42n, targetType: 1, targetId: 5n },
        ],
        TargetType: { Asset: 1, Task: 2 },
        RelationType: { RelatedTo: 2, MemberOf: 7 },
      },
      NRCTasks: {
        requestTask: (convId, id, { onSuccess } = {}) => {
          onSuccess?.({ task: { id, convId: 0n, title: "Member task", status: 3, priority: 0, createdAt: 1n } });
          return 1;
        },
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({
    correlationId: 7,
    slices: [{ name: "Alpha", sliceId: 5n, backlog: 1, done: 2, blocked: 1 }],
  }));

  const loading = element("sliceRecord").innerHTML;
  assert.match(loading, /Select a slice/, "the previous record remains until every read settles");
  assert.equal(element("sliceRecord").inert, true, "the retained record cannot act on the new selection");

  await settleMicrotasks();
  const ready = element("sliceRecord").innerHTML;
  assert.equal(element("sliceRecord").inert, false);
  assert.match(ready, /CREATION ORDER, OLDEST LEFT/);
  assert.match(ready, /slice-strip--wide/);
  assert.match(ready, /slice-mark--done/, "the loaded member keeps its status mark");
  assert.match(ready, /slice-strip-legend/, "the legend belongs to the strip it explains");
  assert.doesNotMatch(ready, /slice-bar-group/);
});

test("write requests are refused while disconnected and do not claim success", () => {
  const slices = loadSlices({ serverReady: false });
  slices.requestList({ force: true });
  slices.createSlice("Alpha");
  assert.match(slices.getState().writeError, /OFFLINE/);
  assert.equal(slices.__sent.length, 0, "a disconnected client sends nothing at all");
  assert.equal(slices.getState().writePending, false, "a refused write is not left pending");
});

test("the record renders the outcome it holds, so a later close cannot erase it", async () => {
  // The listing carries the counters, but the owner, the outcome and the closure
  // live in the slice record. A record field rendered from the listing would come
  // out empty, and the next close or reopen would write that emptiness back.
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        id, innerHTML: "", textContent: "", value: "", hidden: false, dataset: {},
        setAttribute() {}, getAttribute: () => null, hasAttribute: () => false,
        querySelector: () => null, querySelectorAll: () => [], contains: () => false, focus() {},
        addEventListener() {},
      });
    }
    return elements.get(id);
  };
  const slices = loadSlices({
    myNickname: "rene",
    document: {
      activeElement: null,
      getElementById: element,
      addEventListener() {},
      querySelectorAll: () => [],
    },
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map([[5n, {
          assetId: 5n,
          assetType: 11,
          preview: JSON.stringify({ version: 1, name: "Alpha", owner: "anke", outcome: "Ship the register." }),
        }]])]]),
        sendUpdateAsset: () => 1,
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n, owner: "anke" }] }));
  await settleMicrotasks();

  const markup = element("sliceRecord").innerHTML;
  assert.match(markup, /id="sliceOutcome"[^>]*>Ship the register\.<\/textarea>/, "the outcome field carries the record");
  assert.match(markup, /id="sliceOwner"[^>]*value="anke"/, "the owner field carries the record");

  const listed = slices.getState().slices[0];
  assert.equal(listed.outcome, undefined, "the listing itself never carries the outcome");
});

// A member row is the click target, not only its title: the row carries the
// reference, and the opener inside it carries its own identity so a re-render
// can put focus back on the control the keyboard reached.
test("a member row carries the reference and its opener the focus identity", async () => {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        id, innerHTML: "", textContent: "", value: "", hidden: false, dataset: {},
        setAttribute() {}, getAttribute: () => null, hasAttribute: () => false,
        querySelector: () => null, querySelectorAll: () => [], contains: () => false, focus() {},
        addEventListener() {},
      });
    }
    return elements.get(id);
  };
  const roomAssets = new Map([[0n, new Map([
    [5n, { assetId: 5n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Alpha" }) }],
    [204n, { assetId: 204n, assetType: 5, preview: JSON.stringify({ title: "Member note" }), createdAt: 1n, updatedAt: 2n }],
    [205n, { assetId: 205n, assetType: 3, preview: JSON.stringify({ title: "member.svg", category: "Diagram", size: "412 KB" }), createdAt: 1n, updatedAt: 2n }],
  ])]]);
  const slices = loadSlices({
    document: {
      activeElement: null,
      getElementById: element,
      addEventListener() {},
      querySelectorAll: () => [],
    },
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets,
        requestAsset: (convId, assetId, { onSuccess } = {}) => {
          onSuccess?.({ asset: roomAssets.get(0n).get(assetId) });
          return 1;
        },
        MAX_PREVIEW_LENGTH: 4096,
      },
      NRCEdges: {
        requestEdgePage: () => Promise.resolve({}),
        getEdgesForEntity: () => [
          { edgeId: 1n, relation: 7, sourceType: 2, sourceId: 42n, targetType: 1, targetId: 5n },
          { edgeId: 2n, relation: 7, sourceType: 1, sourceId: 204n, targetType: 1, targetId: 5n },
          { edgeId: 3n, relation: 7, sourceType: 1, sourceId: 205n, targetType: 1, targetId: 5n },
        ],
        TargetType: { Asset: 1, Task: 2 },
        RelationType: { RelatedTo: 2, MemberOf: 7 },
      },
      NRCTasks: {
        requestTask: (convId, id, { onSuccess } = {}) => {
          onSuccess?.({ task: { id, convId: 0n, title: "Member task", status: 1, priority: 3, createdAt: 1n } });
          return 1;
        },
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n, todo: 1, notes: 1, files: 1 }] }));
  await settleMicrotasks();

  const markup = element("sliceRecord").innerHTML;
  assert.match(markup, /class="slice-member slice-member--task" data-member-task="42"/, "the task row is the click target");
  assert.match(markup, /class="slice-member-open" data-member-open="task:42"/, "the task opener carries its own identity");
  // The status a member row draws is the control that changes it: the same token
  // the flat register draws, carrying the task it would move.
  assert.match(markup, /<button type="button" class="status-badge task-row-status status-todo" data-member-status="42" aria-haspopup="listbox"/, "a member's status is the control that changes it");
  assert.match(markup, /class="slice-member slice-member--plain" data-member-note="204"/, "the note row is the click target");
  assert.match(markup, /class="slice-member-open" data-member-open="note:204"/, "the note opener carries its own identity");
  assert.match(markup, /class="slice-member slice-member--file" data-member-file="205"/, "the file row is the click target");
  assert.match(markup, /class="slice-member-open" data-member-open="file:205"/, "the file opener carries its own identity");
  assert.doesNotMatch(markup, /class="slice-member-open" data-member-(?:task|note|file)=/, "an opener does not repeat the row's reference");
});

test("keyboard focus gives one slice member the shared selected-row state", () => {
  const listeners = {};
  const record = { selected: [], querySelectorAll: () => record.selected };
  const member = (identity) => {
    const classes = new Set(["slice-member"]);
    const attributes = new Map();
    const row = {
      classList: {
        add: (name) => classes.add(name),
        remove: (name) => classes.delete(name),
        contains: (name) => classes.has(name),
      },
      closest: (selector) => selector === "#sliceRecord" ? record : null,
      querySelector: (selector) => selector === ".slice-member-open" ? opener : null,
    };
    const opener = {
      dataset: { memberOpen: identity },
      closest: (selector) => selector === ".slice-member-open" ? opener : selector === ".slice-member" ? row : null,
      setAttribute: (name, value) => attributes.set(name, value),
      removeAttribute: (name) => attributes.delete(name),
      getAttribute: (name) => attributes.get(name) ?? null,
    };
    return { row, opener };
  };
  const first = member("task:41");
  const second = member("note:52");
  const view = {
    style: {}, dataset: {},
    addEventListener: (type, listener) => { listeners[type] = listener; },
    querySelector: () => null,
  };
  loadSlices({
    document: {
      activeElement: null,
      getElementById: (id) => id === "sliceView" ? view : id === "sliceRecord" ? record : null,
      addEventListener() {}, querySelectorAll: () => [], dispatchEvent() {},
    },
  });

  listeners.focusin({ target: first.opener });
  record.selected = [first.row];
  assert.equal(first.row.classList.contains("slice-member-selected"), true);
  assert.equal(first.opener.getAttribute("aria-current"), "true");

  listeners.focusin({ target: second.opener });
  assert.equal(first.row.classList.contains("slice-member-selected"), false, "the previous row is cleared");
  assert.equal(first.opener.getAttribute("aria-current"), null);
  assert.equal(second.row.classList.contains("slice-member-selected"), true);
  assert.equal(second.opener.getAttribute("aria-current"), "true");
});

// A move is confirmed before it is drawn anywhere, and a member table holds its
// own snapshot of a task: the confirmation is what the row reads, so the status
// cannot stay behind when the move took the task out of the partial task cache
// the flat register draws from.
test("a member row keeps the status a confirmed move answered with", async () => {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        id, innerHTML: "", textContent: "", value: "", hidden: false, dataset: {},
        setAttribute() {}, getAttribute: () => null, hasAttribute: () => false,
        querySelector: () => null, querySelectorAll: () => [], contains: () => false, focus() {},
        addEventListener() {},
      });
    }
    return elements.get(id);
  };
  const roomAssets = new Map([[0n, new Map([
    [5n, { assetId: 5n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Alpha" }) }],
  ])]]);
  const slices = loadSlices({
    document: {
      activeElement: null,
      getElementById: element,
      addEventListener() {},
      querySelectorAll: () => [],
    },
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets,
        requestAsset: (convId, assetId, { onSuccess } = {}) => {
          onSuccess?.({ asset: roomAssets.get(0n).get(assetId) });
          return 1;
        },
        MAX_PREVIEW_LENGTH: 4096,
      },
      NRCEdges: {
        requestEdgePage: () => Promise.resolve({}),
        getEdgesForEntity: () => [
          { edgeId: 1n, relation: 7, sourceType: 2, sourceId: 42n, targetType: 1, targetId: 5n },
        ],
        TargetType: { Asset: 1, Task: 2 },
        RelationType: { RelatedTo: 2, MemberOf: 7 },
      },
      NRCTasks: {
        requestTask: (convId, id, { onSuccess } = {}) => {
          onSuccess?.({ task: { id, convId: 0n, title: "Member task", status: 1, priority: 3, createdAt: 1n } });
          return 1;
        },
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n, todo: 1 }] }));
  await settleMicrotasks();
  assert.match(element("sliceRecord").innerHTML, /status-todo/, "the drawn member starts in the status the task carried");

  slices.onTaskMoved(42n, 3, 9);
  const markup = element("sliceRecord").innerHTML;
  assert.match(markup, /class="status-badge task-row-status status-done" data-member-status="42"/, "the member token follows the confirmation");
  assert.match(markup, />DONE<\/button>/, "the member token reads the confirmed status");

  // A move for a task this record does not carry draws nothing.
  slices.onTaskMoved(99n, 3, 0);
  assert.equal(element("sliceRecord").innerHTML, markup, "another task's move leaves the record alone");
});

// The record's owner and outcome are live fields, so a selection change asks
// before it replaces them — a click and an arrow key both go through the guard.
test("a selection change asks before it discards unsaved record edits", async () => {
  const dialogs = [];
  let confirmed = false;
  const typed = { owner: "anke", outcome: "Typed but unsaved." };
  const slices = loadSlices({
    document: {
      activeElement: null,
      getElementById: (id) => {
        if (id === "sliceOwner") return { value: typed.owner };
        if (id === "sliceOutcome") return { value: typed.outcome };
        return null;
      },
      addEventListener() {},
      querySelectorAll: () => [],
    },
    window: {
      NRCDialog: {
        confirm: (message, options) => {
          dialogs.push({ message, options });
          return Promise.resolve(confirmed);
        },
      },
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map([
          [5n, { assetId: 5n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Alpha", owner: "rene", outcome: "Ship the register." }) }],
          [6n, { assetId: 6n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Beta", owner: "rene", outcome: "" }) }],
        ])]]),
        requestAsset: (convId, assetId, { onSuccess } = {}) => {
          onSuccess?.({ asset: null });
          return 1;
        },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n }, { name: "Beta", sliceId: 6n }] }));
  await settleMicrotasks();
  assert.equal(slices.getState().detailSliceId, 5n, "the fields on screen belong to Alpha");

  assert.equal(slices.recordDirty(), true, "the typed owner and outcome are unsaved");
  assert.equal(await slices.selectGuarded("Beta"), false, "a declined answer keeps the record");
  assert.equal(slices.getState().selected, "Alpha");
  assert.equal(dialogs.length, 1, "the change asks once");
  assert.equal(dialogs[0].options.title, "UNSAVED CHANGES");
  assert.match(dialogs[0].message, /Discard unsaved changes to this slice\?/);

  confirmed = true;
  assert.equal(await slices.selectGuarded("Beta"), true);
  assert.equal(slices.getState().selected, "Beta");
  await settleMicrotasks();
  assert.equal(slices.getState().detailSliceId, 6n, "the record that arrived is Beta's");

  // A record that holds what its fields hold has nothing to discard, and
  // re-selecting the slice already on screen never asks.
  const asked = dialogs.length;
  typed.owner = "rene";
  typed.outcome = "";
  assert.equal(slices.recordDirty(), false);
  assert.equal(await slices.selectGuarded("Beta"), true, "re-selecting the open slice does not ask");
  assert.equal(await slices.selectGuarded("Alpha"), true, "a clean record changes selection without a question");
  assert.equal(dialogs.length, asked, "a clean record never asks");
});

// A background refresh re-renders the record, so the fields it holds unsaved
// have to survive it — and a field the reader has not touched still follows the
// record, so an update from elsewhere stays visible.
test("a refresh keeps text the record's fields hold unsaved", async () => {
  const roomAssets = new Map([[0n, new Map([
    [5n, { assetId: 5n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Alpha", owner: "rene", outcome: "Ship the register." }) }],
  ])]]);
  // The fake fields follow what a render painted, and the text put into them by
  // the reader is what a re-render would replace.
  let painted = { owner: "", outcome: "" };
  const typed = { owner: null, outcome: null };
  const field = (id, name) => ({
    id,
    get value() { return typed[name] ?? painted[name]; },
    set value(value) { typed[name] = value; },
  });
  const fields = { sliceOwner: field("sliceOwner", "owner"), sliceOutcome: field("sliceOutcome", "outcome") };
  const container = {
    nrcMarkup: undefined, contains: () => false, querySelector: () => null,
    setAttribute() {},
  };
  Object.defineProperty(container, "innerHTML", {
    set(markup) {
      painted = {
        owner: /id="sliceOwner"[^>]*value="([^"]*)"/.exec(markup)?.[1] ?? "",
        outcome: />([^<]*)<\/textarea>/.exec(markup)?.[1] ?? "",
      };
      typed.owner = null;
      typed.outcome = null;
    },
    get: () => "",
  });
  const view = { style: {}, dataset: {}, addEventListener() {}, querySelector: () => null };
  const slices = loadSlices({
    document: {
      activeElement: null,
      getElementById: (id) => (id === "sliceView" ? view : id === "sliceRecord" ? container : fields[id] ?? null),
      addEventListener() {},
      querySelectorAll: () => [],
    },
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets,
        requestAsset: (convId, assetId, { onSuccess } = {}) => {
          onSuccess?.({ asset: roomAssets.get(0n).get(assetId) });
          return 1;
        },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, todo: 1 }] }));
  await settleMicrotasks();
  assert.deepEqual(
    { owner: fields.sliceOwner.value, outcome: fields.sliceOutcome.value },
    { owner: "rene", outcome: "Ship the register." },
    "the fields are painted from the record",
  );

  fields.sliceOutcome.value = "Typed but unsaved.";
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, todo: 2 }] }));
  assert.deepEqual(
    { owner: fields.sliceOwner.value, outcome: fields.sliceOutcome.value },
    { owner: "rene", outcome: "Typed but unsaved." },
    "the refresh keeps the reader's text and the untouched field follows the record",
  );

  // The record moves on elsewhere: the untouched owner shows it, the outcome the
  // reader is still typing in does not lose its text.
  roomAssets.get(0n).get(5n).preview = JSON.stringify({ version: 1, name: "Alpha", owner: "anke", outcome: "Remote." });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, todo: 2 }] }));
  await settleMicrotasks();
  assert.deepEqual(
    { owner: fields.sliceOwner.value, outcome: fields.sliceOutcome.value },
    { owner: "anke", outcome: "Typed but unsaved." },
    "a remote change shows where the reader has not typed",
  );
});

test("closing a bound slice updates the asset with an owner-acted closure", () => {
  const updates = [];
  const slices = loadSlices({
    myNickname: "rene",
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map([[5n, { assetId: 5n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Alpha", owner: "rene", outcome: "Ship it." }) }]])]]),
        sendUpdateAsset: (convId, assetId, preview, payload, type, correlationId, options) => {
          updates.push({ convId, assetId, preview: JSON.parse(preview), payload, type });
          options.onSuccess({});
          return 1;
        },
        sendCreateAsset: () => { throw new Error("close must update, not create"); },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n, owner: "rene", flags: 1 }] }));
  slices.closeSlice(slices.selectedSlice());

  assert.equal(updates.length, 1);
  assert.equal(updates[0].assetId, 5n);
  assert.equal(updates[0].type, 11);
  assert.equal(updates[0].preview.closed, true);
  assert.equal(updates[0].preview.closed_by, "rene");
  assert.ok(updates[0].preview.closed_at > 0, "closure records when it happened");
  assert.equal(updates[0].preview.outcome, "Ship it.", "closure preserves the recorded outcome");
  assert.equal(updates[0].preview.owner, "rene");
});

test("creating a slice writes a record with the name it was given", () => {
  const creates = [];
  const slices = loadSlices({
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map()]]),
        sendCreateAsset: (convId, type, parentType, parentId, preview, payload, correlationId, options) => {
          creates.push({ type, parentType, parentId, preview: JSON.parse(preview), payload });
          options.onSuccess({});
          return 1;
        },
        sendUpdateAsset: () => { throw new Error("a new slice must be created, not updated"); },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [] }));
  slices.createSlice("  Shard hardening  ", { owner: "rene", outcome: "Restart-safe." });

  assert.equal(creates.length, 1);
  assert.equal(creates[0].type, 11, "a slice is an asset of type Slice");
  assert.equal(creates[0].preview.version, 1);
  assert.equal(creates[0].preview.name, "Shard hardening", "the name is trimmed");
  assert.equal(creates[0].preview.owner, "rene");
  assert.equal(creates[0].preview.outcome, "Restart-safe.");
  assert.equal(creates[0].preview.closed, false);
  assert.equal(slices.getState().selected, "Shard hardening", "the new slice is selected");
});

test("a name that is already taken is refused before anything is sent", () => {
  const slices = loadSlices({
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map()]]),
        sendCreateAsset: () => { throw new Error("a duplicate name must not reach the wire"); },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n }] }));
  slices.createSlice("Alpha");
  assert.match(slices.getState().writeError, /already exists/);
});

test("saving a bound slice updates the record instead of creating a second one", () => {
  const updates = [];
  const slices = loadSlices({
    ...sliceFields({ outcome: "Sharpened outcome.", owner: "anke" }),
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map([[5n, { assetId: 5n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Alpha", owner: "rene", outcome: "First." }) }]])]]),
        sendUpdateAsset: (convId, assetId, preview, payload, type, correlationId, options) => {
          updates.push({ assetId, preview: JSON.parse(preview), type });
          options.onSuccess({});
          return 1;
        },
        sendCreateAsset: () => { throw new Error("a bound slice must be updated, not created"); },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n, flags: 1 }] }));
  slices.saveRecord();

  assert.equal(updates.length, 1);
  assert.equal(updates[0].assetId, 5n);
  assert.equal(updates[0].preview.outcome, "Sharpened outcome.");
  assert.equal(updates[0].preview.owner, "anke");
});

test("an over-long outcome is rejected before anything is sent", () => {
  const slices = loadSlices({
    ...sliceFields({ outcome: "x".repeat(2049) }),
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map([[5n, { assetId: 5n, assetType: 11, preview: JSON.stringify({ version: 1, name: "Alpha" }) }]])]]),
        sendUpdateAsset: () => { throw new Error("an oversized preview must not reach the wire"); },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n, flags: 1 }] }));
  slices.saveRecord();
  assert.match(slices.getState().writeError, /limit/);
});

test("assigning a member writes one member-of edge to the slice", () => {
  const created = [];
  const slices = loadSlices({
    window: {
      NRCAssets: { generateCorrelationId: () => 7, roomAssets: new Map([[0n, new Map()]]) },
      NRCEdges: {
        requestEdgePage: () => Promise.resolve({}),
        getEdgesForEntity: () => [],
        sendCreateEdge: (convId, sourceType, sourceId, targetType, targetId, relation, options) => {
          created.push({ convId, sourceType, sourceId, targetType, targetId, relation });
          options?.onSuccess?.({});
          return 1;
        },
        sendDeleteEdge: () => 1,
        TargetType: { Asset: 1, Task: 2 },
        RelationType: { RelatedTo: 2, MemberOf: 7 },
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n }] }));
  slices.assignMembers("task", [42n]);
  slices.assignMembers("note", [204n]);

  assert.equal(created.length, 2);
  assert.equal(created[0].sourceType, 2, "a task member is a task");
  assert.equal(created[0].sourceId, 42n);
  assert.equal(created[0].targetType, 1, "the slice is an asset, not a task");
  assert.equal(created[0].targetId, 5n);
  assert.equal(created[0].relation, 7, "membership is member-of");
  assert.equal(created[1].sourceType, 1, "a note member is an asset");
  assert.equal(created[1].sourceId, 204n);
});

test("a disposed picker acknowledgement does not refresh the newly selected slice", async () => {
  let picker, acknowledgement;
  const reads = [];
  const slices = loadSlices({ window: {
    NRCLinksUI: { openEntityPicker: options => { picker = options; } },
    NRCAssets: { requestAsset: (room, id, { onSuccess } = {}) => { reads.push(id); onSuccess?.({ asset: null }); return 1; } },
    NRCEdges: { sendCreateEdge: (...args) => { acknowledgement = args.at(-1); return 1; } },
  } });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n }, { name: "Beta", sliceId: 9n }] }));
  slices.openMemberPicker({}, "task");
  let cancelled = false;
  const pending = picker.onSelect({ id: 42n }, 7, () => cancelled);
  cancelled = true;
  slices.select("Beta");
  const before = { reads: reads.length, packets: slices.__sent.length };
  acknowledgement.onSuccess();
  await pending;
  assert.equal(reads.length, before.reads, "late ACK must not re-read Beta");
  assert.equal(slices.__sent.length, before.packets, "late ACK must not invalidate the register");

  slices.openMemberPicker({}, "task");
  const current = picker.onSelect({ id: 43n }, 7, () => false);
  acknowledgement.onSuccess();
  await current;
  assert.equal(reads.length, before.reads + 1, "current session still refreshes its detail");
  assert.equal(reads.at(-1), 9n);
});

test("assigning without a picker reports it instead of failing silently", () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n }] }));
  slices.openMemberPicker({ id: "anchor" }, "file");
  assert.match(slices.getState().writeError, /unavailable/);
});

test("unassigning removes the member-of edge that joins the member to this slice", () => {
  const deleted = [];
  const slices = loadSlices({
    window: {
      NRCAssets: { generateCorrelationId: () => 7, roomAssets: new Map([[0n, new Map()]]) },
      NRCEdges: {
        requestEdgePage: () => Promise.resolve({}),
        getEdgesForEntity: () => [
          { edgeId: 1n, relation: 7, sourceType: 2, sourceId: 42n, targetType: 1, targetId: 5n },
          { edgeId: 2n, relation: 2, sourceType: 1, sourceId: 204n, targetType: 1, targetId: 5n },
          { edgeId: 3n, relation: 7, sourceType: 1, sourceId: 204n, targetType: 1, targetId: 5n },
        ],
        sendCreateEdge: () => 1,
        sendDeleteEdge: (convId, edgeId, options) => { deleted.push(edgeId); options?.onSuccess?.({}); return 1; },
        TargetType: { Asset: 1, Task: 2 },
        RelationType: { RelatedTo: 2, MemberOf: 7 },
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n }] }));
  slices.unassignMember("note", 204n);

  assert.equal(deleted.length, 1, "only the member-of edge for this member is removed");
  assert.equal(deleted[0], 3n, "the related-to edge is left alone");
});

test("a member that is not assigned has nothing to remove", () => {
  const slices = loadSlices({
    window: {
      NRCAssets: { generateCorrelationId: () => 7, roomAssets: new Map([[0n, new Map()]]) },
      NRCEdges: {
        requestEdgePage: () => Promise.resolve({}),
        getEdgesForEntity: () => [],
        sendCreateEdge: () => 1,
        sendDeleteEdge: () => { throw new Error("nothing to remove"); },
        TargetType: { Asset: 1, Task: 2 },
        RelationType: { RelatedTo: 2, MemberOf: 7 },
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ correlationId: 7, slices: [{ name: "Alpha", sliceId: 5n }] }));
  slices.unassignMember("task", 42n);
  assert.match(slices.getState().writeError, /No membership/);
});

// The register's controls and readouts are looked up by id, so a filter test
// supplies the elements it asserts on and lets every other lookup miss.
function registerElements() {
  const elements = new Map();
  return (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        id, innerHTML: "", textContent: "", value: "", hidden: false, dataset: {},
        setAttribute() {}, getAttribute: () => null, hasAttribute: () => false,
        querySelector: () => null, querySelectorAll: () => [], contains: () => false, focus() {},
        addEventListener() {},
      });
    }
    return elements.get(id);
  };
}

// sliceRequest reads a C_ListTaskSlices body back, so a test can assert what the
// register asked the server for rather than how it asked.
function sliceRequest(view) {
  const ownerLength = view.getUint16(12, false);
  const owner = new TextDecoder().decode(new Uint8Array(view.buffer, view.byteOffset + 14, ownerLength));
  let offset = 14 + ownerLength;
  const hasName = view.getUint8(offset) === 1;
  offset += 1;
  const nameLength = view.getUint16(offset, false);
  offset += 2;
  const name = new TextDecoder().decode(new Uint8Array(view.buffer, view.byteOffset + offset, nameLength));
  offset += nameLength;
  const limit = view.getUint16(offset, false);
  offset += 2;
  const hasCursor = view.getUint8(offset) === 1;
  offset += 1;
  let cursor = null;
  if (hasCursor) {
    cursor = {
      closed: view.getUint8(offset) === 1,
      sortAt: view.getBigInt64(offset + 1, false),
      sliceId: view.getBigUint64(offset + 9, false),
    };
    offset += 17;
  }
  return {
    opcode: view.getUint16(0, false),
    convId: view.getBigUint64(2, false),
    includeClosed: view.getUint8(10) === 1,
    hasOwner: view.getUint8(11) === 1,
    owner,
    hasName,
    name,
    limit,
    hasCursor,
    cursor,
    correlationId: view.getUint32(offset, false),
    length: view.byteLength,
  };
}

// A filter is the server's: a change asks for the listing again with the filter in
// the request, and the page that arrives is already the filtered one.
test("a filter change asks the server with the filter in the request", async () => {
  const slices = loadSlices({ myNickname: "rene" });
  slices.requestList({ force: true });

  slices.setOwnerFilter("me");
  const mine = sliceRequest(new DataView(slices.__sent[1]));
  assert.equal(mine.hasOwner, true);
  assert.equal(mine.owner, "rene", "MY SLICES resolves to the reader's own name");

  slices.setOwnerFilter("unassigned");
  const unowned = sliceRequest(new DataView(slices.__sent[2]));
  assert.equal(unowned.hasOwner, true, "UNASSIGNED is an owner filter too");
  assert.equal(unowned.owner, "", "and it names nobody");

  slices.setQuery("shard");
  const queried = sliceRequest(new DataView(slices.__sent[3]));
  assert.equal(queried.hasName, true);
  assert.equal(queried.name, "shard");
  assert.equal(queried.hasOwner, true, "the owner filter stays beside the query");

  slices.resetFilters();
  const reset = sliceRequest(new DataView(slices.__sent[4]));
  assert.equal(reset.hasOwner, false, "RESET asks for every owner again");
  assert.equal(reset.hasName, false);
  assert.equal(slices.filterActive(), false);
});

// The register is paged: the head says how much of the listing is drawn, and the
// cursor a page ends on asks for the next one.
test("a page that says there is more carries the cursor the next page asks for", async () => {
  const element = registerElements();
  const slices = loadSlices({
    document: { activeElement: null, getElementById: element, addEventListener() {}, querySelectorAll: () => [] },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({
    hasMore: true,
    nextCursor: { closed: false, sortAt: 9000n, sliceId: 77n },
    total: 3,
    slices: [{ name: "Alpha", sliceId: 77n, todo: 2, lastMovedAt: 9000n }],
  }));

  const state = slices.getState();
  assert.equal(state.mode, "ready");
  assert.equal(state.total, 3);
  assert.equal(state.hasMore, true);
  assert.deepEqual({ ...state.cursor }, { closed: false, sortAt: 9000n, sliceId: 77n });
  assert.equal(element("sliceResultsCount").textContent, "1 / 3 SLICES / 2 OPEN",
    "the head says how many of the listing's slices the register has drawn");

  slices.loadMore();
  const request = sliceRequest(new DataView(slices.__sent[1]));
  assert.equal(request.hasCursor, true);
  assert.deepEqual({ ...request.cursor }, { closed: false, sortAt: 9000n, sliceId: 77n },
    "the next page asks where the previous one stopped");

  // The page continues the listing instead of replacing it.
  slices.handleSliceList(encodeSliceList({
    total: 3,
    slices: [{ name: "Beta", sliceId: 78n }],
  }));
  assert.deepEqual(Array.from(state.slices, (slice) => slice.name), ["Alpha", "Beta"]);
  assert.equal(state.hasMore, false);
  assert.equal(state.cursor, null, "the end of the listing has no next page");
  assert.equal(element("sliceResultsCount").textContent, "3 SLICES / 2 OPEN");
});

// A filter that matches nothing is an empty page, and the register says so instead
// of reading as an empty workspace.
test("a filter that matches nothing says so", async () => {
  const element = registerElements();
  // The record's fields hold what the record holds, so nothing is unsaved.
  const fields = { sliceOwner: { value: "rene" }, sliceOutcome: { value: "" } };
  const slices = loadSlices({
    myNickname: "rene",
    document: {
      activeElement: null,
      getElementById: (id) => fields[id] ?? element(id),
      addEventListener() {},
      querySelectorAll: () => [],
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ total: 2, slices: [
    { name: "Alpha", sliceId: 5n, owner: "rene", todo: 2 },
    { name: "Beta", sliceId: 6n, owner: "anke" },
  ] }));
  await settleMicrotasks();
  assert.equal(element("sliceResultsCount").textContent, "2 SLICES / 2 OPEN");
  assert.equal(element("sliceStatus").hidden, true, "a register with rows carries no status line");

  const filtered = slices.setOwnerFilter("unassigned");
  slices.handleSliceList(encodeSliceList({ total: 0, slices: [] }));
  await filtered;
  assert.equal(element("sliceResultsCount").textContent, "0 SLICES / 0 OPEN");
  assert.equal(element("sliceStatus").textContent, "NO SLICES MATCH THE FILTER");
  assert.equal(element("sliceStatus").hidden, false);
  assert.equal(element("sliceRegisterList").innerHTML, "", "a filter that matches nothing draws no row");
  assert.equal(slices.getState().selected, null, "there is no row to open");
});

// The record follows the register, unless the reader has unsaved work in it.
test("a listing replaces the record unless the reader has unsaved work in it", async () => {
  const fields = { sliceOwner: { value: "typed but unsaved" }, sliceOutcome: { value: "" } };
  const slices = loadSlices({
    myNickname: "rene",
    document: {
      activeElement: null,
      getElementById: (id) => fields[id] ?? null,
      addEventListener() {},
      querySelectorAll: () => [],
    },
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map([[5n, {
          assetId: 5n,
          assetType: 11,
          preview: JSON.stringify({ version: 1, name: "Alpha", owner: "rene", outcome: "" }),
        }]])]]),
        requestAsset: (convId, assetId, { onSuccess } = {}) => {
          onSuccess?.({ asset: null });
          return 1;
        },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ total: 2, slices: [
    { name: "Alpha", sliceId: 5n, owner: "rene" },
    { name: "Beta", sliceId: 6n, owner: "anke" },
  ] }));
  await settleMicrotasks();
  assert.equal(slices.getState().selected, "Alpha");
  assert.equal(slices.recordDirty(), true, "the typed owner is unsaved");

  // A filtered listing that does not carry the open slice leaves the record alone.
  slices.setOwnerFilter("anke");
  slices.handleSliceList(encodeSliceList({ total: 1, slices: [{ name: "Beta", sliceId: 6n, owner: "anke" }] }));
  assert.equal(slices.getState().selected, "Alpha", "the reader keeps the record they were working in");
  assert.deepEqual(Array.from(slices.getState().slices, (slice) => slice.name), ["Beta"]);

  // A record that holds what its fields hold follows the listing.
  fields.sliceOwner.value = "anke";
  slices.setOwnerFilter("unassigned");
  slices.handleSliceList(encodeSliceList({ total: 1, slices: [{ name: "Beta", sliceId: 6n, owner: "anke" }] }));
  assert.equal(slices.getState().selected, "Beta", "a clean record opens the row the listing draws");
});

// MY SLICES resolves to the reader's own name, the way MY TASKS resolves the
// assignee; without an identity the request names nobody. The register is only
// reachable with a session, so this is the request's shape and not a filter the
// reader can choose.
test("MY SLICES without an identity names nobody", async () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  slices.setOwnerFilter("me");
  assert.equal(sliceRequest(new DataView(slices.__sent[1])).owner, "");
});

// A derived view (the attention register) folds a whole listing through its own
// read: every page is walked, and the register's window, filter and selection are
// left where the reader put them.
test("a headless read walks every page without touching the register", async () => {
  const slices = loadSlices({ myNickname: "rene" });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ total: 1, slices: [{ name: "Register row", sliceId: 5n, owner: "anke" }] }));
  const sentBefore = slices.__sent.length;

  const read = slices.readAll({ owner: "me" });
  const first = sliceRequest(new DataView(slices.__sent[sentBefore]));
  assert.equal(first.hasOwner, true, "the read carries its own filter");
  assert.equal(first.owner, "rene", "MY SLICES resolves to the reader's own name");
  assert.equal(first.hasCursor, false, "the walk starts at the first page");

  slices.handleSliceList(encodeSliceList({
    hasMore: true,
    nextCursor: { closed: false, sortAt: 9000n, sliceId: 77n },
    total: 2,
    slices: [{ name: "Mine 1", sliceId: 77n, owner: "rene", todo: 2 }],
  }));
  // The walk asks for the next page on its own.
  await settleMicrotasks();
  const second = sliceRequest(new DataView(slices.__sent[sentBefore + 1]));
  assert.deepEqual({ ...second.cursor }, { closed: false, sortAt: 9000n, sliceId: 77n },
    "the next page asks where the previous one stopped");

  slices.handleSliceList(encodeSliceList({ total: 2, slices: [{ name: "Mine 2", sliceId: 78n, owner: "rene" }] }));
  const listing = await read;
  assert.deepEqual(Array.from(listing.slices, (slice) => slice.name), ["Mine 1", "Mine 2"]);
  assert.equal(listing.total, 2, "the listing says how many work streams it matched");

  assert.deepEqual(Array.from(slices.getState().slices, (slice) => slice.name), ["Register row"],
    "the register's window is untouched");
  assert.equal(slices.getState().selected, "Register row", "so is its selection");
  assert.deepEqual({ ...slices.getFilters() }, { owner: null, query: "" }, "and its filter");
});

test("a headless read ends when a page cannot advance the cursor", async () => {
  const slices = loadSlices();
  const read = slices.readAll({ owner: "me" });
  slices.handleSliceList(encodeSliceList({
    hasMore: true,
    nextCursor: { closed: false, sortAt: 9000n, sliceId: 77n },
    total: 5,
    slices: [],
  }));
  const listing = await read;
  assert.deepEqual(Array.from(listing.slices), []);
  assert.equal(listing.total, 5);
  assert.equal(slices.__sent.length, 1, "a page that cannot advance the cursor ends the walk");
});

test("a headless read that fails answers nothing rather than an empty listing", async () => {
  const slices = loadSlices();
  const read = slices.readAll({ owner: "me" });
  slices.handleSliceList(encodeSliceList({ success: false, error: "Slice listing allocation failed" }));
  assert.equal(await read, null, "a failed read is not an empty listing");
});

// A slice is created without an owner, so a filter that would hide it is dropped:
// the register asks for the listing again without one.
test("creating a slice drops the filter that would hide it", async () => {
  const slices = loadSlices({
    myNickname: "rene",
    window: {
      NRCAssets: {
        generateCorrelationId: () => 7,
        roomAssets: new Map([[0n, new Map()]]),
        sendCreateAsset: (convId, type, parentType, parentId, preview, payload, correlationId, options) => {
          options.onSuccess({});
          return 1;
        },
        MAX_PREVIEW_LENGTH: 4096,
      },
    },
  });
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ total: 1, slices: [{ name: "Alpha", sliceId: 5n, owner: "anke" }] }));
  slices.setQuery("Alpha");
  assert.equal(slices.filterActive(), true);

  slices.createSlice("Shard hardening");
  assert.equal(slices.filterActive(), false, "the filter goes so the new slice is visible");
  assert.deepEqual({ ...slices.getFilters() }, { owner: null, query: "" });
  assert.equal(slices.getState().selected, "Shard hardening");
});

test("a listing is announced only when it differs from the one before", () => {
  const slices = loadSlices();
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, blocked: 2 }] }));
  assert.equal(slices.__dispatched.length, 1, "a new listing is announced");

  // The register asks for the list itself and is answered with the same list, so
  // a second announcement would have it ask again, forever.
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, blocked: 2 }] }));
  assert.equal(slices.__dispatched.length, 1, "the same listing is not announced again");

  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, blocked: 5 }] }));
  assert.equal(slices.__dispatched.length, 2, "a changed listing is announced");

  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({ slices: [{ name: "Alpha", sliceId: 5n, blocked: 5, owner: "mara" }] }));
  assert.equal(slices.__dispatched.length, 3, "so is a changed owner");

  // A continuation page carries more of the same work streams rather than new ones,
  // so a derived view is not asked to walk again for every page the reader scrolls.
  slices.requestList({ force: true });
  slices.handleSliceList(encodeSliceList({
    hasMore: true,
    nextCursor: { closed: false, sortAt: 9000n, sliceId: 5n },
    total: 2,
    slices: [{ name: "Alpha", sliceId: 5n, blocked: 5, owner: "mara" }],
  }));
  assert.equal(slices.__dispatched.length, 3, "the same first page is not announced again");
  slices.loadMore();
  slices.handleSliceList(encodeSliceList({ total: 2, slices: [{ name: "Beta", sliceId: 6n, blocked: 1 }] }));
  assert.equal(slices.__dispatched.length, 3, "a continuation page is not announced");
});
