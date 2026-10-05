// NRC_CLIENT_URL=http://localhost:8000 node client/theme-danger.e2e.mjs
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";

const css = await fs.readFile(new URL("css/foundation.css", import.meta.url), "utf8");
const themes = [...new Set(["light", ...[...css.matchAll(/\[data-theme="([^"]+)"\]/g)].map(match => match[1])])];
function luminance(color) {
  const scale = color.startsWith("color(srgb") ? 1 : 255;
  const channels = color.match(/[\d.]+/g).slice(0, 3).map(Number).map(value => {
    const channel = value / scale;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}
function contrast(a, b) {
  const values = [luminance(a), luminance(b)].sort((a, b) => a - b);
  return (values[1] + 0.05) / (values[0] + 0.05);
}
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ deviceScaleFactor: 2, serviceWorkers: "block" });
  await page.goto(`${process.env.NRC_CLIENT_URL || "http://localhost:8000"}/design-system/`);
  // Exercise the production phone drill-in state, not its hidden register view.
  await page.locator(".catalog-slice-layout").evaluate(el => {
    el.classList.add("slice-view");
    el.dataset.sliceMobileDetail = "true";
  });
  const record = page.locator(".slice-identity").first();
  const close = record.getByRole("button", { name: "CLOSE SLICE", exact: true });
  const remove = record.getByRole("button", { name: "DELETE SLICE", exact: true });
  assert.equal(await close.getAttribute("class"), "btn", "reversible closure is neutral");
  assert.match(await remove.getAttribute("class"), /btn--danger/, "deletion remains destructive");
  const screenshots = process.env.NRC_THEME_SCREENSHOTS;
  if (screenshots) await fs.mkdir(screenshots, { recursive: true });
  let minimum = Infinity;
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: 900 });
    for (const theme of themes) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await close.hover();
      const normal = await remove.evaluate(el => {
        const css = getComputedStyle(el);
        return { color: css.color, background: css.backgroundColor, border: css.borderTopColor };
      });
      const [r, g, b] = normal.color.match(/\d+/g).map(Number);
      assert.ok(r > g * 1.4 && r > b * 1.4, `${theme}: danger must be red, not a decorative palette color`);
      assert.equal(normal.border, normal.color, `${theme}: danger border matches text`);
      const textContrast = contrast(normal.color, normal.background);
      assert.ok(textContrast >= 4.5, `${theme}/${width}: text contrast ${textContrast}`);
      await remove.hover();
      const hover = await remove.evaluate(el => {
        const css = getComputedStyle(el);
        return { color: css.color, background: css.backgroundColor };
      });
      assert.equal(hover.background, normal.color, `${theme}: hover uses semantic danger fill`);
      const hoverContrast = contrast(hover.color, hover.background);
      assert.ok(hoverContrast >= 4.5, `${theme}/${width}: hover contrast ${hoverContrast}`);
      minimum = Math.min(minimum, textContrast, hoverContrast);
      if (screenshots && ["lupine", "hackerman", "lumon", "white"].includes(theme)) {
        await record.screenshot({ path: path.join(screenshots, `${theme}-${width}-hover.png`) });
        await page.mouse.move(0, 0);
        await record.screenshot({ path: path.join(screenshots, `${theme}-${width}.png`) });
      }
    }
  }
  console.log(`PASS: ${themes.length} themes at 1280/390px; red danger, neutral closure, normal/hover contrast ≥ ${minimum.toFixed(2)}:1`);
} finally {
  await browser.close();
}
