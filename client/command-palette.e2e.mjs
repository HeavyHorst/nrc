import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const clientRoot = __dirname;
const odinBin = process.env.ODIN_BIN || "odin";
const wsPort = 8080;
const e2eJWTSecret = "dev-insecure-nrc-jwt-secret";
const e2eJWTIssuer = "nrc-tailscale-proxy";
const e2eJWTAudience = "nrc";

async function importPlaywright() {
  try {
    return await import("playwright");
  } catch (err) {
    throw new Error(
      "Playwright is required for this E2E test. Install it with `npm install --no-save playwright` " +
        "and, if needed, `npx playwright install chromium`.",
      { cause: err },
    );
  }
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit", ...options });
    child.on("error", reject);
    child.on("exit", (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} ${args.join(" ")} failed (${code ?? signal})`));
    });
  });
}

function isPortFree(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.once("listening", () => server.close(() => resolve(true)));
    server.listen(port, "127.0.0.1");
  });
}

function waitForTcp(port, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const socket = net.connect({ port, host: "127.0.0.1" });
      socket.once("connect", () => {
        socket.destroy();
        resolve();
      });
      socket.once("error", () => {
        socket.destroy();
        if (Date.now() > deadline) reject(new Error(`Timed out waiting for port ${port}`));
        else setTimeout(attempt, 100);
      });
    };
    attempt();
  });
}

function initializeEmptyShardedLayout(workDir) {
  const dataDir = path.join(workDir, "data");
  const generationDir = path.join(dataDir, "sharded-00000000000000000001");
  for (let shard = 0; shard < 256; shard += 1) {
    const shardDir = path.join(generationDir, `shard_${String(shard).padStart(3, "0")}`);
    fs.mkdirSync(shardDir, { recursive: true });
    fs.writeFileSync(path.join(shardDir, "active.wal"), Buffer.alloc(0));
  }
  // Fixed generation-1 Sharded_V1 manifest. The server still validates the
  // production wire format and complete generation before it starts.
  fs.writeFileSync(
    path.join(dataDir, "storage-layout.manifest"),
    Buffer.from("TlJDTAABAAAAAAAAAAAAAQIBAAAAAAAAAAABAAABAACsNnTeRP92XA==", "base64"),
  );
}

function contentType(filePath) {
  if (filePath.endsWith(".html")) return "text/html; charset=utf-8";
  if (filePath.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (filePath.endsWith(".css")) return "text/css; charset=utf-8";
  if (filePath.endsWith(".svg")) return "image/svg+xml";
  if (filePath.endsWith(".png")) return "image/png";
  if (filePath.endsWith(".ico")) return "image/x-icon";
  return "application/octet-stream";
}

function startStaticServer(root, authToken) {
  const server = http.createServer((req, res) => {
    const rawPath = new URL(req.url, "http://127.0.0.1").pathname;
    const decodedPath = decodeURIComponent(rawPath === "/" ? "/index.html" : rawPath);
    const filePath = path.resolve(root, `.${decodedPath}`);
    if (!filePath.startsWith(root + path.sep)) {
      res.writeHead(403).end("forbidden");
      return;
    }
    fs.readFile(filePath, (err, data) => {
      if (err) {
        res.writeHead(404).end("not found");
        return;
      }
      res.writeHead(200, { "content-type": contentType(filePath) });
      res.end(data);
    });
  });

  server.on("upgrade", (req, socket, head) => {
    const upstream = net.connect({ host: "127.0.0.1", port: wsPort }, () => {
      const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
      let sawHost = false;
      for (let i = 0; i < req.rawHeaders.length; i += 2) {
        const name = req.rawHeaders[i];
        const value = req.rawHeaders[i + 1];
        if (name.toLowerCase() === "host") {
          sawHost = true;
          lines.push(`Host: 127.0.0.1:${wsPort}`);
          continue;
        }
        if (name.toLowerCase() === "x-nrc-auth") continue;
        lines.push(`${name}: ${value}`);
      }
      if (!sawHost) lines.push(`Host: 127.0.0.1:${wsPort}`);
      lines.push(`X-NRC-Auth: ${authToken}`);
      upstream.write(`${lines.join("\r\n")}\r\n\r\n`);
      if (head.length > 0) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on("error", () => socket.destroy());
    socket.on("error", () => upstream.destroy());
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      resolve({
        server,
        url: `http://127.0.0.1:${server.address().port}`,
      });
    });
  });
}

function base64UrlJson(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function buildProxyStyleJWT(username) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64UrlJson({ alg: "HS256", typ: "JWT" });
  const payload = base64UrlJson({
    sub: username,
    username,
    iss: e2eJWTIssuer,
    aud: e2eJWTAudience,
    nbf: now - 2,
    exp: now + 5 * 60,
  });
  const signingInput = `${header}.${payload}`;
  const signature = crypto
    .createHmac("sha256", e2eJWTSecret)
    .update(signingInput)
    .digest("base64url");
  return `${signingInput}.${signature}`;
}

async function main() {
  const { chromium } = await importPlaywright();

  if (!(await isPortFree(wsPort))) {
    throw new Error(`Port ${wsPort} is already in use. Stop the running NRC server before this E2E test.`);
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "nrc-command-palette-e2e-"));
  const serverBin = path.join(tmpDir, "server");
  let serverProcess = null;
  let staticServer = null;
  let browser = null;
  let shuttingDown = false;
  const serverLogs = [];
  const browserLogs = [];

  try {
    await run(odinBin, ["build", ".", `-out:${serverBin}`], { cwd: repoRoot });
    initializeEmptyShardedLayout(tmpDir);

    serverProcess = spawn(serverBin, [], {
      cwd: tmpDir,
      env: {
        ...process.env,
        NRC_JWT_SECRET: e2eJWTSecret,
        NRC_THREAD_COUNT: "1",
        NRC_LOG_LEVEL: "error",
        NRC_DISABLE_CPU_AFFINITY: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    serverProcess.stdout.on("data", (chunk) => serverLogs.push(`[server stdout] ${chunk}`));
    serverProcess.stderr.on("data", (chunk) => serverLogs.push(`[server stderr] ${chunk}`));
    serverProcess.once("exit", (code, signal) => {
      if (!shuttingDown && (code !== null && code !== 0 || signal)) {
        serverLogs.push(`server exited unexpectedly (${code ?? signal})`);
      }
    });
    await waitForTcp(wsPort);

    const staticInfo = await startStaticServer(clientRoot, buildProxyStyleJWT(`palette-e2e-${Date.now()}`));
    staticServer = staticInfo.server;

    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext();
    await context.grantPermissions(["notifications"], { origin: staticInfo.url });
    const page = await context.newPage();

    page.on("console", (msg) => browserLogs.push(`[browser ${msg.type()}] ${msg.text()}`));
    page.on("pageerror", (err) => browserLogs.push(`[pageerror] ${err.message}`));

    await page.goto(staticInfo.url, { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#connectionStatus.connected", { timeout: 15_000 });
    await page.waitForSelector("#usersList .user-item", { timeout: 15_000 });

    async function openPaletteForCommand(title) {
      await page.keyboard.press("Control+P");
      await page.waitForSelector("#commandPalette:not(.hidden)");
      await page.fill("#paletteInput", title);
      await page.locator("#paletteResults .palette-option-cmd", { hasText: title }).first().waitFor({ timeout: 5_000 });
    }

    async function closePalette() {
      if (await page.locator("#commandPalette:not(.hidden)").count()) {
        await page.keyboard.press("Escape");
        await page.locator("#commandPalette").waitFor({ state: "hidden", timeout: 5_000 });
      }
    }

    async function executePaletteCommand(title, arg = null) {
      await openPaletteForCommand(title);
      await page.keyboard.press("Enter");
      if (arg !== null) {
        await page.waitForSelector("#paletteArgBar:not(.hidden)", { timeout: 5_000 });
        await page.fill("#paletteArgField", arg);
        await page.keyboard.press("Enter");
      }
      await page.locator("#commandPalette").waitFor({ state: "hidden", timeout: 5_000 });
    }

    async function waitForLogText(match, timeout = 5_000) {
      try {
        await page.waitForFunction((source) => {
          const text = document.querySelector("#logOutput")?.textContent || "";
          if (source.regex) return new RegExp(source.value).test(text);
          return text.includes(source.value);
        }, typeof match === "string" ? { value: match, regex: false } : { value: match.source, regex: true }, { timeout });
      } catch (err) {
        throw new Error(`Timed out waiting for message ledger text: ${match}`, { cause: err });
      }
    }

    async function waitForBrowserLog(match, timeout = 5_000) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        if (browserLogs.some((entry) => typeof match === "string" ? entry.includes(match) : match.test(entry))) return;
        await page.waitForTimeout(50);
      }
      throw new Error(`Timed out waiting for browser log: ${match}`);
    }

    async function waitForBrowserLogAfter(startIndex, match, timeout = 5_000) {
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        if (browserLogs.slice(startIndex).some((entry) => typeof match === "string" ? entry.includes(match) : match.test(entry))) return;
        await page.waitForTimeout(50);
      }
      throw new Error(`Timed out waiting for browser log after ${startIndex}: ${match}`);
    }

    const paletteCommands = [
      { title: "Show help" },
      { title: "Join room", arg: "room" },
      { title: "Leave room", arg: "room" },
      { title: "Switch room", arg: "room" },
      { title: "Switch workspace", arg: "workspace_id" },
      { title: "Clear room messages" },
      { title: "Refresh participants" },
      { title: "Reconnect" },
      { title: "Create task", arg: "title" },
      { title: "Mark task done", arg: "task_id" },
      { title: "Delete task", arg: "task_id" },
      { title: "Refresh tasks" },
      { title: "Create note", arg: "text" },
      { title: "Filter task by assignee", arg: "assignee" },
      { title: "Start direct message", arg: "username" },
      { title: "AI: Create task from text", arg: "text" },
      { title: "AI: Create note from text", arg: "text" },
      { title: "Sullivan Workbench", arg: "request" },
      { title: "Enable notifications" },
      { title: "Set theme", arg: "theme" },
    ];

    for (const command of paletteCommands) {
      await openPaletteForCommand(command.title);
      if (command.arg) {
        await page.keyboard.press("Enter");
        await page.waitForSelector("#paletteArgBar:not(.hidden)", { timeout: 5_000 });
        assert.equal(await page.locator("#paletteArgField").getAttribute("placeholder"), command.arg.toUpperCase());
      }
      await closePalette();
    }

    await executePaletteCommand("Show help");
    await waitForLogText("AVAILABLE PALETTE ACTIONS");

    await executePaletteCommand("Set theme", "lupine");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "lupine");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "lupine");

    assert.equal(await page.evaluate(() => document.documentElement.hasAttribute("data-appearance")), false);
    await page.keyboard.press("Alt+t");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "matte-black");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "matte-black");
    await executePaletteCommand("Set theme", "tokyo-night");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "tokyo-night");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "tokyo-night");
    await executePaletteCommand("Set theme", "ayu");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "ayu");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "ayu");
    await executePaletteCommand("Set theme", "modus-vivendi");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "modus-vivendi");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "modus-vivendi");
    await executePaletteCommand("Set theme", "matte-black");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "matte-black");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "matte-black");
    await executePaletteCommand("Set theme", "kanagawa");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "kanagawa");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "kanagawa");
    await executePaletteCommand("Set theme", "solitude");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "solitude");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "solitude");
    await executePaletteCommand("Set theme", "lupine");
    await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "lupine");
    assert.equal(await page.evaluate(() => localStorage.getItem("nrc-theme")), "lupine");

    await executePaletteCommand("Enable notifications");
    assert.match(await page.evaluate(() => Notification.permission), /^(granted|denied)$/);

    await executePaletteCommand("Refresh participants");
    await waitForBrowserLog(/REFRESHING PARTICIPANTS/);

    await executePaletteCommand("Switch room", "OPERATIONS");
    await page.waitForFunction(() => currentRoomId === 3n);
    await executePaletteCommand("Switch room", "ENGINEERING");
    await page.waitForFunction(() => currentRoomId === 2n);
    assert.equal(await page.locator("#sidebarViewRoomName").textContent(), "WORKSPACE");

    const joinedRoom = `E2E-PALETTE-${Date.now()}`;
    await executePaletteCommand("Join room", joinedRoom);
    await waitForLogText(`JOINED ${joinedRoom}`, 10_000);
    await page.locator("#roomList").getByText(joinedRoom).waitFor({ timeout: 5_000 });
    await executePaletteCommand("Leave room", joinedRoom);
    await waitForLogText(`LEFT ${joinedRoom}`);
    await page.locator("#roomList").getByText(joinedRoom).waitFor({ state: "detached", timeout: 5_000 });

    const switchWorkspaceLogStart = browserLogs.length;
    await executePaletteCommand("Switch workspace", "workspace1");
    await waitForBrowserLogAfter(switchWorkspaceLogStart, "ALREADY IN WORKSPACE workspace1");

    await executePaletteCommand("Clear room messages");
    await waitForLogText("CLEARED MESSAGES FOR ENGINEERING");

    const reconnectLogStart = browserLogs.length;
    await executePaletteCommand("Reconnect");
    await waitForBrowserLogAfter(reconnectLogStart, "SERVER READY; INITIALIZING SESSION", 15_000);
    await page.waitForSelector("#connectionStatus.connected", { timeout: 15_000 });
    await waitForBrowserLogAfter(reconnectLogStart, "SESSION READY", 5_000);

    const noteTitle = `E2E palette note ${Date.now()}`;
    await executePaletteCommand("Create note", noteTitle);
    await page.waitForFunction((title) => {
      const assets = window.NRCAssets?.roomAssets?.get(0n);
      if (!assets) return false;
      return Array.from(assets.values()).some((asset) =>
        asset.assetType === 5 && ((asset.preview || "").includes(title) || (asset.payload || "").includes(title)),
      );
    }, noteTitle, { timeout: 10_000 });

    const dmLogStart = browserLogs.length;
    await executePaletteCommand("Start direct message", "missing-palette-user");
    await waitForBrowserLogAfter(dmLogStart, /DM ERROR: USER NOT FOUND/);

    await page.evaluate(() => {
      window.__paletteAiCalls = [];
      window.NRCAI = window.NRCAI || {};
      window.NRCAI.handlePasteToTask = (text) => window.__paletteAiCalls.push({ method: "task", text });
      window.NRCAI.handlePasteToNote = (text) => window.__paletteAiCalls.push({ method: "note", text });
      window.NRCAI.handleAsk = (question, options) => window.__paletteAiCalls.push({ method: "ask", question, options });
    });
    await executePaletteCommand("AI: Create task from text", "turn this into a task");
    await executePaletteCommand("AI: Create note from text", "turn this into a note");
    await executePaletteCommand("Sullivan Workbench", "what changed?");
    assert.deepEqual(await page.evaluate(() => window.__paletteAiCalls), [
      { method: "task", text: "turn this into a task" },
      { method: "note", text: "turn this into a note" },
      { method: "ask", question: "what changed?", options: { forceRoom: false } },
    ]);

    // Chat input must not execute palette actions or slash commands.
    await page.fill("#messageInput", "/help");
    await page.press("#messageInput", "Enter");
    await page.waitForTimeout(500);
    assert.equal(await page.locator("#logOutput").getByText("AVAILABLE PALETTE ACTIONS").count(), 0);

    // Palette shows action titles, not slash command labels.
    await page.keyboard.press("Control+P");
    await page.waitForSelector("#commandPalette:not(.hidden)");
    await page.fill("#paletteInput", "create task");
    await page.getByText("Create task", { exact: true }).waitFor({ timeout: 5_000 });
    assert.equal(await page.locator("#paletteResults").getByText("/task").count(), 0);

    const taskTitle = `E2E palette task ${Date.now()}`;
    await page.keyboard.press("Enter");
    await page.fill("#paletteArgField", taskTitle);
    await page.keyboard.press("Enter");

    const createdTaskId = await page.waitForFunction((title) => {
      const tasks = window.NRCTasks?.roomTasks?.get(0n);
      if (!tasks) return null;
      const task = Array.from(tasks.values()).find((it) => it.title === title);
      return task ? task.id.toString() : null;
    }, taskTitle, { timeout: 5_000 }).then((handle) => handle.jsonValue());

    const refreshTasksLogStart = browserLogs.length;
    await executePaletteCommand("Refresh tasks");
    await waitForBrowserLogAfter(refreshTasksLogStart, /LOADED \d+ WORKSPACE TASKS/);

    // Palette task filter must drive the actual task view filter state.
    await page.click("#tasksBtn");
    await page.click('[data-task-grouping="flat"]');
    await page.waitForSelector("#taskListView", { state: "visible", timeout: 5_000 });
    await page.locator("#taskListBody").getByText(taskTitle).waitFor({ timeout: 5_000 });

    await page.keyboard.press("Control+P");
    await page.fill("#paletteInput", "filter task by assignee");
    await page.keyboard.press("Enter");
    await page.waitForSelector("#paletteArgBar:not(.hidden)", { timeout: 5_000 });
    await page.fill("#paletteArgField", "my");
    await page.keyboard.press("Enter");
    await page.locator("#taskListBody").getByText("NO TASKS").waitFor({ timeout: 5_000 });
    assert.equal(await page.locator("#taskListBody").getByText(taskTitle).count(), 0);

    await page.keyboard.press("Control+P");
    await page.fill("#paletteInput", "filter task by assignee");
    await page.keyboard.press("Enter");
    await page.fill("#paletteArgField", "all");
    await page.keyboard.press("Enter");
    await page.locator("#taskListBody").getByText(taskTitle).waitFor({ timeout: 5_000 });

    await page.locator('#roomList [data-room="2"]').click();

    await page.keyboard.press("Control+P");
    await page.fill("#paletteInput", "mark task done");
    await page.keyboard.press("Enter");
    await page.locator("#paletteResults").getByText(taskTitle).waitFor({ timeout: 5_000 });
    const moveLogStart = browserLogs.length;
    await page.keyboard.press("Enter");
    await waitForBrowserLogAfter(moveLogStart, /MOVED: .*DONE/);

    const deleteLogStart = browserLogs.length;
    await executePaletteCommand("Delete task", createdTaskId);
    await waitForBrowserLogAfter(deleteLogStart, new RegExp(`TASK #${createdTaskId} DELETED`));
    await page.waitForFunction(id => !NRCTasks.roomTasks.get(0n)?.has(BigInt(id)), createdTaskId);

    console.log("command palette E2E passed");
  } catch (err) {
    if (serverLogs.length > 0) {
      console.error("--- server logs ---");
      console.error(serverLogs.join(""));
    }
    if (browserLogs.length > 0) {
      console.error("--- browser logs ---");
      console.error(browserLogs.join("\n"));
    }
    throw err;
  } finally {
    if (browser) await browser.close().catch(() => {});
    if (staticServer) await new Promise((resolve) => staticServer.close(resolve));
    if (serverProcess && !serverProcess.killed) {
      shuttingDown = true;
      serverProcess.kill("SIGINT");
      await new Promise((resolve) => setTimeout(resolve, 500));
      if (!serverProcess.killed) serverProcess.kill("SIGKILL");
    }
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(err.message);
  if (err.cause) console.error(err.cause.message);
  process.exit(1);
});
