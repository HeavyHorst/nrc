// Isolated real-server UI fixture. Never deploy this identity-bypassing proxy.
// Build first: odin build . -out:/tmp/nrc-customers-server
// Run: NRC_TEST_SERVER=/tmp/nrc-customers-server node test/customer-workspace-dev.mjs
// All data lives in a temporary directory; the production data/ is never opened.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import net from "node:net";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../client/", import.meta.url));
const binary = process.env.NRC_TEST_SERVER;
const backendPort = Number(process.env.NRC_TEST_BACKEND_PORT || 8080);
const httpPort = Number(process.env.NRC_TEST_HTTP_PORT || 8091);
if (!binary || !path.isAbsolute(binary)) throw new Error("NRC_TEST_SERVER must name an absolute server binary path");
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nrc-customers-"));
const generation = path.join(dir, "data/sharded-00000000000000000001");
for (let shard = 0; shard < 256; shard++) {
  const shardDir = path.join(generation, `shard_${String(shard).padStart(3, "0")}`);
  fs.mkdirSync(shardDir, { recursive: true });
  fs.writeFileSync(path.join(shardDir, "active.wal"), "");
}
fs.writeFileSync(path.join(dir, "data/storage-layout.manifest"), Buffer.from("TlJDTAABAAAAAAAAAAAAAQIBAAAAAAAAAAABAAABAACsNnTeRP92XA==", "base64"));
const secret = crypto.randomBytes(32).toString("hex");
const backend = spawn(binary, [], { cwd: dir, env: { ...process.env, NRC_PORT: String(backendPort), NRC_JWT_SECRET: secret, NRC_THREAD_COUNT: "1", NRC_DISABLE_CPU_AFFINITY: "1", NRC_LOG_LEVEL: "error" }, stdio: "inherit" });
function token() {
  const now = Math.floor(Date.now() / 1000);
  const encode = data => Buffer.from(JSON.stringify(data)).toString("base64url");
  const input = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ sub: "customer-preview", username: "customer-preview", iss: "nrc-tailscale-proxy", aud: "nrc", nbf: now - 2, exp: now + 300 })}`;
  return input + "." + crypto.createHmac("sha256", secret).update(input).digest("base64url");
}
// Attachment stand-in. The disposable fixture has no tailscale-proxy, so uploads
// are held in memory and served back from /files/. The contract matches the
// proxy: POST /upload (multipart, field "file") answers with the attachment
// header, GET /files/<fileId>?filename=&inline=true returns the stored bytes.
const uploads = new Map();
// The Go CLI uploads multipart parts without a content type, so the fixture
// falls back to the filename, the way a browser upload already carries one.
const MIME_BY_EXTENSION = {
  ".pdf": "application/pdf", ".csv": "text/csv", ".svg": "image/svg+xml", ".png": "image/png",
  ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".txt": "text/plain", ".md": "text/markdown", ".json": "application/json",
};
function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}
function jsonResponse(res, status, value) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(value));
}
async function handleUpload(req, res) {
  const form = await new Response(await readBody(req), { headers: { "content-type": req.headers["content-type"] || "" } }).formData();
  const file = form.get("file");
  if (!file || typeof file === "string") { jsonResponse(res, 400, { error: "missing file field" }); return; }
  const bytes = Buffer.from(await file.arrayBuffer());
  const fileId = `att_${crypto.randomBytes(16).toString("hex")}`;
  const filename = file.name || "upload.bin";
  const declared = file.type && file.type !== "application/octet-stream" ? file.type : "";
  const mimeType = declared || MIME_BY_EXTENSION[path.extname(filename).toLowerCase()] || "application/octet-stream";
  uploads.set(fileId, { filename, mimeType, bytes });
  jsonResponse(res, 200, { fileId, filename, size: bytes.length, mimeType, uploadedAt: Date.now() * 1000000 });
}
function handleDownload(req, res, fileId) {
  const stored = uploads.get(fileId);
  if (!stored) { res.writeHead(404, { "Content-Type": "text/plain" }); res.end("Unknown attachment"); return; }
  const inline = new URL(req.url, "http://fixture").searchParams.get("inline") === "true";
  res.writeHead(200, {
    "Content-Type": stored.mimeType,
    "Content-Length": stored.bytes.length,
    "Content-Disposition": `${inline ? "inline" : "attachment"}; filename="${stored.filename.replace(/["\\\r\n]/g, "_")}"`,
  });
  res.end(stored.bytes);
}
const server = http.createServer((req, res) => {
  const pathname = new URL(req.url, "http://fixture").pathname;
  res.setHeader("Cache-Control", "no-store");
  if (pathname === "/api/features") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end('{"customers":true}');
    return;
  }
  if (pathname === "/upload" && req.method === "POST") {
    handleUpload(req, res).catch(() => jsonResponse(res, 400, { error: "malformed upload" }));
    return;
  }
  if (pathname.startsWith("/files/") && req.method === "GET") {
    handleDownload(req, res, decodeURIComponent(pathname.slice("/files/".length)));
    return;
  }
  const file = path.resolve(root, "." + decodeURIComponent(pathname === "/" ? "/index.html" : pathname));
  if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
  fs.readFile(file, (error, data) => {
    if (error) { res.writeHead(404).end(); return; }
    const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2" };
    res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream" });
    res.end(data);
  });
});
server.on("upgrade", (req, socket, head) => {
  const upstream = net.connect(backendPort, "127.0.0.1", () => {
    // Portal requests carry cookies and proxy metadata that the NRC handshake
    // does not need and that can exceed its deliberately small header budget.
    const forwarded = new Set(["origin", "sec-websocket-extensions", "sec-websocket-key", "sec-websocket-protocol", "sec-websocket-version"]);
    const headers = Object.entries(req.headers)
      .filter(([key, value]) => forwarded.has(key) && value !== undefined)
      .map(([key, value]) => `${key}: ${value}`);
    headers.unshift("Host: 127.0.0.1:8080", "Connection: Upgrade", "Upgrade: websocket");
    upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n${headers.join("\r\n")}\r\nX-NRC-Auth: ${token()}\r\n\r\n`);
    if (head.length) upstream.write(head);
    socket.pipe(upstream);
    let response = Buffer.alloc(0);
    const forwardHandshake = chunk => {
      response = Buffer.concat([response, chunk]);
      const text = response.toString("latin1");
      const match = /\r?\n\r?\n/.exec(text);
      if (!match) return;
      upstream.off("data", forwardHandshake);
      const headerEnd = match.index + match[0].length;
      socket.write(`${text.slice(0, match.index).split(/\r?\n/).join("\r\n")}\r\n\r\n`, "latin1");
      if (headerEnd < response.length) socket.write(response.subarray(headerEnd));
      upstream.pipe(socket);
    };
    upstream.on("data", forwardHandshake);
  });
  socket.on("error", () => upstream.destroy());
  socket.on("close", () => upstream.destroy());
  upstream.on("error", () => socket.destroy());
});
let stopping = false;
function stop() {
  if (stopping) return;
  stopping = true;
  server.close();
  backend.kill("SIGINT");
}
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
backend.on("exit", code => {
  fs.rmSync(dir, { recursive: true, force: true });
  if (!stopping) console.error("Fixture backend exited", code);
  process.exit(code || 0);
});
server.listen(httpPort, "127.0.0.1", () => console.log(`Customer fixture on port ${httpPort}; fake identity, disposable data.`));

// Optional demo content: NRC_FIXTURE_SEED=1 seeds notes, tasks, files, links and
// messages into the fixture's default workspace. The store is disposable and
// wiped with the fixture, so a restart re-seeds instead of accumulating. The
// seed waits for the backend itself; this only starts it.
if (process.env.NRC_FIXTURE_SEED) {
  const seed = fileURLToPath(new URL("./seed-demo-workspace.mjs", import.meta.url));
  const workspace = process.env.NRC_FIXTURE_SEED_WORKSPACE || "workspace1";
  const seeding = spawn(process.execPath, [seed, "--url", `http://127.0.0.1:${httpPort}`, "--workspace", workspace], { stdio: "inherit" });
  seeding.on("exit", code => console.log(code === 0 ? "Fixture demo workspace seeded." : `Fixture seed exited with ${code}.`));
}
