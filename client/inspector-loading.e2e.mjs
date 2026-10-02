// Run against the disposable test/customer-workspace-dev.mjs fixture.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { chromium } from "playwright";

const url = process.env.NRC_CUSTOMERS_TEST_URL;
if (!url) throw new Error("Set NRC_CUSTOMERS_TEST_URL to the disposable fixture");
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, serviceWorkers: "block" });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto(`${url}/#workspace=inspector-loading-${Date.now()}`);
  await page.waitForFunction(() => serverReady && NRCCustomers.isEnabled());
  const ids = await page.evaluate(async () => {
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    const ids = { task: [], note: [], contact: [], company: [] };
    for (let i = 0; i < 2; i++) {
      const task = await rpc(o => NRCTasks.sendCreateTask(0n, `Task ${i}`, `Task body ${i}`, 128, 0, "", 0n, [], 0, 0, "", o));
      ids.task.push(String(task.task.id));
      for (const [type, kind] of [[5, "note"], [8, "company"], [9, "contact"]]) {
        const result = await rpc(o => NRCAssets.sendCreateAsset(0n, type, 0, 0n,
          JSON.stringify({ version: 1, title: `${kind} ${i}`, email: `person${i}@example.test` }), `${kind} body ${i}`, 0, o));
        ids[kind].push(String(result.asset.assetId));
      }
      await rpc(o => NRCEdges.sendCreateEdge(0n, 2, task.task.id, 1, BigInt(ids.note[i]), 1, o));
      await rpc(o => NRCEdges.sendCreateEdge(0n, 1, BigInt(ids.contact[i]), 1, BigInt(ids.company[i]), NRCEdges.RelationType.MemberOf, o));
    }
    return ids;
  });
  const open = (type, index, extra = {}) => page.evaluate(({ type, id, extra }) =>
    NRCInspector.openEntity({ roomId: 0n, type, id: BigInt(id) }, { replaceCurrent: true, ...extra }),
  { type, id: ids[type][index], extra });
  const ready = () => page.waitForFunction(() => !NRCInspector.isLoading());
  const host = page.locator("#inspectorEntityHost");

  for (const theme of ["light", "dark"]) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
      for (const type of ["task", "note", "contact"]) {
        await open(type, 0); await ready();
        const before = await host.innerHTML();
        // Keep the primary note cold as well: its exact-read broadcast must not
        // publish a new body before the relationships have arrived.
        await page.evaluate(({ type, id }) => {
          if (type === "note") NRCAssets.roomAssets.get(0n).get(BigInt(id)).payload = null;
          const request = NRCEdges.requestEdgePage;
          window.releaseInspectorEdges = null;
          NRCEdges.requestEdgePage = async (...args) => {
            const result = await request(...args);
            await new Promise(resolve => { window.releaseInspectorEdges = resolve; });
            return result;
          };
          window.restoreInspectorEdges = () => { NRCEdges.requestEdgePage = request; };
        }, { type, id: ids[type][1] });
        await open(type, 1, type === "note" ? { deferDetail: true } : {});
        await page.waitForFunction(() => !!window.releaseInspectorEdges);
        assert.equal(await host.innerHTML(), before, `${type}: old detail stays intact at ${width}/${theme}`);
        assert.equal(await host.evaluate(el => el.inert), true);
        await page.keyboard.press("e");
        assert.equal(await host.innerHTML(), before, "old edit shortcut is blocked");
        await page.evaluate(() => { window.restoreInspectorEdges(); window.releaseInspectorEdges(); });
        await ready();
        assert.match(await host.textContent(), new RegExp(`${type === "task" ? "Task" : type} ${1}`));
        const links = type === "contact" ? page.locator("#contactCompanies") : page.locator(type === "task" ? "#taskDetailLinksList" : "#noteLinksList");
        assert.match(await links.textContent(), new RegExp(type === "contact" ? "company 1" : type === "task" ? "note 1" : "Task 1"));
        if (process.env.NRC_INSPECTOR_SCREENSHOTS) {
          await fs.mkdir(process.env.NRC_INSPECTOR_SCREENSHOTS, { recursive: true });
          await page.locator("#inspector").screenshot({ path: `${process.env.NRC_INSPECTOR_SCREENSHOTS}/${type}-${theme}-${width}.png` });
        }
      }
    }
  }

  // A missing linked target delays publication even after all edge pages arrive.
  await open("task", 0); await ready();
  const beforeTarget = await host.innerHTML();
  await page.evaluate(id => {
    const request = NRCAssets.requestAsset;
    window.releaseInspectorTarget = null;
    NRCAssets.roomAssets.get(0n).delete(BigInt(id));
    NRCAssets.requestAsset = (room, assetId, options) => request(room, assetId, {
      ...options, onSuccess: result => { window.releaseInspectorTarget = () => options.onSuccess(result); },
    });
    window.restoreInspectorTarget = () => { NRCAssets.requestAsset = request; };
  }, ids.note[1]);
  await open("task", 1);
  await page.waitForFunction(() => !!window.releaseInspectorTarget);
  assert.equal(await host.innerHTML(), beforeTarget);
  await page.evaluate(() => window.restoreInspectorTarget());
  await open("contact", 0); await ready();
  const newest = await host.innerHTML();
  await page.evaluate(() => window.releaseInspectorTarget());
  assert.equal(await host.innerHTML(), newest, "stale target completion cannot replace a newer entity");

  // A live company-link refresh preserves the complete previous table.
  const companyList = page.locator("#contactCompanies");
  const beforeCompanies = await companyList.innerHTML();
  await page.evaluate(async ({ company, contact }) => {
    const request = NRCEdges.requestEdgePage;
    window.releaseInspectorEdges = null;
    NRCEdges.requestEdgePage = async (...args) => {
      const result = await request(...args);
      await new Promise(resolve => { window.releaseInspectorEdges = resolve; });
      return result;
    };
    window.restoreInspectorEdges = () => { NRCEdges.requestEdgePage = request; };
    await new Promise((resolve, reject) => NRCEdges.sendCreateEdge(0n, 1, BigInt(contact), 1, BigInt(company), NRCEdges.RelationType.MemberOf,
      { onSuccess: resolve, onError: reject }));
  }, { company: ids.company[1], contact: ids.contact[0] });
  await page.waitForFunction(() => !!window.releaseInspectorEdges);
  assert.equal(await companyList.innerHTML(), beforeCompanies);
  assert.equal(await companyList.evaluate(el => el.inert), true);
  await page.evaluate(() => { window.restoreInspectorEdges(); window.releaseInspectorEdges(); });
  await page.waitForFunction(() => document.getElementById("contactCompanies").textContent.includes("LINKED COMPANIES / 2"));
  assert.match(await companyList.textContent(), /company 1/);

  // Error/retry and closing during a pending request must release inertness.
  await page.evaluate(() => {
    const request = NRCEdges.requestEdgePage;
    NRCEdges.requestEdgePage = async () => { throw new Error("Relationship read failed"); };
    window.restoreInspectorEdges = () => { NRCEdges.requestEdgePage = request; };
  });
  await open("note", 1); await ready();
  assert.match(await host.textContent(), /Relationship read failed/);
  await page.evaluate(() => window.restoreInspectorEdges());
  await host.getByRole("button", { name: "RETRY", exact: true }).click(); await ready();
  assert.match(await host.textContent(), /note 1/);
  await page.evaluate(() => {
    const request = NRCEdges.requestEdgePage;
    window.releaseInspectorEdges = null;
    NRCEdges.requestEdgePage = async (...args) => {
      await new Promise(resolve => { window.releaseInspectorEdges = resolve; });
      return request(...args);
    };
    window.restoreInspectorEdges = () => { NRCEdges.requestEdgePage = request; };
  });
  await open("task", 0);
  await page.waitForFunction(() => !!window.releaseInspectorEdges);
  await page.locator("#inspectorHeader .task-detail-close").click();
  await page.evaluate(() => { window.restoreInspectorEdges(); window.releaseInspectorEdges(); });
  await page.waitForFunction(() => !NRCInspector.hasEntity() && !NRCInspector.isLoading());
  assert.equal(await host.evaluate(el => el.inert), false);
  await page.evaluate(() => { serverReady = false; });
  await open("task", 0); await ready();
  assert.match(await host.textContent(), /Task 0/, "cached details remain readable offline");
  await page.evaluate(() => { serverReady = true; });

  // Exercise the real row handlers with 897 server-backed notes. Add 120 ms
  // to each exact/edge request: a prefetched click must not pay that latency.
  await page.setViewportSize({ width: 1440, height: 1000 });
  const target = await page.evaluate(async () => {
    await NRCInspector.close();
    const rpc = send => new Promise((resolve, reject) => send({ onSuccess: resolve, onError: reject }));
    for (let start = 2; start < 897; start += 25) {
      await Promise.all(Array.from({ length: Math.min(25, 897 - start) }, (_, j) => {
        const i = start + j;
        return rpc(o => NRCAssets.sendCreateAsset(0n, 5, 0, 0n,
          JSON.stringify({ title: `Prefetch ${i}`, format: "markdown" }), `Body for prefetch ${i}`, 0, o));
      }));
    }
    NRCNotes.showNotesView();
    const state = getNotesPaginationState(0n);
    while (state.loading) await new Promise(resolve => setTimeout(resolve, 10));
    for (let page = 0; page < 40 && state.hasMore; page++) {
      fetchNotesPage(0n);
      while (state.loading) await new Promise(resolve => setTimeout(resolve, 10));
    }
    const virtual = document.getElementById("notesList").virtualList;
    if (virtual.items.length !== 897) throw new Error(`Expected 897 notes, got ${virtual.items.length}`);
    for (const note of virtual.items) note.payload = null;
    const note = virtual.items[10];
    virtual.ensure(10);
    window.prefetchProbe = { requests: [], completedLinks: new Set() };
    const send = sendPacket;
    sendPacket = data => {
      const opcode = new DataView(data).getUint16(0);
      if (opcode === Opcode.C_GetAsset || opcode === Opcode.C_ListEdgesPaged) {
        prefetchProbe.requests.push(opcode);
        setTimeout(() => send(data), 120);
      } else send(data);
    };
    const loadLinks = NRCLinksUI.loadLinks;
    NRCLinksUI.loadLinks = async (...args) => {
      await loadLinks(...args);
      prefetchProbe.completedLinks.add(String(args[2]));
    };
    return { id: String(note.assetId), title: JSON.parse(note.preview).title };
  });
  const row = page.locator(`.note-card[data-note-id="${target.id}"]`);
  await row.evaluate(async el => {
    el.dispatchEvent(new PointerEvent("pointerenter", { pointerType: "mouse" }));
    el.dispatchEvent(new PointerEvent("pointerleave", { pointerType: "mouse" }));
    await new Promise(resolve => setTimeout(resolve, 80));
  });
  assert.equal(await page.evaluate(() => prefetchProbe.requests.length), 0, "passing across a row must cancel hover speculation");
  await row.hover();
  await page.waitForFunction(id => NRCAssets.roomAssets.get(0n).get(BigInt(id)).payload != null &&
    prefetchProbe.completedLinks.has(id), target.id);
  const latency = await page.evaluate(async ({ id, title }) => {
    const requests = prefetchProbe.requests.length;
    const start = performance.now();
    document.querySelector(`.note-card[data-note-id="${id}"] .task-row-open`).click();
    for (let frame = 0; frame < 60; frame++) {
      await new Promise(requestAnimationFrame);
      if (NRCInspector.current()?.id === BigInt(id) && !NRCInspector.isLoading()) {
        return { ms: performance.now() - start, requests: prefetchProbe.requests.length - requests,
          rendered: document.getElementById("inspectorEntityHost").textContent.includes(title) };
      }
    }
    throw new Error("Prefetched note did not render");
  }, target);
  assert.equal(latency.requests, 0, "hover-prefetched click must make no further network reads");
  assert.equal(latency.rendered, true);
  console.log(`PASS 897 notes, 120 ms artificial request latency: warm click to DOM/frame ${latency.ms.toFixed(1)} ms, 0 additional reads`);
  assert.deepEqual(errors, []);
  console.log("PASS atomic task/note/contact details; cold body and targets; deferred navigation; stale completion; error/retry; close; both themes and widths");
} finally {
  await browser.close();
}
