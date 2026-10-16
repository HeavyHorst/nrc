import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const cwd = dirname(fileURLToPath(import.meta.url));
const scratch = mkdtempSync(join(tmpdir(), "nrc-publish-browser-"));
const binary = join(scratch, "preview.test");
const publicURL = "http://127.0.0.1:18193";
const adminURL = "http://127.0.0.1:18194";
const artifacts = process.env.PUBLISH_SCREENSHOTS;
if (artifacts) mkdirSync(artifacts, { recursive: true });
let server, gateway, browser;
try {
  execFileSync("go", ["test", "-c", "-o", binary], { cwd, stdio: "inherit" });
  server = spawn(
    binary,
    ["-test.run", "^TestBrowserPreview$", "-test.timeout", "0"],
    {
      cwd,
      env: {
        ...process.env,
        TMPDIR: scratch,
        PUBLISH_BROWSER_PREVIEW: "1",
        PUBLISH_PREVIEW_JWT_SECRET: "fixture-signing-secret-not-production",
        PUBLISH_PREVIEW_ADDR: "127.0.0.1:18193",
        PUBLISH_PREVIEW_ADMIN_ADDR: "127.0.0.1:18194",
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  let logs = "";
  server.stdout.on("data", (data) => {
    logs += data;
  });
  server.stderr.on("data", (data) => {
    logs += data;
  });
  let ready = false;
  for (let i = 0; i < 100; i++) {
    try {
      if ((await fetch(`${publicURL}/health`)).ok) {
        ready = true;
        break;
      }
    } catch {}
    if (server.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert(ready, `Preview failed: ${logs}`);
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    deviceScaleFactor: 2,
  });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const shot = async (name) => {
    if (artifacts)
      await page.screenshot({
        path: resolve(artifacts, `${name}.png`),
        fullPage: true,
      });
  };
  const noOverflow = async (target = page) =>
    assert(
      await target.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
      "horizontal overflow",
    );

  await page.goto(publicURL);
  assert.equal(await page.locator(".category-card").count(), 4);
  assert.equal(await page.locator(".topic-number").count(), 4);
  assert.equal(await page.getByRole("heading", { name: "Alle Artikel", exact: true }).count(), 0);
  assert.equal(await page.title(), `Knowledge Base · ${process.env.PUBLISH_BRAND || "Dokumentation"}`);
  assert.equal(await page.getByRole("link", { name: "Thema entdecken", exact: true }).count(), 0);
  assert.equal(await page.locator(".home-brand img").count(), process.env.PUBLISH_LOGO_FILE ? 1 : 0);
  if (process.env.PUBLISH_LOGO_FILE) {
    assert(await page.locator(".home-brand img").evaluate(img => img.complete && img.naturalWidth > 0));
  }
  assert.equal(await page.locator("footer").count(), process.env.PUBLISH_FOOTER_TEXT || process.env.PUBLISH_IMPRINT_URL || process.env.PUBLISH_PRIVACY_URL || process.env.PUBLISH_TERMS_URL || process.env.PUBLISH_CONTACT_URL ? 1 : 0);
  for (const [name, variable] of [["Impressum", "PUBLISH_IMPRINT_URL"], ["Datenschutz", "PUBLISH_PRIVACY_URL"], ["Nutzungsbedingungen", "PUBLISH_TERMS_URL"], ["Kontakt", "PUBLISH_CONTACT_URL"]]) {
    if (process.env[variable]) {
      assert.equal(await page.getByRole("link", { name, exact: true }).getAttribute("href"), process.env[variable]);
    }
  }
  assert(
    await page
      .locator(".category-card a[href='/articles/api-schluessel']")
      .isVisible(),
  );
  await noOverflow();
  await shot("knowledge-home");
  await page.getByRole("searchbox").fill("Schlüssel");
  await page.getByRole("button", { name: "Suchen" }).click();
  await page.waitForURL("**/?q=*");
  assert.equal(await page.locator(".result").count(), 2);
  await shot("knowledge-search");
  await page.goto(`${publicURL}/?category=Erste%20Schritte`);
  assert.equal(await page.locator(".result").count(), 2);
  await page.goto(`${publicURL}/?q=NichtVorhandenXYZ`);
  assert.equal(
    await page.getByText("Keine passenden Artikel gefunden.").count(),
    1,
  );
  await shot("knowledge-empty-search");

  await page.goto(`${publicURL}/articles/dateien-verwalten`);
  const diagram = page.getByRole("img", { name: "Beispielabbildung" });
  assert(
    await diagram.evaluate(
      (image) => image.complete && image.naturalWidth === 320,
    ),
  );
  assert.match(
    await diagram.getAttribute("src"),
    /^\/media\/[0-9a-f]{32}\/att_diagram$/,
  );
  const downloadURL = await page
    .getByRole("link", { name: "Beispieldatei herunterladen" })
    .getAttribute("href");
  const download = await fetch(`${publicURL}${downloadURL}`);
  assert.equal(await download.text(), "Synthetische Beispieldatei\n");
  assert.match(download.headers.get("content-disposition"), /^attachment/);
  assert.deepEqual((await page.locator(".attachments a").allTextContents()).map(text => text.trim()), ["checkliste.txt ↓"]);
  await noOverflow();
  await shot("knowledge-attachments");
  await page.setViewportSize({ width: 390, height: 844 });
  await noOverflow();
  await shot("knowledge-attachments-narrow");
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(`${publicURL}/articles/verbindungsprobleme`);
  assert.equal(await page.locator(".attachments").count(), 0);
  assert.equal(await page.getByRole("img", { name: "Beispielabbildung" }).count(), 1);
  assert.equal(await page.getByRole("link", { name: "Beispieldatei herunterladen" }).count(), 1);
  await shot("knowledge-attachments-all-inline");

  await page.goto(`${publicURL}/articles/api-schluessel`);
  assert.equal(
    await page.locator(".desktop-nav [aria-current=page]").textContent(),
    "API-Schlüssel erstellen",
  );
  assert.equal(await page.locator(".toc nav a").count(), 4);
  assert.equal(await page.locator(".prose pre code").count(), 1);
  assert.equal(await page.locator(".related a").count(), 1);
  assert.equal(await page.locator(".related a").getAttribute("href"), "/?category=API%20%26%20Integrationen");
  assert.equal(await page.getByRole("heading", { name: "Weiter in diesem Thema" }).count(), 0);
  assert.equal(await page.locator('.prose a[href="/articles/api-referenz"]').count(), 1);
  const noteLink = page.locator('.prose a[href="/articles/by-note/2"]');
  assert.equal(await noteLink.textContent(), "Benutzer und Rechte verstehen");
  assert.equal(await page.locator(".prose code").filter({ hasText: "[note:999]" }).count(), 1);
  await noteLink.click();
  assert.equal(await page.locator("h1").textContent(), "Benutzer und Rechte verstehen");
  await page.goto(`${publicURL}/articles/api-schluessel`);
  await page.locator(".toc a").filter({ hasText: "Erster Request" }).click();
  assert.match(page.url(), /#erster-request$/);
  await page.goto(`${publicURL}/articles/api-schluessel`);
  await noOverflow();
  await shot("knowledge-article");

  await page.setViewportSize({ width: 1440, height: 480 });
  const nav = page.locator(".desktop-nav");
  assert(await nav.evaluate(el => el.scrollHeight > el.clientHeight), "long navigation must have its own scroll range");
  const articleTop = await page.locator("h1").evaluate(el => el.getBoundingClientRect().top);
  await shot("knowledge-sidebar-scroll-start");
  await nav.hover();
  await page.mouse.wheel(0, 2000);
  await page.waitForFunction(() => document.querySelector(".desktop-nav").scrollTop > 0);
  assert.equal(await page.evaluate(() => window.scrollY), 0, "sidebar wheel must not scroll article");
  assert.equal(await page.locator("h1").evaluate(el => el.getBoundingClientRect().top), articleTop);
  await shot("knowledge-sidebar-scroll-end");

  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.locator(".mobile-nav").getAttribute("open"), null);
  await noOverflow();
  assert(
    await page
      .locator(".prose pre")
      .evaluate((el) => el.scrollWidth <= el.clientWidth),
    "narrow code block clipped",
  );
  await shot("knowledge-article-narrow");
  await page.setViewportSize({ width: 390, height: 500 });
  await page.locator(".mobile-nav summary").click();
  assert.equal(await page.locator(".mobile-nav").getAttribute("open"), "");
  const mobileNav = page.locator(".mobile-nav nav");
  assert(await mobileNav.evaluate(el => el.scrollHeight > el.clientHeight), "expanded mobile navigation must scroll independently");
  await mobileNav.hover();
  const mobilePageScroll = await page.evaluate(() => window.scrollY);
  await page.mouse.wheel(0, 2000);
  await page.waitForFunction(() => document.querySelector(".mobile-nav nav").scrollTop > 0);
  assert.equal(await page.evaluate(() => window.scrollY), mobilePageScroll);
  await shot("knowledge-navigation-narrow");
  await page.locator(".mobile-nav summary").click();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator(".mobile-toc summary").click();
  assert.equal(await page.locator(".mobile-toc nav a").count(), 4);
  await page.goto(publicURL);
  await noOverflow();
  await shot("knowledge-home-narrow");

  // Exercise the real CLI against this private fixture, not a mocked HTTP client.
  const cli = join(scratch, "nrc");
  const gatewayBinary = join(scratch, "gateway.test");
  execFileSync("go", ["test", "-c", "-o", gatewayBinary], {
    cwd: resolve(cwd, "../../auth/tailscale-proxy"),
    stdio: "inherit",
  });
  gateway = spawn(
    gatewayBinary,
    ["-test.run", "^TestPublishGatewayPreview$", "-test.timeout", "0"],
    {
      env: {
        ...process.env,
        PUBLISH_GATEWAY_PREVIEW: "1",
        NRC_PUBLISH_BACKEND: adminURL,
        NRC_PUBLISH_WORKSPACE: "test-workspace",
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  gateway.stdout.on("data", (data) => {
    logs += data;
  });
  gateway.stderr.on("data", (data) => {
    logs += data;
  });
  let gatewayReady = false;
  for (let i = 0; i < 100; i++) {
    try {
      if ((await fetch("http://127.0.0.1:18195/health")).ok) {
        gatewayReady = true;
        break;
      }
    } catch {}
    if (gateway.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert(gatewayReady, `Gateway fixture failed: ${logs}`);
  execFileSync("go", ["build", "-o", cli, "./cmd/nrc"], {
    cwd: resolve(cwd, "../../../cli"),
    stdio: "inherit",
  });
  const publish = (...args) =>
    JSON.parse(
      execFileSync(cli, ["publish", ...args, "--json"], {
        env: {
          ...process.env,
          NRC_PUBLISH_URL: "http://127.0.0.1:18195",
        },
        encoding: "utf8",
      }),
    );
  assert.equal(publish("list").published.length, 7);
  const prepared = publish(
    "draft",
    "--note",
    "41",
    "--slug",
    "agent-cli",
    "--title",
    "Agent CLI",
    "--category",
    "Erste Schritte",
  );
  assert.equal(prepared.draft.created_by, "tag:amp");
  assert.equal(prepared.review_url, `${adminURL}/drafts/${prepared.draft.id}`);
  const inspected = publish("inspect", prepared.draft.id);
  assert.equal(inspected.draft.note_id, "41");
  assert.equal(inspected.stale, false);
  assert.equal((await fetch(`${publicURL}/articles/agent-cli`)).status, 404);

  // Exercise real browser form submission, auth, confirmation, publication and withdrawal.
  const adminContext = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    deviceScaleFactor: 2,
    httpCredentials: {
      username: "reviewer",
      password: "only-for-tests-not-a-secret",
    },
  });
  const admin = await adminContext.newPage();
  admin.on("pageerror", (error) => errors.push(error.message));
  const ordered = publish("order", "--category", "API & Integrationen", "6", "4", "5");
  assert.deepEqual(ordered.note_ids, ["6", "4", "5"]);
  await page.goto(`${publicURL}/?category=API%20%26%20Integrationen`);
  assert.deepEqual(await page.locator(".result h3").allTextContents(), ["Mit Webhooks auf Ereignisse reagieren", "API-Schlüssel erstellen", "API-Referenz"]);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await shot("knowledge-ordered-topic");
  await admin.goto(`${adminURL}/order`);
  assert.equal(await admin.getByRole("spinbutton", { name: "Position: Mit Webhooks auf Ereignisse reagieren", exact: true }).inputValue(), "1");
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "knowledge-order-editor.png"), fullPage: true });
  await admin.setViewportSize({ width: 390, height: 844 });
  await noOverflow(admin);
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "knowledge-order-editor-narrow.png"), fullPage: true });
  await admin.setViewportSize({ width: 1440, height: 1000 });
  await admin.getByRole("spinbutton", { name: "Position: API-Schlüssel erstellen", exact: true }).fill("1");
  await admin.getByRole("spinbutton", { name: "Position: Mit Webhooks auf Ereignisse reagieren", exact: true }).fill("2");
  await admin.locator('form[action="/order"]').filter({ has: admin.locator('input[name="category"][value="API & Integrationen"]') }).getByRole("button", { name: "Reihenfolge speichern" }).click();
  await admin.waitForURL(`${adminURL}/order`);
  assert.deepEqual(publish("list").published.filter(article => article.category === "API & Integrationen").map(article => article.note_id), ["4", "6", "5"]);
  publish("subtopic", "--category", "API & Integrationen", "--name", "Authentifizierung", "4", "5");
  publish("subtopic", "--category", "API & Integrationen", "--name", "Ereignisse", "6");
  assert.equal(publish("list").published.find(article => article.note_id === "4").subtopic, "Authentifizierung");
  await page.goto(`${publicURL}/?category=API%20%26%20Integrationen`);
  assert.deepEqual(await page.locator(".subtopic-heading").allTextContents(), ["Authentifizierung", "Ereignisse"]);
  assert.deepEqual(await page.locator(".subtopic-number").allTextContents(), ["01", "02"]);
  assert.deepEqual(await page.locator(".subtopic-header p").allTextContents(), ["2 Artikel", "1 Artikel"]);
  assert.deepEqual(await page.locator(".subtopic-links a").allTextContents(), ["01 Authentifizierung", "02 Ereignisse"]);
  assert.equal(await page.locator(".result .small").count(), 0);
  assert.equal(await page.locator(".article-results .pill").count(), 0);
  assert.deepEqual(await page.locator(".result h3").allTextContents(), ["API-Schlüssel erstellen", "API-Referenz", "Mit Webhooks auf Ereignisse reagieren"]);
  await shot("subtopics-topic-desktop");
  await page.locator('.subtopic-links a[href="#subtopic-2"]').click();
  await page.waitForFunction(() => location.hash === "#subtopic-2" && scrollY > 0);
  await page.goto(`${publicURL}/?category=API%20%26%20Integrationen`);
  await page.setViewportSize({ width: 390, height: 844 });
  await noOverflow();
  await shot("subtopics-topic-mobile");
  await page.locator('.subtopic-links a[href="#subtopic-2"]').click();
  await page.waitForFunction(() => location.hash === "#subtopic-2" && scrollY > 0);
  await page.goto(`${publicURL}/?category=API%20%26%20Integrationen&q=API`);
  assert.equal(await page.locator(".subtopic-links").count(), 0);
  assert(await page.locator(".result .small").count() > 0);
  await page.goto(`${publicURL}/articles/api-schluessel`);
  await page.locator(".mobile-nav > summary").click();
  assert.equal(await page.locator(".mobile-nav .subtopic[open]").count(), 1);
  await shot("subtopics-article-mobile");
  await page.setViewportSize({ width: 1440, height: 1000 });
  assert.equal(await page.locator(".desktop-nav .subtopic[open]").count(), 1);
  await page.locator(".desktop-nav .subtopic summary").filter({ hasText: "Ereignisse" }).click();
  assert(await page.locator('.desktop-nav a[href="/articles/webhooks"]').isVisible());
  await shot("subtopics-article-desktop");
  await admin.goto(`${adminURL}/order`);
  await admin.getByRole("textbox", { name: "Unterthema: Mit Webhooks auf Ereignisse reagieren", exact: true }).fill("Authentifizierung");
  await admin.locator('form[action="/subtopics"]').filter({ has: admin.locator('input[name="category"][value="API & Integrationen"]') }).getByRole("button", { name: "Unterthemen speichern" }).click();
  await admin.waitForURL(`${adminURL}/order`);
  assert.equal(publish("list").published.find(article => article.note_id === "6").subtopic, "Authentifizierung");
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "subtopics-editor-desktop.png"), fullPage: true });
  await admin.setViewportSize({ width: 390, height: 844 });
  await noOverflow(admin);
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "subtopics-editor-mobile.png"), fullPage: true });
  await admin.setViewportSize({ width: 1440, height: 1000 });
  await admin.goto(adminURL);
  assert.equal(await admin.locator("a.result").count(), 2);
  const draftLabels = await admin.locator("a.result .pill").allTextContents();
  assert.deepEqual(draftLabels.map(label => label.trim()).sort(), ["Neuer Artikel", "Update"]);
  await noOverflow(admin);
  if (artifacts) {
    await admin.screenshot({ path: resolve(artifacts, "publish-dashboard.png"), fullPage: true });
  }
  await admin
    .locator("a.result")
    .filter({
      has: admin.getByRole("heading", { name: "API-Schlüssel erstellen" }),
    })
    .click();
  assert.equal(await admin.locator(".comparison .review-card").count(), 2);
  assert.equal(await admin.locator('.comparison .prose a[href="/articles/by-note/2"]').count(), 2);
  const reviewURL = admin.url();
  await admin.locator('.comparison .prose a[href="/articles/by-note/2"]').last().click();
  assert.equal(admin.url(), `${adminURL}/articles/benutzer-rechte`);
  assert.equal(await admin.locator("h1").textContent(), "Benutzer und Rechte verstehen");
  await admin.goBack();
  assert.equal(admin.url(), reviewURL);
  assert.equal(await admin.getByRole("checkbox").isChecked(), false);
  assert.equal(
    await admin.getByRole("heading", { name: "Schlüssel widerrufen" }).count(),
    1,
  );
  if (artifacts)
    await admin.screenshot({
      path: resolve(artifacts, "knowledge-update-review.png"),
      fullPage: true,
    });
  await noOverflow(admin);
  await admin.setViewportSize({ width: 390, height: 844 });
  await noOverflow(admin);
  assert(
    await admin
      .getByRole("button", { name: /Diesen Stand öffentlich/ })
      .isVisible(),
  );
  await admin.evaluate(() => window.scrollTo(0, 0));
  if (artifacts)
    await admin.screenshot({
      path: resolve(artifacts, "knowledge-update-review-narrow.png"),
      fullPage: true,
    });
  await admin.setViewportSize({ width: 1440, height: 1000 });
  assert(
    !(
      await (await fetch(`${publicURL}/articles/api-schluessel`)).text()
    ).includes("Schlüssel widerrufen"),
    "pending update leaked",
  );
  await admin.goto(`${adminURL}/notes`);
  await admin
    .getByRole("link", { name: /Integration fixture|Interner Titel/ })
    .first()
    .click();
  assert.equal(await admin.locator("input[name=source]").inputValue(), "41");
  await admin.locator("input[name=title]").fill("Browser-Freigabe");
  await admin.locator("input[name=slug]").fill("browser-freigabe");
  await admin.locator("input[name=category]").fill("Erste Schritte");
  await admin
    .getByRole("button", { name: /Entwurf aus aktuellem Notizstand/ })
    .click();
  await admin.waitForURL("**/drafts/*");
  assert.equal(
    (await fetch(`${publicURL}/articles/browser-freigabe`)).status,
    404,
  );
  if (artifacts)
    await admin.screenshot({
      path: resolve(artifacts, "knowledge-review.png"),
      fullPage: true,
    });
  await admin.getByRole("checkbox").check();
  await admin.getByRole("button", { name: /Diesen Stand öffentlich/ }).click();
  await admin.waitForURL(`${adminURL}/`);
  await page.goto(`${publicURL}/articles/browser-freigabe`);
  assert.equal(
    await page
      .getByRole("heading", { name: "Browser-Freigabe", exact: true })
      .count(),
    1,
  );
  const row = admin
    .locator(".result")
    .filter({ has: admin.getByRole("heading", { name: "Browser-Freigabe" }) });
  await row.locator("summary").click();
  await row.getByRole("button", { name: "Jetzt zurückziehen" }).click();
  await admin.waitForURL(`${adminURL}/`);
  assert.equal(
    (await fetch(`${publicURL}/articles/browser-freigabe`)).status,
    404,
  );
  const olderAlpha = publish("draft", "--note", "5348", "--slug", "alte-alpha-url", "--title", "Alte Alpha-Variante", "--category", "Verlinkungen");
  const alpha = publish("draft", "--note", "5348", "--slug", "kreis-alpha", "--title", "Kreis Alpha", "--category", "Verlinkungen");
  const beta = publish("draft", "--note", "5349", "--slug", "kreis-beta", "--title", "Kreis Beta", "--category", "Verlinkungen");
  await admin.goto(`${adminURL}/drafts/${alpha.draft.id}`);
  assert(await admin.getByText("Linkziele fehlen:", { exact: true }).isVisible());
  assert(await admin.getByRole("button", { name: /Diesen Stand öffentlich/ }).isDisabled());
  assert(await admin.getByText("[note:5349] (Linkziel fehlt)", { exact: true }).isVisible());
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "publish-missing-target.png"), fullPage: true });
  await admin.setViewportSize({ width: 390, height: 844 });
  await noOverflow(admin);
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "publish-missing-target-narrow.png"), fullPage: true });
  await admin.setViewportSize({ width: 1440, height: 1000 });
  await admin.goto(adminURL);
  assert.equal(await admin.locator(`a[href="/drafts/${olderAlpha.draft.id}"]`).count(), 0);
  await admin.locator(`input[name=draft][value="${alpha.draft.id}"]`).check();
  await admin.locator(`input[name=draft][value="${beta.draft.id}"]`).check();
  await admin.evaluate(() => window.scrollTo(0, 0));
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "publish-group-selection.png"), fullPage: true });
  await admin.setViewportSize({ width: 390, height: 844 });
  await noOverflow(admin);
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "publish-group-selection-narrow.png"), fullPage: true });
  await admin.setViewportSize({ width: 1440, height: 1000 });
  await admin.getByRole("button", { name: "Auswahl gemeinsam prüfen →" }).click();
  await admin.waitForURL("**/reviews/*");
  assert.equal(await admin.locator(".comparison").count(), 2);
  assert.equal(await admin.locator('.comparison .prose a[href="/articles/by-note/5349"]').textContent(), "Kreis Beta");
  assert.equal(await admin.locator('.comparison .prose a[href="/articles/by-note/5348"]').textContent(), "Kreis Alpha");
  assert.equal((await fetch(`${publicURL}/articles/kreis-alpha`)).status, 404);
  assert.equal((await fetch(`${publicURL}/articles/kreis-beta`)).status, 404);
  await noOverflow(admin);
  await admin.evaluate(() => window.scrollTo(0, 0));
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "publish-group-review.png"), fullPage: true });
  await admin.setViewportSize({ width: 390, height: 844 });
  await noOverflow(admin);
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "publish-group-review-narrow.png"), fullPage: true });
  await admin.getByRole("checkbox").check();
  await admin.getByRole("button", { name: "Alle 2 Artikel gemeinsam veröffentlichen →" }).click();
  await admin.waitForURL(`${adminURL}/`);
  await page.goto(`${publicURL}/articles/kreis-alpha`);
  await page.locator('.prose a[href="/articles/by-note/5349"]').click();
  await page.waitForURL(`${publicURL}/articles/kreis-beta`);
  await page.locator('.prose a[href="/articles/by-note/5348"]').click();
  await page.waitForURL(`${publicURL}/articles/kreis-alpha`);
  const movedBeta = publish("draft", "--note", "5349", "--slug", "kreis-beta-neu", "--title", "Kreis Beta – aktualisiert", "--category", "Verlinkungen");
  await admin.goto(`${adminURL}/drafts/${movedBeta.draft.id}`);
  assert.equal(await admin.locator(".pill").textContent(), "Update");
  await admin.setViewportSize({ width: 1440, height: 1000 });
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "publish-url-update.png"), fullPage: true });
  await admin.setViewportSize({ width: 390, height: 844 });
  await noOverflow(admin);
  if (artifacts) await admin.screenshot({ path: resolve(artifacts, "publish-url-update-narrow.png"), fullPage: true });
  await admin.getByRole("checkbox").check();
  await admin.getByRole("button", { name: /Diesen Stand öffentlich/ }).click();
  await admin.waitForURL(`${adminURL}/`);
  assert.equal(publish("list").published.filter(article => article.note_id === "5349").length, 1);
  await page.goto(`${publicURL}/articles/kreis-alpha`);
  await page.locator('.prose a[href="/articles/by-note/5349"]').click();
  await page.waitForURL(`${publicURL}/articles/kreis-beta-neu`);
  await page.goto(`${publicURL}/articles/kreis-beta`);
  await page.waitForURL(`${publicURL}/articles/kreis-beta-neu`);
  assert.deepEqual(errors, []);
  console.log(
    "PASS: real CLI → gateway → signed workspace assertion → private draft/inspect; human approval boundary; browser navigation, publication and atomic cyclic-link group workflow.",
  );
} finally {
  if (browser) await browser.close();
  if (gateway && gateway.exitCode === null) {
    const exited = new Promise((resolve) => gateway.once("exit", resolve));
    gateway.kill("SIGTERM");
    await exited;
  }
  if (server && server.exitCode === null) {
    const exited = new Promise((resolve) => server.once("exit", resolve));
    server.kill("SIGTERM");
    await exited;
  }
  rmSync(scratch, { recursive: true, force: true });
}
