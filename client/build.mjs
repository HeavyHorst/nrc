import { build, transform } from "esbuild";
import { parse } from "acorn";
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";

const clientDir = fileURLToPath(new URL("./", import.meta.url));
const fontDir = path.join(clientDir, "node_modules");

function bindingNames(pattern) {
  if (!pattern) return [];
  if (pattern.type === "Identifier") return [pattern.name];
  if (pattern.type === "RestElement") return bindingNames(pattern.argument);
  if (pattern.type === "AssignmentPattern") return bindingNames(pattern.left);
  if (pattern.type === "ArrayPattern") return pattern.elements.flatMap(bindingNames);
  if (pattern.type === "ObjectPattern") return pattern.properties.flatMap((property) => bindingNames(property.value || property.argument));
  return [];
}

function scriptNames(program) {
  const declared = new Set(), mentioned = new Set();
  function visit(node, global = true, top = false) {
    if (!node || typeof node !== "object") return;
    if (node.type === "Identifier") mentioned.add(node.name);
    if (node.type === "Literal" && typeof node.value === "string") mentioned.add(node.value);
    if (global && (node.type === "FunctionDeclaration" || node.type === "ClassDeclaration")) bindingNames(node.id).forEach((name) => declared.add(name));
    if (global && node.type === "VariableDeclaration" && (top || node.kind === "var")) {
      node.declarations.flatMap((declaration) => bindingNames(declaration.id)).forEach((name) => declared.add(name));
    }
    const childGlobal = global && !/^(?:Function|ArrowFunction|Class)/.test(node.type || "");
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) value.forEach((child) => visit(child, childGlobal, node.type === "Program"));
      else if (value && typeof value === "object") visit(value, childGlobal);
    }
  }
  visit(program);
  return { declared, mentioned };
}

// These legacy classic scripts share global bindings. Do not turn them into
// modules/IIFEs or rename top-level names used by inline handlers and other files.
export async function bundleScripts(html, sourceDir, outDir) {
  const assets = [];
  const sources = new Set();
  let output = "", cursor = 0, pending = [], names = new Set();
  const flush = async () => {
    if (!pending.length) return;
    const { code } = await transform(pending.join("\n;\n"), {
      loader: "js", minifyWhitespace: true, minifyIdentifiers: true,
      // Avoid cross-file constant propagation; preserve the global script format.
      minifySyntax: false, legalComments: "inline",
    });
    const hash = createHash("sha256").update(code).digest("hex").slice(0, 20);
    const asset = `assets/classic-${hash}.js`;
    await writeFile(path.join(outDir, asset), code);
    assets.push(asset);
    output += `<script src="${asset}"></script>\n`;
    pending = [];
    names = new Set();
  };
  for (const match of html.matchAll(/<script\b[^>]*>[\s\S]*?<\/script>/gi)) {
    const gap = html.slice(cursor, match.index);
    if (gap.trim()) await flush();
    output += gap;
    cursor = match.index + match[0].length;
    const src = /^<script\s+src="([^"<>]+)"\s*><\/script>$/i.exec(match[0])?.[1];
    // Inline, CDN, module, async/defer and attributed tags are execution barriers.
    if (!src || /^(?:[a-z]+:|\/)/i.test(src)) {
      await flush();
      output += match[0];
      continue;
    }
    const file = path.resolve(sourceDir, src.split("?")[0]);
    if (!file.startsWith(path.resolve(sourceDir) + path.sep)) throw new Error(`Script outside client: ${src}`);
    const code = await readFile(file, "utf8");
    const program = parse(code, { ecmaVersion: "latest", sourceType: "script" });
    const { declared, mentioned } = scriptNames(program);
    const strict = program.body.some((node) => node.directive === "use strict");
    // Do not make later declarations visible earlier: this changes function
    // capture and turns typeof checks into TDZ errors for later let/const names.
    // Conservatively include mentions inside functions and property names too.
    if (strict || [...declared].some((name) => names.has(name))) await flush();
    pending.push(code);
    mentioned.forEach((name) => names.add(name));
    sources.add("./" + src);
    if (strict) await flush();
  }
  await flush();
  return { html: output + html.slice(cursor), assets, sources };
}

export async function buildClient({ sourceDir = clientDir, outDir = path.join(clientDir, "dist") } = {}) {
  sourceDir = path.resolve(sourceDir);
  outDir = path.resolve(outDir);
  if (sourceDir === outDir || sourceDir.startsWith(outDir + path.sep)) {
    throw new Error("Build output must not contain the source directory");
  }
  await rm(outDir, { recursive: true, force: true });
  const entries = await readdir(sourceDir);
  await mkdir(outDir, { recursive: true });
  for (const entry of entries) {
    await cp(path.join(sourceDir, entry), path.join(outDir, entry), {
      recursive: true,
      filter: (file) => {
        const relative = path.relative(sourceDir, file);
        return file !== outDir && !relative.split(path.sep).some((part) => ["node_modules", "dist", "build"].includes(part)) &&
          !relative.endsWith(".mjs") && !/^package(?:-lock)?\.json$/.test(relative) && !relative.endsWith("AGENTS.md");
      },
    });
  }

  let html = await readFile(path.join(sourceDir, "index.html"), "utf8");
  const localStyles = [...html.matchAll(/<link rel="stylesheet" href="(css\/[^\"]+)">/g)];
  if (!localStyles.length) throw new Error("No local application stylesheets found");
  const result = await build({
    absWorkingDir: sourceDir,
    stdin: {
      contents: localStyles.map(([, url]) => `@import ${JSON.stringify("./" + url)};`).join("\n"),
      resolveDir: sourceDir,
      loader: "css",
      sourcefile: "app.css",
    },
    bundle: true,
    minify: true,
    outdir: path.join(outDir, "assets"),
    entryNames: "app-[hash]",
    assetNames: "[name]-[hash]",
    loader: { ".woff2": "file" },
    metafile: true,
    plugins: [{
      name: "self-host-app-fonts",
      setup(builder) {
        builder.onResolve({ filter: /^https:\/\/fonts\.googleapis\.com\// }, () => ({ path: "app-fonts", namespace: "fonts" }));
        builder.onLoad({ filter: /.*/, namespace: "fonts" }, () => ({
          contents: [
            '@import "@fontsource-variable/inter/standard.css";',
            ...[400, 500, 700].map((weight) => `@import "@fontsource/ibm-plex-mono/${weight}.css";`),
          ].join("\n"),
          resolveDir: clientDir,
          loader: "css",
        }));
        builder.onLoad({ filter: /node_modules[/\\]@fontsource.*\.css$/ }, async ({ path: file }) => ({
          contents: (await readFile(file, "utf8"))
            .replaceAll("Inter Variable", "Inter")
            .replace(/, url\([^)]*\.woff\) format\('woff'\)/g, ""),
          resolveDir: path.dirname(file),
          loader: "css",
        }));
      },
    }],
  });
  const assets = Object.keys(result.metafile.outputs).map((file) =>
    path.relative(outDir, path.resolve(sourceDir, file)).split(path.sep).join("/"));
  const css = assets.find((file) => file.endsWith(".css"));
  html = html.replace(localStyles[0][0], `<link rel="stylesheet" href="${css}">`);
  for (const [tag] of localStyles.slice(1)) html = html.replace(tag, "");
  const preloads = ["inter-latin-standard-normal-", "ibm-plex-mono-latin-400-normal-"]
    .map((prefix) => {
      const font = assets.find((file) => path.basename(file).startsWith(prefix));
      if (!font) throw new Error(`Missing preload font: ${prefix}`);
      return `    <link rel="preload" href="${font}" as="font" type="font/woff2" crossorigin>`;
    }).join("\n");
  html = html.replace("</head>", `${preloads}\n</head>`);
  const scripts = await bundleScripts(html, sourceDir, outDir);
  html = scripts.html;
  assets.push(...scripts.assets);
  await writeFile(path.join(outDir, "index.html"), html);
  // Compress once at build time instead of spending server CPU on each request.
  for (const file of ["index.html", ...assets.filter((file) => /\.(js|css)$/.test(file))]) {
    const content = await readFile(path.join(outDir, file));
    await writeFile(path.join(outDir, file + ".gz"), gzipSync(content, { level: 9 }));
    await writeFile(path.join(outDir, file + ".br"), brotliCompressSync(content, {
      params: { [constants.BROTLI_PARAM_QUALITY]: 11 },
    }));
  }

  await mkdir(path.join(outDir, "licenses"), { recursive: true });
  for (const [pkg, name] of [["@fontsource-variable/inter", "Inter"], ["@fontsource/ibm-plex-mono", "IBM-Plex-Mono"]]) {
    await cp(path.join(fontDir, pkg, "LICENSE"), path.join(outDir, "licenses", `${name}.txt`));
  }

  // Replace source CSS/script URLs with generated assets in production's worker.
  // Hash shell contents too: HTML/JS-only edits update the installed revision.
  const workerSource = await readFile(path.join(sourceDir, "service-worker.js"), "utf8");
  const shell = vm.runInNewContext(`${workerSource}\n;({ app: APP_SHELL, external: EXTERNAL_SHELL })`, {
    self: { addEventListener() {} },
  });
  const app = [...shell.app.filter((url) => !url.startsWith("./css/") && !scripts.sources.has(url)), ...assets.map((file) => "./" + file)];
  const external = shell.external.filter((url) => !url.startsWith("https://fonts.googleapis.com/"));
  const hash = createHash("sha256").update(workerSource).update(JSON.stringify({ app, external }));
  for (const url of app) {
    const file = url === "./" ? "index.html" : url.split("?")[0];
    hash.update(url).update(await readFile(path.join(outDir, file)));
  }
  const cacheName = `nrc-terminal-build-${hash.digest("hex").slice(0, 20)}`;
  const worker = workerSource
    .replace(/const CACHE_NAME = [^;]+;/, `const CACHE_NAME = ${JSON.stringify(cacheName)};`)
    .replace(/const APP_SHELL = \[[\s\S]*?\];/, `const APP_SHELL = ${JSON.stringify(app, null, 2)};`)
    .replace(/const EXTERNAL_SHELL = \[[\s\S]*?\];/, `const EXTERNAL_SHELL = ${JSON.stringify(external, null, 2)};`);
  await writeFile(path.join(outDir, "service-worker.js"), worker);
  return { outDir, css, assets, cacheName };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { outDir, assets, cacheName } = await buildClient();
  console.log(`Built ${outDir}: ${assets.length} hashed CSS/font/script assets; ${cacheName}`);
}
