// Local measurement fixture only: never deploy this automatic test identity.
import { createHmac, randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const dir = path.join(root, ".amp/lighthouse");
await mkdir(dir, { recursive: true, mode: 0o700 });
const keyFile = path.join(dir, "secrets.json");
try {
  await writeFile(keyFile, JSON.stringify({ jwt: randomBytes(32).toString("hex"), bot: randomBytes(32).toString("hex") }), { flag: "wx", mode: 0o600 });
} catch (error) {
  if (error.code !== "EEXIST") throw error;
}
const keys = JSON.parse(await readFile(keyFile, "utf8"));

function run(command, args, cwd, env = {}) {
  const child = spawn(command, args, { cwd, env: { ...process.env, ...env }, stdio: "inherit" });
  for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => child.kill(signal));
  child.on("error", (error) => { console.error(error.message); process.exitCode = 1; });
  child.on("exit", (code, signal) => { process.exitCode = code ?? (signal ? 1 : 0); });
}

switch (process.argv[2]) {
  case "backend":
    await mkdir(path.join(dir, "backend/data"), { recursive: true });
    run(path.join(dir, "server"), [], path.join(dir, "backend"), {
      NRC_PORT: "8080", NRC_THREAD_COUNT: "1", NRC_DISABLE_CPU_AFFINITY: "1",
      NRC_JWT_SECRET: keys.jwt, NRC_JWT_ISSUER: "nrc-local", NRC_JWT_AUDIENCE: "nrc",
      NRC_BOT_SECRET: keys.bot, NRC_MESSAGE_RETENTION: "0",
    });
    break;
  case "search":
    run(path.join(dir, "search"), [], dir, {
      NRC_SERVER: "ws://127.0.0.1:8080", SEARCH_PORT: "8090",
      NRC_BOT_SECRET: keys.bot, NRC_NICKNAME: "local-search",
      MODEL_PATH: path.join(dir, "models/model.onnx"),
      TOKENIZER_PATH: path.join(dir, "models/tokenizer.json"),
      ONNXRUNTIME_PATH: path.join(dir, "lib/onnxruntime-linux-x64-1.24.1/lib/libonnxruntime.so.1.24.1"),
      DATA_DIR: path.join(dir, "search-data"),
    });
    break;
  case "auth":
    http.createServer((req, res) => {
      if (req.url !== "/auth") { res.writeHead(404).end(); return; }
      const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
      const now = Math.floor(Date.now() / 1000);
      const unsigned = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({
        sub: "lighthouse-local", username: "lighthouse-local", user_type: "user",
        iss: "nrc-local", aud: "nrc", nbf: now - 5, exp: now + 300,
      })}`;
      const token = `${unsigned}.${createHmac("sha256", keys.jwt).update(unsigned).digest("base64url")}`;
      res.writeHead(204, { "X-NRC-Auth": token, "Cache-Control": "no-store" }).end();
    }).listen(8093, "127.0.0.1", () => console.log("Local test identity ready on loopback"));
    break;
  case "nginx": {
    // Reuse production compression, cache rules, and routing; only adapt hosting
    // paths, Docker DNS, and the identity provider for this isolated fixture.
    let config = await readFile(path.join(root, "docker/nginx/nginx.conf"), "utf8");
    config = `daemon off;\npid ${dir}/nginx.pid;\nerror_log stderr;\n` + config
      .replace("http {", `http {\n    access_log off;\n    client_body_temp_path ${dir}/body;\n    proxy_temp_path ${dir}/proxy;\n    fastcgi_temp_path ${dir}/fastcgi;\n    uwsgi_temp_path ${dir}/uwsgi;\n    scgi_temp_path ${dir}/scgi;`)
      .replace("listen 80;", "listen 127.0.0.1:8000;")
      .replace("root /usr/share/nginx/html;", `root ${root}/client/dist;`)
      .replace("http://websocket-server:8080", "http://127.0.0.1:8080")
      .replace("http://search:8090", "http://127.0.0.1:8090")
      // No AI service belongs to this fixture; never reach another local service.
      .replace(/location \^~ \/ai\/ \{[^}]*\}/, "location ^~ /ai/ { return 503; }")
      .replace("location ~ ^/[^./]+$ {", `location = /__local_auth {
            internal;
            proxy_pass http://127.0.0.1:8093/auth;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
        }
        location ~ ^/[^./]+$ {
            auth_request /__local_auth;
            auth_request_set $local_token $upstream_http_x_nrc_auth;`)
      .replace("proxy_set_header X-NRC-Auth $http_x_nrc_auth;", "proxy_set_header X-NRC-Auth $local_token;");
    const configPath = path.join(dir, "nginx.conf");
    await writeFile(configPath, config);
    run("/usr/sbin/nginx", ["-p", dir, "-c", configPath], root);
    break;
  }
  default:
    throw new Error("Usage: node test/lighthouse-local.mjs backend|search|auth|nginx");
}
