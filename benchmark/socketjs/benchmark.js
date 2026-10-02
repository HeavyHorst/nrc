const { spawn } = require("node:child_process");
const net = require("node:net");
const { parseArgs } = require("node:util");
const { URL } = require("node:url");
const jwt = require("jsonwebtoken");
const { io } = require("socket.io-client");

const options = parseArgs({
  options: {
    server: { type: "string", default: "ws://127.0.0.1:8081" },
    users: { type: "string", default: "100" },
    duration: { type: "string", default: "60" },
    rampup: { type: "string", default: "10" },
    messageInterval: { type: "string", default: "1" },
    workspaces: { type: "string", default: "4" },
    conversations: { type: "string", default: "10" },
    convsPerUser: { type: "string", default: "3" },
    msgSize: { type: "string", default: "128" },
    auth: { type: "boolean", default: false },
    startServer: { type: "boolean", default: false },
    jwtSecret: { type: "string", default: "dev-insecure-nrc-jwt-secret" },
    jwtIssuer: { type: "string", default: "nrc-tailscale-proxy" },
    jwtAudience: { type: "string", default: "nrc" },
  },
}).values;

const cfg = {
  server: options.server,
  users: Number(options.users),
  durationSec: Number(options.duration),
  rampupSec: Number(options.rampup),
  msgIntervalSec: Number(options.messageInterval),
  workspaces: Number(options.workspaces),
  conversations: Number(options.conversations),
  convsPerUser: Number(options.convsPerUser),
  msgSize: Number(options.msgSize),
  auth: options.auth,
  startServer: options.startServer,
  jwtSecret: options.jwtSecret,
  jwtIssuer: options.jwtIssuer,
  jwtAudience: options.jwtAudience,
};

const metrics = {
  connectTimesMs: [],
  rttsMs: [],
  sent: 0,
  recv: 0,
  failed: 0,
  connected: 0,
};

const clients = [];
let reqID = 1;
const pending = new Map();

function percentile(arr, p) {
  if (!arr.length) return 0;
  const sorted = [...arr].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForPort(urlString, timeoutMs) {
  const parsed = new URL(urlString);
  const host = parsed.hostname;
	const port = Number(parsed.port || (parsed.protocol === "wss:" ? 443 : 80));

	const started = Date.now();
	while (Date.now() - started < timeoutMs) {
		const connected = await new Promise((resolve) => {
      const socket = net.createConnection({ host, port });
      socket.once("connect", () => {
				socket.destroy();
				resolve(true);
      });
			socket.once("error", () => resolve(false));
			setTimeout(() => {
				socket.destroy();
				resolve(false);
			}, 250);
		});
		if (connected) return;
		await sleep(100);
	}
	throw new Error("timeout waiting for socketjs server");
}

function makeJWT(username) {
  return jwt.sign(
    {
      sub: username,
      username,
      iss: cfg.jwtIssuer,
      aud: cfg.jwtAudience,
      nbf: Math.floor(Date.now() / 1000) - 2,
    },
    cfg.jwtSecret,
    { algorithm: "HS256", expiresIn: "5m" }
  );
}

function workspaceForUser(userID) {
  return `ws-${userID % cfg.workspaces}`;
}

function convsForUser(userID) {
  const convs = [];
  for (let i = 0; i < cfg.convsPerUser; i++) {
    convs.push((userID + i) % cfg.conversations + 1);
  }
  return convs;
}

function randomContent() {
  const chars = [];
  for (let i = 0; i < cfg.msgSize; i++) chars.push(String.fromCharCode(97 + (i % 26)));
  return chars.join("");
}

async function main() {
  let managed = null;
 	try {
    if (cfg.startServer) {
      managed = spawn("node", ["server.js"], {
				cwd: __dirname,
        env: {
					...process.env,
					AUTH_ENABLED: cfg.auth ? "1" : "0",
					NRC_JWT_SECRET: cfg.jwtSecret,
					JWT_ISSUER: cfg.jwtIssuer,
					JWT_AUDIENCE: cfg.jwtAudience,
				},
      stdio: "inherit",
    });
    await waitForPort(cfg.server, 10000);
  }

  process.stdout.write(`SocketJS benchmark: users=${cfg.users} duration=${cfg.durationSec}s workspaces=${cfg.workspaces}\n`);

  const start = Date.now();
  const rampDelayMs = cfg.users > 1 ? (cfg.rampupSec * 1000) / cfg.users : 0;

  const launchClient = (userID) => {
    const connectedAt = Date.now();
    const workspace = workspaceForUser(userID);
    const username = `user-${userID}`;
    const headers = cfg.auth ? { "X-NRC-Auth": makeJWT(username) } : undefined;

    const socket = io(cfg.server, {
      transports: ["websocket"],
      reconnection: false,
      auth: { workspace },
      extraHeaders: headers,
    });

    const client = {
      socket,
      convs: convsForUser(userID),
      timer: null,
      started: false,
      startSending() {
        if (this.started) return;
        this.started = true;
        const tick = () => {
          this.send();
          this.timer = setTimeout(tick, cfg.msgIntervalSec * 1000);
        };
        this.timer = setTimeout(tick, Math.random() * cfg.msgIntervalSec * 1000);
      },
      send() {
        if (!socket.connected) return;
        const convID = this.convs[Math.floor(Math.random() * this.convs.length)];
        const thisReqID = reqID++;
        const sentAt = process.hrtime.bigint();
        pending.set(thisReqID, sentAt);
        socket.emit(
          "send_message",
          { convID, clientReqID: thisReqID, content: randomContent(), username },
          (ack) => {
            const startedAt = pending.get(ack.clientReqID);
            if (startedAt) {
              const ms = Number(process.hrtime.bigint() - startedAt) / 1e6;
              metrics.rttsMs.push(ms);
              pending.delete(ack.clientReqID);
            }
          }
        );
        metrics.sent++;
      },
    };

    socket.on("connect", () => {
      metrics.connected++;
      metrics.connectTimesMs.push(Date.now() - connectedAt);
      socket.emit("subscribe_convs", { convIDs: convsForUser(userID) });
      client.startSending();
    });

    socket.on("connect_error", () => {
      metrics.failed++;
    });

    socket.on("new_message", () => {
      metrics.recv++;
    });

    clients.push(client);
  };

  for (let userID = 0; userID < cfg.users; userID++) {
    const delay = Math.floor(userID * rampDelayMs);
    setTimeout(() => launchClient(userID), delay);
  }

  await sleep(cfg.durationSec * 1000);

  const elapsedSec = (Date.now() - start) / 1000;
  const p50 = percentile(metrics.rttsMs, 50);
  const p95 = percentile(metrics.rttsMs, 95);
  const p99 = percentile(metrics.rttsMs, 99);

  process.stdout.write("\n=== SocketJS Benchmark Results ===\n");
  process.stdout.write(`Duration: ${elapsedSec.toFixed(1)}s\n`);
  process.stdout.write(`Connections: total=${metrics.connected} failed=${metrics.failed}\n`);
  process.stdout.write(
    `Connect Time: p50=${percentile(metrics.connectTimesMs, 50).toFixed(2)}ms p95=${percentile(metrics.connectTimesMs, 95).toFixed(2)}ms p99=${percentile(metrics.connectTimesMs, 99).toFixed(2)}ms\n`
    );
  process.stdout.write(`Messages: sent=${metrics.sent} (${(metrics.sent / elapsedSec).toFixed(1)}/sec) recv=${metrics.recv} (${(metrics.recv / elapsedSec).toFixed(1)}/sec)\n`);
  process.stdout.write(`RTT: p50=${p50.toFixed(2)}ms p95=${p95.toFixed(2)}ms p99=${p99.toFixed(2)}ms\n`);
  } finally {
    for (const c of clients) {
      clearTimeout(c.timer);
      c.socket.disconnect();
    }
    if (managed && !managed.killed) {
      managed.kill("SIGINT");
      await sleep(500);
      if (!managed.killed) {
        managed.kill("SIGKILL");
      }
    }
		}
}

main().catch((err) => {
  process.stderr.write(`${err.stack || err.message}\n`);
  process.exit(1);
});
