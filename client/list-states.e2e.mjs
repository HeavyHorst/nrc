// Shared list states against production CSS and catalogue markup.
// node client/list-states.e2e.mjs
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ serviceWorkers: "block" });
const families = [
  [".task-table tbody tr", "task-row-selected"],
  [".note-card", "note-selected"],
  [".reminder-row", "reminder-row-selected"],
  [".customer-row", "aria-pressed"],
  [".customer-contact", "aria-pressed"],
  [".customer-event", null],
  [".system-log-table tbody tr", "system-log-row-selected"],
  [".slice-row", "aria-pressed"],
  [".slice-member", "slice-member-selected"],
  [".attention-row", null],
];
const style = row => row.evaluate(el => {
  const css = getComputedStyle(el);
  return { background: css.backgroundColor, shadow: css.boxShadow, outline: css.outlineWidth, outlineStyle: css.outlineStyle, outlineColor: css.outlineColor, outlineOffset: css.outlineOffset };
});
const assertOutline = async (row, color, message) => {
  const css = await style(row);
  assert.deepEqual([css.outline, css.outlineStyle, css.outlineColor, css.outlineOffset], ["1px", "solid", color, "-1px"], message);
};
try {
  await page.route("http://nrc.test/**", async route => {
    try {
      await route.fulfill({ path: fileURLToPath(new URL(`.${new URL(route.request().url()).pathname}`, import.meta.url)) });
    } catch { await route.fulfill({ status: 404, body: "Not found" }); }
  });
  await page.goto("http://nrc.test/design-system/index.html");
  await page.evaluate(() => {
    const table = document.createElement("table");
    table.className = "system-log-table";
    table.innerHTML = "<tbody><tr tabindex='0'><td>12:04</td><td>NOTE UPDATED</td></tr></tbody>";
    document.querySelector("#data").append(table);
    const layout = document.querySelector(".catalog-slice-layout");
    const view = document.createElement("div");
    view.className = "slice-view";
    layout.before(view);
    view.append(layout);
  });
  await fs.mkdir(".amp/in/artifacts", { recursive: true });
  for (const theme of ["light", "dark", "lupine"]) {
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
      const tokens = await page.evaluate(() => {
        const probe = document.createElement("div");
        document.body.append(probe);
        const resolve = name => {
          probe.style.backgroundColor = `var(${name})`;
          return getComputedStyle(probe).backgroundColor;
        };
        const result = { hover: resolve("--bg-hover"), selected: resolve("--selected-row-bg"), accent: resolve("--selected-row-accent"), focus: resolve("--focus-interactive") };
        probe.remove();
        return result;
      });
      for (const [selector, selection] of families) {
        await page.locator(".slice-view").evaluateAll((views, detail) => {
          for (const view of views) view.dataset.sliceMobileDetail = String(detail);
        }, selector === ".slice-member");
        const row = page.locator(selector).first();
        const select = enabled => row.evaluate((el, { selection, enabled }) => {
          if (selection === "aria-pressed") el.setAttribute(selection, String(enabled));
          else if (selection) el.classList.toggle(selection, enabled);
        }, { selection, enabled });
        await select(false);
        await page.mouse.move(0, 0);
        assert.equal((await style(row)).outlineStyle, "none", `${selector}: idle row has no outline`);
        await row.hover();
        assert.equal((await style(row)).background, tokens.hover, `${selector}: hover (${theme}/${width})`);
        await assertOutline(row, tokens.focus, `${selector}: pointer hover outlines the whole row`);
        if (selection) {
          await select(true);
          const selected = await style(row);
          assert.equal(selected.background, tokens.selected, `${selector}: selection wins over hover`);
          assert.equal(selected.shadow, `${tokens.accent} 3px 0px 0px 0px inset`, `${selector}: shared selection bar`);
          await page.mouse.move(0, 0);
          assert.equal((await style(row)).background, tokens.selected, `${selector}: selection without hover`);
          await assertOutline(row, tokens.focus, `${selector}: selection stays outlined without hover or focus`);
          await select(false);
        }
        // Keyboard modality, including child openers on reminder rows.
        await page.keyboard.press("Tab");
        const opener = row.locator(".task-row-open, .slice-member-open");
        if (await opener.count()) await opener.first().focus();
        else {
          await row.evaluate(el => { el.tabIndex = 0; });
          await row.focus();
        }
        assert.deepEqual(await row.evaluate(el => ({ width: getComputedStyle(el).outlineWidth, style: getComputedStyle(el).outlineStyle })), { width: "1px", style: "solid" }, `${selector}: whole-row keyboard focus`);
        if (selector === ".customer-row") {
          await page.locator(".catalog-customer-register").screenshot({ path: `.amp/in/artifacts/list-focus-${theme}-${width}.png` });
        }
        await row.evaluate(el => { el.blur(); el.querySelector(".task-row-open, .slice-member-open")?.blur(); });
        await select(true);
        if (selector === ".slice-member") {
          await page.locator(".slice-members").first().screenshot({ path: `.amp/in/artifacts/list-slice-members-${theme}-${width}.png` });
        }
      }
      await page.locator(".catalog-customer-register").screenshot({ path: `.amp/in/artifacts/list-customers-${theme}-${width}.png` });
      await page.locator(".catalog-notes-demo").evaluate(el => { el.scrollLeft = 0; });
      await page.locator(".note-card").first().locator("..").screenshot({ path: `.amp/in/artifacts/list-notes-${theme}-${width}.png` });
    }
  }
  console.log("List states passed: ten row families, three themes, desktop and mobile.");
} finally {
  await browser.close();
}
