import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const clientUrl = new URL("./", import.meta.url);

test("catalogue and offline shell use the production CSS versions, including imports", async () => {
  const [html, catalogue, worker, main] = await Promise.all(
    ["index.html", "design-system/index.html", "service-worker.js", "css/main.css"]
      .map(file => readFile(new URL(file, clientUrl), "utf8")),
  );
  const styles = source => [...source.matchAll(/<link rel="stylesheet" href="(?:\.\.\/)?(css\/[^\"]+)"/g)].map(match => match[1]);
  const production = styles(html);
  assert.ok(production.length > 0, "production styles are discoverable");
  assert.deepEqual(styles(catalogue), production, "catalogue must not retain stale CSS cache keys");
  const shell = vm.runInNewContext(`${worker}\nAPP_SHELL`, { self: { addEventListener() {} } });
  for (const file of [...production, ...[...main.matchAll(/@import url\("([^\"]+)"\)/g)].map(match => `css/${match[1]}`)]) {
    assert.ok(shell.includes(`./${file}`), `${file} must be available offline at the same version`);
  }
});

test("client declares an installable PWA", async () => {
  const [html, manifestText] = await Promise.all([
    readFile(new URL("index.html", clientUrl), "utf8"),
    readFile(new URL("manifest.webmanifest", clientUrl), "utf8"),
  ]);
  const manifest = JSON.parse(manifestText);

  assert.match(html, /<link rel="manifest" href="manifest\.webmanifest">/);
  assert.match(html, /navigator\.serviceWorker\.register\("service-worker\.js"\)/);
  assert.equal(manifest.display, "standalone");
  assert.equal(manifest.start_url, "./");
  assert.deepEqual(
    manifest.icons.map(({ sizes }) => sizes),
    ["192x192", "512x512"],
  );

  await Promise.all(
    manifest.icons.map(({ src }) => readFile(new URL(src, clientUrl))),
  );
});

test("installed desktop PWA provides an icon-free overlay titlebar", async () => {
  const [html, manifestText, css, app] = await Promise.all([
    readFile(new URL("index.html", clientUrl), "utf8"),
    readFile(new URL("manifest.webmanifest", clientUrl), "utf8"),
    readFile(new URL("css/workspace.css", clientUrl), "utf8"),
    readFile(new URL("app.js", clientUrl), "utf8"),
  ]);
  const manifest = JSON.parse(manifestText);

  assert.deepEqual(manifest.display_override, ["window-controls-overlay"]);
  assert.match(html, /id="pwaTitlebarTitle"/);
  assert.match(css, /@media \(display-mode: window-controls-overlay\)/);
  assert.match(css, /-webkit-app-region: drag/);
  assert.match(app, /pwaTitlebarTitle\.textContent/);
});

test("application shell assets avoid the search reverse-proxy namespace", async () => {
  const [html, serviceWorker] = await Promise.all([
    readFile(new URL("index.html", clientUrl), "utf8"),
    readFile(new URL("service-worker.js", clientUrl), "utf8"),
  ]);

  assert.doesNotMatch(html, /<script src="search[^/"]*/);
  assert.doesNotMatch(serviceWorker, /"\.\/search[^/"]*/);
  assert.match(html, /<script src="query-controller\.js\?v=20260914workspace1"><\/script>/);
  assert.match(serviceWorker, /"\.\/query-controller\.js\?v=20260914workspace1"/);
});

test("worker installation requires successful CORS caching of eager dependencies", async () => {
  const source = await readFile(new URL("service-worker.js", clientUrl), "utf8");
  for (const unavailable of [false, true]) {
    let install, completion;
    const requests = [];
    vm.runInNewContext(source, {
      Request,
      self: { addEventListener: (type, fn) => { if (type === "install") install = fn; }, skipWaiting() {} },
      caches: { open: async () => ({
        addAll: async () => {},
        add: async (request) => {
          requests.push(request);
          assert.equal(request.mode, "cors");
          if (unavailable && request.url.includes("marked@")) throw new Error("CDN unavailable");
        },
      }) },
    });
    install({ waitUntil: (promise) => { completion = promise; } });
    if (unavailable) await assert.rejects(completion, /CDN unavailable/);
    else await completion;
    assert.ok(requests.some((request) => request.url.includes("marked@")));
    assert.ok(!requests.some((request) => /graphology|cosmos/.test(request.url)));
  }
});

test("application shell and HTML contain no graph UI or renderer dependencies", async () => {
  const worker = await readFile(new URL("service-worker.js", clientUrl), "utf8");
  const html = await readFile(new URL("index.html", clientUrl), "utf8");
  const shell = vm.runInNewContext(`${worker}; [...APP_SHELL, ...EXTERNAL_SHELL]`, {
    self: { addEventListener() {} },
  });
  assert.doesNotMatch(html, /(?:id="graph(?:Btn|Panel|Container)"|graph\.js|graphology|@cosmos\.gl)/i);
  assert.ok(!shell.some(url => /graph\.js|graphology|@cosmos\.gl/i.test(url)));
});

test("an in-flight worker fetch does not recreate its cache after activation deletes it", async () => {
  const source = await readFile(new URL("service-worker.js", clientUrl), "utf8");
  const listeners = new Map(), stores = new Map(), opens = [], writes = [], waits = [];
  let finishFetch, fetchStarted;
  const started = new Promise((resolve) => { fetchStarted = resolve; });
  const network = new Promise((resolve) => { finishFetch = resolve; });
  const cache = {
    match: async () => undefined,
    put: async (_request, response) => { writes.push(await response.text()); },
  };
  const context = vm.createContext({
    URL,
    self: {
      location: { origin: "https://nrc.test" },
      registration: { scope: "https://nrc.test/" },
      addEventListener: (type, listener) => listeners.set(type, listener),
    },
    caches: {
      open: async (name) => { opens.push(name); stores.set(name, cache); return cache; },
      match: () => { throw new Error("Must not search other versions' caches"); },
    },
    fetch: () => { fetchStarted(); return network; },
  });
  vm.runInContext(source, context);
  let response;
  listeners.get("fetch")({
    request: { method: "GET", url: "https://nrc.test/latency-worker.js", mode: "cors" },
    respondWith: (promise) => { response = promise; },
    waitUntil: (promise) => waits.push(promise),
  });
  await started;
  assert.equal(opens.length, 1);
  stores.delete(opens[0]); // A new worker activates while this fetch is in flight.
  finishFetch(new Response("fresh response"));
  assert.equal(await (await response).text(), "fresh response");
  await Promise.all(waits);
  assert.deepEqual(writes, ["fresh response"]);
  assert.equal(opens.length, 1);
  assert.equal(stores.size, 0, "completion must not reopen the deleted cache name");
});
