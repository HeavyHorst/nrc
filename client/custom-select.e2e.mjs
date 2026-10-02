// Native select contracts and real custom-element/portal lifecycle.
// node client/custom-select.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.addInitScript(() => {
    window.documentClicks = new Set();
    const add = document.addEventListener.bind(document), remove = document.removeEventListener.bind(document);
    document.addEventListener = (type, listener, options) => {
      if (type === "click") documentClicks.add(listener);
      add(type, listener, options);
    };
    document.removeEventListener = (type, listener, options) => {
      if (type === "click") documentClicks.delete(listener);
      remove(type, listener, options);
    };
  });
  await page.route("http://nrc.test/**", async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/") return route.fulfill({ contentType: "text/html", body: `<!doctype html>
      <meta charset="utf-8">
      <link rel="stylesheet" href="/css/main.css"><link rel="stylesheet" href="/css/custom-select.css">
      <script src="/portal.js"></script><script src="/custom-picker.js"></script><script src="/custom-select.js"></script>
      <form id="editor"><div class="header-filter-cell"><label for="native">STATE</label>
        <nrc-select id="host"><select id="native" name="state" tabindex="3" data-custom-select-portal>
          <option value="draft" selected>Draft</option><option value="review">Review</option><option value="done">Done</option>
        </select></nrc-select></div>
        <label>COMPATIBLE<select id="compat" name="legacy" data-custom-select><option>Legacy</option></select></label>
        <button type="reset" id="resetButton">RESET</button>
      </form><form id="other"><button type="reset" id="otherReset">OTHER RESET</button></form><button id="outside">OUTSIDE</button>` });
    await route.fulfill({ path: fileURLToPath(new URL(`.${path}`, import.meta.url)) });
  });
  await page.goto("http://nrc.test/");
  assert.equal(await page.locator("nrc-select .custom-select__trigger").count(), 2, "parser-connected and compatibility selects mount once");
  assert.equal(await page.locator("nrc-select nrc-select").count(), 0, "host replaces wrapper without nesting");
  const baseline = await page.evaluate(() => documentClicks.size - CustomSelect.instances.size);
  await page.evaluate(() => {
    window.changes = [];
    editor.addEventListener("change", event => changes.push([event.target.id, event.target.value]));
    native.value = "review";
  });
  assert.equal(await page.locator("#host .custom-select__value").textContent(), "Review");
  assert.equal(await page.evaluate(() => new FormData(editor).get("state")), "review");
  assert.deepEqual(await page.evaluate(() => changes), [], "assigning a native value does not synthesize change");
  await page.evaluate(() => { native.selectedIndex = 2; });
  assert.equal(await page.locator("#host .custom-select__value").textContent(), "Done");
  await page.evaluate(() => { native.options[2].firstChild.data = "Completed"; });
  await page.waitForFunction(() => document.querySelector("#host .custom-select__value").textContent === "Completed");
  await page.evaluate(() => { native.options[2].label = "Shipped"; });
  await page.waitForFunction(() => document.querySelector("#host .custom-select__value").textContent === "Shipped");
  await page.evaluate(() => native.options[2].removeAttribute("label"));
  await page.evaluate(() => { editor.reset(); });
  await page.waitForFunction(() => document.querySelector("#host .custom-select__value").textContent === "Draft");
  assert.equal(await page.evaluate(() => native.value), "draft");

  await page.evaluate(() => { native.value = "done"; });
  await page.locator("#resetButton").click();
  assert.equal(await page.evaluate(() => native.value), "draft");
  await page.waitForFunction(() => document.querySelector("#host .custom-select__value").textContent === "Draft");
  await page.evaluate(() => {
    native.value = "review";
    editor.addEventListener("reset", event => event.preventDefault(), { once: true });
  });
  await page.locator("#resetButton").click();
  await page.evaluate(() => new Promise(resolve => setTimeout(resolve, 20)));
  assert.equal(await page.evaluate(() => native.value), "review");
  assert.equal(await page.locator("#host .custom-select__value").textContent(), "Review");
  await page.evaluate(() => native.setAttribute("form", "other"));
  await page.locator("#otherReset").click();
  assert.equal(await page.evaluate(() => native.value), "draft");
  await page.waitForFunction(() => document.querySelector("#host .custom-select__value").textContent === "Draft");
  await page.evaluate(() => native.removeAttribute("form"));
  assert.deepEqual(await page.evaluate(() => changes), [], "resets do not synthesize change");

  await page.getByRole("button", { name: /^STATE Draft/ }).click();
  await page.locator(".portal-wrapper input").fill("review");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  assert.deepEqual(await page.evaluate(() => changes), [["native", "review"]], "one bubbling native change per selection");
  assert.equal(await page.locator("#host button").getAttribute("aria-expanded"), "false");

  await page.locator("#host button").click();
  await page.evaluate(() => { native.disabled = true; });
  assert.equal(await page.locator("#host button").isDisabled(), true);
  assert.equal(await page.locator("#host button").getAttribute("aria-expanded"), "false");
  assert.equal(await page.evaluate(() => new FormData(editor).has("state")), false);
  await page.evaluate(() => native.removeAttribute("disabled"));
  await page.waitForFunction(() => !document.querySelector("#host button").disabled);

  // Removing a portaled control immediately restores native state and releases
  // global listeners. Reconnection uses current options and does not multiply handlers.
  for (let i = 0; i < 3; i++) {
    await page.locator("#host button").click();
    const detached = await page.evaluate(() => {
      window.savedHost = host;
      window.savedNative = native;
      savedHost.remove();
      return { instances: CustomSelect.instances.size, pickers: CustomPicker.instances.size,
        clicks: documentClicks.size, tabindex: savedNative.getAttribute("tabindex"),
        valueOverridden: Object.hasOwn(savedNative, "value"), labelFor: editor.querySelector("label").htmlFor };
    });
    assert.deepEqual(detached, { instances: 1, pickers: 1, clicks: baseline + 1, tabindex: "3", valueOverridden: false, labelFor: "native" });
    assert.equal(await page.locator(".portal-wrapper").count(), 0);
    await page.evaluate(() => {
      savedNative.value = "done";
      editor.firstElementChild.append(savedHost);
    });
    assert.equal(await page.locator("#host .custom-select__value").textContent(), "Completed");
    assert.equal(await page.evaluate(() => documentClicks.size), baseline + 2);
    assert.equal(await page.locator("#host button").count(), 1);
  }

  // Replace only the native child and then move it to a different live host.
  await page.evaluate(() => {
    window.previous = native;
    const replacement = document.createElement("select");
    replacement.id = "native"; replacement.name = "state";
    replacement.innerHTML = '<option value="replacement">Replacement</option>';
    previous.replaceWith(replacement);
  });
  await page.waitForFunction(() => document.querySelector("#host .custom-select__value").textContent === "Replacement");
  assert.equal(await page.evaluate(() => CustomSelect.instances.has(previous)), false);
  await page.evaluate(() => {
    const destination = document.createElement("nrc-select");
    destination.id = "destination";
    editor.append(destination);
    destination.append(native);
  });
  await page.waitForFunction(() => document.querySelector("#destination .custom-select__value")?.textContent === "Replacement");
  assert.equal(await page.locator("#host button").count(), 0);
  assert.equal(await page.evaluate(() => CustomSelect.instances.size), 2);
  assert.equal(await page.evaluate(() => documentClicks.size), baseline + 2);

  await page.evaluate(() => {
    native.value = "replacement";
    native.dispatchEvent(new Event("change", { bubbles: true }));
    editor.replaceChildren();
  });
  assert.equal(await page.evaluate(() => changes.length), 2, "reconnection does not duplicate native change listeners");
  assert.equal(await page.evaluate(() => CustomSelect.instances.size + CustomPicker.instances.size), 0);
  assert.equal(await page.evaluate(() => documentClicks.size), baseline);
  assert.deepEqual(errors, []);
  console.log("PASS: native values/FormData/change/reset/disabled/options, parser and dynamic mount, label/tabindex restoration, reconnect/replace/move, portal and global-listener cleanup");
} finally { await browser.close(); }
