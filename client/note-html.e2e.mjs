// node client/note-html.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ serviceWorkers: "block" });
const errors = [];
page.on("pageerror", error => errors.push(error.message));

try {
  const externalRequests = [];
  await page.context().route(/^https?:\/\/outside\.example\//, route => {
    externalRequests.push({ url: route.request().url(), referer: route.request().headers().referer });
    return route.fulfill({ contentType: "text/html", body: "External page" });
  });
  await page.route("http://nrc.test/**", async route => {
    if (new URL(route.request().url()).pathname === "/note-html.js") {
      return route.fulfill({ path: fileURLToPath(new URL("./note-html.js", import.meta.url)) });
    }
    await route.fulfill({ contentType: "text/html", body: '<script src="/note-html.js"></script>' });
  });
  await page.goto("http://nrc.test/workspace");
  await page.evaluate(() => {
    window.payload = `<base href="https://outside.example/">
      <img name="addEventListener" alt=""><img name="getElementById" alt="">
      <a id="jump" href="#fields" target="_top" ping="https://outside.example/ping" download><span>Fields</span></a>
      <a id="encoded" href="#Gr%C3%B6%C3%9Fe">Encoded ID</a>
      <a href="#missing">Missing</a><a href="#">Empty</a><a href="#%ZZ">Malformed</a>
      <a id="https" tabindex="0" href="https://outside.example/path?q=nrc#section" target="_top" ping="https://outside.example/ping" download><span>HTTPS</span></a>
      <a id="http" href="http://outside.example/plain">HTTP</a><a href="//outside.example/">Protocol relative</a>
      <a href="/workspace#fields">Relative</a><a href="javascript:alert(1)">Script URL</a>
      <a href="data:text/html,test">Data URL</a><a href="mailto:test@example.com">Mail</a>
      <a href="java&#x09;script:alert(1)">Obfuscated script</a><a href="https://">Invalid web URL</a>
      <a data-nrc-note-href="javascript:alert(1)">Forged script link</a>
      <a data-nrc-note-href="https://outside.example/forged">Forged web link</a>
      <svg><a href="#fields" xlink:href="#fields">SVG</a><set attributeName="href" to="https://outside.example/"/></svg>
      <script id="removed">parent.__executed = true;</script><a href="#removed">Removed target</a>
      <div style="height:1500px"></div><h2 id="fields" onclick="parent.__executed = true">Fields target</h2>
      <div style="height:800px"></div><h2 id="Größe">Encoded target</h2><div style="height:800px"></div>`;
    const frame = NRCHTMLNotes.createFrame(payload);
    frame.style.cssText = "width:100%;height:300px";
    document.body.append(frame);
  });
  const frame = page.frameLocator("iframe");
  await frame.locator("#fields").waitFor({ state: "attached" });
  assert.equal(await page.locator("iframe").getAttribute("sandbox"), "allow-same-origin");
  assert.deepEqual(await frame.locator("[href]").evaluateAll(nodes => nodes.map(n => n.getAttribute("href"))),
    ["#fields", "#Gr%C3%B6%C3%9Fe", "https://outside.example/path?q=nrc#section", "http://outside.example/plain"]);
  assert.equal(await frame.locator("[target], [ping], [download], [onclick], base, script, svg set, svg [*|href]").count(), 0, "navigation modifiers, executable content and SVG links are removed");

  for (const [width, height] of [[1440, 900], [390, 844]]) {
    await page.setViewportSize({ width, height });
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => {
        window.previousNoteDocument = document.querySelector("iframe").contentDocument;
        document.documentElement.style.colorScheme = theme;
        document.dispatchEvent(new Event("nrc:theme-changed"));
      }, theme);
      await page.waitForFunction(() => {
        const doc = document.querySelector("iframe").contentDocument;
        return doc !== previousNoteDocument && doc.readyState === "complete" && doc.querySelector("#jump[href]");
      });
      await frame.locator("#jump").waitFor({ state: "visible" });
      await frame.locator("#jump span").click();
      await page.waitForFunction(() => Math.abs(document.querySelector("iframe").contentDocument.querySelector("#fields").getBoundingClientRect().top) < 2);
      assert.equal(page.url(), "http://nrc.test/workspace");
      assert.equal(await page.locator("iframe").evaluate(el => el.contentWindow.location.href), "about:srcdoc");
      await frame.locator("#encoded").focus();
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => Math.abs(document.querySelector("iframe").contentDocument.querySelector("#Größe").getBoundingClientRect().top) < 2);
    }
  }
  await page.evaluate(() => {
    window.previousNoteDocument = document.querySelector("iframe").contentDocument;
    NRCHTMLNotes.updateFrame(document.querySelector("iframe"), payload);
  });
  await page.waitForFunction(() => {
    const doc = document.querySelector("iframe").contentDocument;
    return doc !== previousNoteDocument && doc.readyState === "complete" && doc.querySelector("#jump[href]");
  });
  await frame.locator("#jump").waitFor({ state: "visible" });
  await frame.locator("#jump").click({ button: "middle" });
  assert.equal(await page.locator("iframe").evaluate(el => el.contentWindow.location.href), "about:srcdoc");
  await frame.locator("#jump").click();
  await page.waitForFunction(() => Math.abs(document.querySelector("iframe").contentDocument.querySelector("#fields").getBoundingClientRect().top) < 2);
  assert.equal(await page.evaluate(() => window.__executed), undefined);
  assert.equal(browser.contexts()[0].pages().length, 1, "no popup opened");
  assert.deepEqual(externalRequests, [], "rendering and local jumps make no external requests");

  for (const [id, activation, url] of [
    ["https", "click", "https://outside.example/path?q=nrc#section"],
    ["http", "keyboard", "http://outside.example/plain"],
    ["https", "middle", "https://outside.example/path?q=nrc#section"],
  ]) {
    const opened = page.context().waitForEvent("page");
    if (activation === "keyboard") {
      await frame.locator(`#${id}`).focus();
      await page.keyboard.press("Enter");
    } else {
      await frame.locator(`#${id} span`).click({ button: activation === "middle" ? "middle" : "left" });
    }
    const tab = await opened;
    await tab.waitForLoadState();
    assert.equal(tab.url(), url);
    assert.equal(await tab.evaluate(() => window.opener), null);
    assert.equal(await tab.evaluate(() => document.referrer), "");
    assert.equal(externalRequests.at(-1).referer, undefined);
    assert.equal(page.url(), "http://nrc.test/workspace");
    assert.equal(await page.locator("iframe").evaluate(el => el.contentWindow.location.href), "about:srcdoc");
    await tab.close();
  }
  assert.equal(externalRequests.length, 3, "only explicit web-link activations request external pages");

  // Hold load delivery before the production listener. This deterministically
  // widens the pre-handler window (also present during slow resource loads),
  // without timing-dependent blob decoding or changing the note's CSP.
  for (const operation of ["create", "update", "theme"]) {
    await page.evaluate(operation => {
      let frame = document.querySelector("iframe");
      window.previousNoteDocument = frame.contentDocument;
      window.noteLoadHeld = false;
      window.holdNoteLoad = event => {
        event.stopImmediatePropagation();
        window.noteLoadHeld = true;
      };
      if (operation === "create") {
        frame.remove();
        frame = NRCHTMLNotes.createFrame(payload);
        frame.style.cssText = "width:100%;height:300px";
        frame.addEventListener("load", holdNoteLoad, { capture: true });
        document.body.append(frame);
      } else {
        frame.addEventListener("load", holdNoteLoad, { capture: true });
        if (operation === "update") NRCHTMLNotes.updateFrame(frame, payload);
        else document.dispatchEvent(new Event("nrc:theme-changed"));
      }
    }, operation);
    await page.waitForFunction(() => noteLoadHeld && document.querySelector("iframe").contentDocument !== previousNoteDocument);
    assert.equal(await frame.locator("[href]").count(), 0, "no native navigation before handlers exist");
    assert.deepEqual(await frame.locator("[data-nrc-note-href]").evaluateAll(nodes => nodes.map(n => n.getAttribute("data-nrc-note-href"))),
      ["#fields", "#Gr%C3%B6%C3%9Fe", "https://outside.example/path?q=nrc#section", "http://outside.example/plain"], "authored internal attributes cannot bypass validation");
    const requestsBefore = externalRequests.length;
    await frame.locator("#jump span").click();
    await frame.locator("#https span").click();
    await frame.locator("#https span").click({ button: "middle" });
    await frame.locator("#https").focus();
    await page.keyboard.press("Enter");
    assert.equal(page.context().pages().length, 1);
    assert.equal(externalRequests.length, requestsBefore);
    assert.equal(page.url(), "http://nrc.test/workspace");
    assert.equal(await page.locator("iframe").evaluate(el => el.contentWindow.location.href), "about:srcdoc");
    await page.evaluate(() => {
      const frame = document.querySelector("iframe");
      frame.removeEventListener("load", holdNoteLoad, { capture: true });
      frame.dispatchEvent(new Event("load"));
    });
    assert.equal(await frame.locator("[data-nrc-note-href]").count(), 0);
    assert.equal(await frame.locator("a[href]").count(), 4);
    await frame.locator("#jump span").click();
    await page.waitForFunction(() => Math.abs(document.querySelector("iframe").contentDocument.querySelector("#fields").getBoundingClientRect().top) < 2);
    const opened = page.context().waitForEvent("page");
    await frame.locator("#https span").click();
    const tab = await opened;
    await tab.waitForLoadState();
    assert.equal(tab.url(), "https://outside.example/path?q=nrc#section");
    assert.equal(await tab.evaluate(() => window.opener), null);
    assert.equal(await tab.evaluate(() => document.referrer), "");
    assert.equal(externalRequests.length, requestsBefore + 1, "one activation opens exactly one tab after load");
    assert.equal(externalRequests.at(-1).referer, undefined);
    assert.equal(page.url(), "http://nrc.test/workspace");
    assert.equal(await page.locator("iframe").evaluate(el => el.contentWindow.location.href), "about:srcdoc");
    await tab.close();
  }
  assert.deepEqual(errors, []);
  console.log("HTML note links: sanitizer, fragments, isolated HTTP(S) tabs, mouse, keyboard, themes, mobile, updates and sandbox passed");
} finally {
  await browser.close();
}
