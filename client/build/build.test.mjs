import assert from "node:assert/strict";
import { appendFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import { brotliDecompressSync, gunzipSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { buildClient, bundleScripts } from "../build.mjs";

const client = fileURLToPath(new URL("../", import.meta.url));

test("production CSS/fonts and worker form a deterministic, content-addressed shell", async (t) => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "nrc-build-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const sourceDir = path.join(dir, "source");
  const outDir = path.join(dir, "output");
  await cp(client, sourceDir, {
    recursive: true,
    filter: (file) => !path.relative(client, file).split(path.sep).some((part) => ["node_modules", "dist"].includes(part)),
  });
  const first = await buildClient({ sourceDir, outDir });
  const html = await readFile(path.join(outDir, "index.html"), "utf8");
  const css = await readFile(path.join(outDir, first.css), "utf8");
  const worker = await readFile(path.join(outDir, "service-worker.js"), "utf8");
  assert.doesNotMatch(css, /@import|fonts\.googleapis|fonts\.gstatic|Inter Variable/);
  assert.match(css, /font-family:Inter/);
  assert.match(css, /font-weight:100 900/);
  assert.match(css, /unicode-range:/);
  assert.match(css, /font-display:swap/);
  assert.equal([...html.matchAll(/rel="stylesheet" href="(?!https:)/g)].length, 1);
  const preloads = [...html.matchAll(/rel="preload" href="([^"]+)" as="font" type="font\/woff2" crossorigin/g)];
  assert.equal(preloads.length, 2);
  for (const [, file] of preloads) {
    assert.ok(first.assets.includes(file));
    assert.match(css, new RegExp(path.basename(file).replaceAll(".", "\\.")));
  }
  for (const file of first.assets) {
    assert.match(file, /^assets\/[^/]+-(?:[A-Z0-9]{8}\.(?:css|woff2)|[a-f0-9]{20}\.js)$/);
    assert.ok((await readFile(path.join(outDir, file))).length > 0);
  }
  for (const file of ["index.html", ...first.assets.filter((file) => /\.(js|css)$/.test(file))]) {
    const raw = await readFile(path.join(outDir, file));
    const compressed = await readFile(path.join(outDir, file + ".gz"));
    assert.deepEqual(gunzipSync(compressed), raw, `compressed ${file} must match served content`);
    assert.ok(compressed.length < raw.length);
    const brotli = await readFile(path.join(outDir, file + ".br"));
    assert.deepEqual(brotliDecompressSync(brotli), raw, `Brotli ${file} must match served content`);
    assert.ok(brotli.length < compressed.length);
  }
  const shell = vm.runInNewContext(`${worker}\n;({ app: APP_SHELL, external: EXTERNAL_SHELL })`, { self: { addEventListener() {} } });
  assert.ok(shell.app.includes("./" + first.css));
  assert.ok(first.assets.every((file) => shell.app.includes("./" + file)));
  assert.ok(!shell.app.some((file) => file.startsWith("./css/")));
  assert.ok(!shell.external.some((file) => file.includes("fonts.googleapis")));
  assert.match(await readFile(path.join(outDir, "licenses/Inter.txt"), "utf8"), /SIL OPEN FONT LICENSE/);
  assert.match(await readFile(path.join(outDir, "licenses/IBM-Plex-Mono.txt"), "utf8"), /SIL OPEN FONT LICENSE/);
  const originalHtml = await readFile(path.join(sourceDir, "index.html"), "utf8");
  const barriers = (text) => [...text.matchAll(/<script[\s\S]*?<\/script>/g)].map(([tag]) => tag).filter((tag) => !/^<script src="(?!https:)/.test(tag));
  assert.deepEqual(barriers(html), barriers(originalHtml));
  assert.match(html, /<meta name="description" content="[^"]+">/);
  const scripts = first.assets.filter((file) => file.endsWith(".js"));
  assert.ok(scripts.length < 10, "collapse the 25 local script requests");
  assert.ok(scripts.length > 1, "preserve legacy global declaration boundaries");
  assert.ok(!shell.app.some((url) => /\.\/app\.js|\.\/tasks\.js/.test(url)));
  assert.ok(shell.app.includes("./latency-worker.js"));
  assert.deepEqual(await readFile(path.join(outDir, "app.js")), await readFile(path.join(sourceDir, "app.js")));

  const second = await buildClient({ sourceDir, outDir });
  assert.equal(second.css, first.css);
  assert.equal(second.cacheName, first.cacheName);
  await appendFile(path.join(sourceDir, "css/workspace.css"), "\n.build-regression { padding-left: 13px; }\n");
  const cssEdit = await buildClient({ sourceDir, outDir });
  assert.notEqual(cssEdit.css, first.css);
  assert.notEqual(cssEdit.cacheName, first.cacheName);
  assert.match(await readFile(path.join(outDir, cssEdit.css), "utf8"), /padding-left:13px/);
  await writeFile(path.join(sourceDir, "index.html"), originalHtml.replace("NRC TERMINAL", "NRC BUILD TEST"));
  const htmlEdit = await buildClient({ sourceDir, outDir });
  assert.equal(htmlEdit.css, cssEdit.css);
  assert.notEqual(htmlEdit.cacheName, cssEdit.cacheName);
  await appendFile(path.join(sourceDir, "app.js"), "\nwindow.buildRevisionRegression = 1;\n");
  const jsEdit = await buildClient({ sourceDir, outDir });
  assert.equal(jsEdit.css, htmlEdit.css);
  assert.notEqual(jsEdit.cacheName, htmlEdit.cacheName);
  assert.notDeepEqual(jsEdit.assets.filter((file) => file.endsWith(".js")), htmlEdit.assets.filter((file) => file.endsWith(".js")));
  await assert.rejects(buildClient({ sourceDir, outDir: sourceDir }), /must not contain/);
});

test("classic bundles preserve shared globals, capture timing, forward references and strict boundaries", async (t) => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "nrc-classic-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(path.join(dir, "assets"));
  const files = [
    'const initial = 11; function action() { return initial; } globalThis.captured = action;',
    'globalThis.shared = initial + 3;',
    'function action() { return captured() + 1; } globalThis.forward = typeof future;',
    'let future = 29; globalThis.futureValue = future;',
    '"use strict"; globalThis.strictThis = (function () { return this; })();',
    'globalThis.sloppyThis = (function () { return this; })();',
  ];
  for (const [i, code] of files.entries()) await writeFile(path.join(dir, `${i}.js`), code);
  const html = files.map((_, i) => `<script src="${i}.js"></script>`).join("\n");
  const built = await bundleScripts(html, dir, dir);
  assert.ok(built.assets.length < files.length);
  const context = vm.createContext({});
  for (const [, src] of built.html.matchAll(/<script src="([^"]+)"><\/script>/g)) vm.runInContext(await readFile(path.join(dir, src), "utf8"), context);
  assert.equal(context.captured(), 11);
  assert.equal(context.action(), 12);
  assert.equal(context.shared, 14);
  assert.equal(context.forward, "undefined");
  assert.equal(context.futureValue, 29);
  assert.equal(context.strictThis, undefined);
  assert.equal(vm.runInContext("sloppyThis === globalThis", context), true);
  assert.equal(vm.runInContext("initial", context), 11);
});

test("CDN, inline, module, defer and markup boundaries retain script order", async (t) => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "nrc-script-order-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(path.join(dir, "assets"));
  const barriers = ['<script src="https://example.com/vendor.js"></script>', '<script>window.ready = true;</script>', '<script type="module" src="module.js"></script>', '<script defer src="deferred.js"></script>', '<div id="later"></div>'];
  let html = "";
  for (const [i, barrier] of barriers.entries()) {
    await writeFile(path.join(dir, `${i}.js`), `window.step${i} = ${i};`);
    html += `<script src="${i}.js"></script>${barrier}`;
  }
  const built = await bundleScripts(html, dir, dir);
  assert.equal(built.assets.length, barriers.length);
  let cursor = 0;
  for (const [i, barrier] of barriers.entries()) {
    const scriptAt = built.html.indexOf(`<script src="${built.assets[i]}"></script>`, cursor);
    const barrierAt = built.html.indexOf(barrier, scriptAt);
    assert.ok(scriptAt >= cursor && barrierAt > scriptAt);
    cursor = barrierAt + barrier.length;
  }
});
