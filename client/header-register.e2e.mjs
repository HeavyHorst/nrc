// Run against a served client: NRC_CLIENT_URL=http://localhost:8001 node client/header-register.e2e.mjs
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ serviceWorkers: "block", deviceScaleFactor: 2 });
const page = await context.newPage();
const base = process.env.NRC_CLIENT_URL || "http://localhost:8001";
const screenshots = process.env.NRC_HEADER_SCREENSHOTS;
async function capture(name, locator) {
  if (!screenshots) return;
  await fs.mkdir(screenshots, { recursive: true });
  await locator.screenshot({ path: path.join(screenshots, `${name}.png`) });
}
try {
  await page.goto(`${base}/design-system/`);
  const mobileHeader = page.locator("#catalogMobileTaskHeader");
  for (const width of [390, 768, 769]) {
    await page.setViewportSize({ width, height: 900 });
    if (width > 768) {
      assert.ok(await mobileHeader.isHidden(), "phone example is hidden above the mobile breakpoint");
      continue;
    }
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      const toggle = mobileHeader.locator("[data-mobile-filters]");
      const query = mobileHeader.locator(".filter-input");
      const sort = mobileHeader.locator('select[aria-label="Mobile task sort example"]');
      const create = mobileHeader.locator(".header-create-action");
      for (const expanded of [false, true, false]) {
        if (await toggle.getAttribute("aria-expanded") !== String(expanded)) await toggle.click();
        assert.ok(await query.isVisible(), `${width}/${theme}/${expanded}: query survives collapsed filters without an app ID`);
        assert.ok(await create.isVisible(), `${width}/${theme}/${expanded}: creation remains directly available`);
        assert.equal(await sort.isVisible(), expanded, "only secondary controls collapse");
        assert.deepEqual(await query.evaluate(el => {
          const css = getComputedStyle(el);
          return { height: el.getBoundingClientRect().height, font: css.fontSize, padding: css.paddingInline };
        }), { height: 32, font: "16px", padding: "8px" }, "catalogue query uses the compact production contract");
        if (expanded) {
          assert.equal((await sort.boundingBox()).height, 44, "catalogue sort uses the task register's touch height");
          assert.equal((await mobileHeader.locator(".task-flags-filter .custom-select__trigger").boundingBox()).height, 44,
            "expanded FLAGS uses the shared filter touch height");
        }
        if (width === 390) await capture(`mobile-catalog-${theme}-${expanded ? "expanded" : "collapsed"}`, mobileHeader);
      }
    }
  }
  console.log("PASS: mobile catalogue query/sort/FLAGS contracts in both themes, collapsed/expanded, at 390/768/769px");
  const stack = page.locator(".catalog-header-register-stack");
  const flagOptions = await stack.locator("#catalogTaskFlags option").allTextContents();
  assert.deepEqual(flagOptions, ["ALL", "BLOCKED", "OVERDUE", "BLOCKED + OVERDUE"],
    "catalogue presents blocked and overdue as one FLAGS filter");
  const catalogTaskResets = stack.locator(".task-filter-bar .header-operation", { hasText: "RESET" });
  const resetsInRow = await catalogTaskResets.evaluateAll((buttons) =>
    buttons.map((button) => button.parentElement.classList.contains("header-register-control-row")));
  assert.ok(resetsInRow.length >= 1 && resetsInRow.every(Boolean),
    "RESET remains a fixed operation beside the scrolling task filters in every grouping");
  const parameterCells = stack.locator(".task-filter-bar .header-control-scroll > .header-filter-cell:not(.filter-group-search, .header-filter-toggle, .task-grouping-cell)");
  const cellMetrics = async () => parameterCells.evaluateAll((cells) => cells.map((cell) => ({
    label: cell.querySelector(".filter-label")?.textContent.trim() || "",
    register: cell.closest(".header-register").querySelector(".header-register-title").textContent.trim(),
    width: Math.round(cell.getBoundingClientRect().width * 10) / 10,
    content: cell.scrollWidth,
  })));
  // While a register fits, its parameter cells keep one compact width. A cell
  // whose value is wider than that width — OWNER reading MY SLICES — takes its
  // content width instead, which is why the check is per register.
  await page.setViewportSize({ width: 1440, height: 900 });
  const widthsByRegister = new Map();
  for (const cell of await cellMetrics()) {
    if (!widthsByRegister.has(cell.register)) widthsByRegister.set(cell.register, new Set());
    widthsByRegister.get(cell.register).add(cell.width);
  }
  for (const [register, widths] of widthsByRegister) {
    assert.equal(widths.size, 1, `${register}: parameter cells share one compact width while the register fits`);
  }
  // A narrowed register compresses them only to their own content; a cell never
  // shrinks below its label and value, and the register scrolls instead.
  await page.setViewportSize({ width: 900, height: 900 });
  for (const cell of await cellMetrics()) {
    assert.ok(cell.width + 1 >= cell.content,
      `${cell.label} keeps its content width instead of overlapping the next cell (${cell.width} >= ${cell.content})`);
  }
  const defaultFlagsWidth = (await stack.locator(".task-flags-filter").boundingBox()).width;
  await stack.locator("#catalogTaskFlags").evaluate(el => el.value = "BLOCKED + OVERDUE");
  assert.deepEqual(await stack.locator(".task-flags-filter .custom-select__trigger").evaluate(el => ({
    text: el.textContent,
    clipped: el.scrollWidth > el.clientWidth,
  })), { text: "BLOCKED + OVERDUE", clipped: false }, "combined FLAGS value remains fully readable");
  assert.ok((await stack.locator(".task-flags-filter").boundingBox()).width > defaultFlagsWidth,
    "FLAGS expands only for its combined long value");
  await stack.locator("#catalogTaskFlags").evaluate(el => el.value = "ALL");
  assert.equal(await stack.locator(".graph-header").count(), 0, "catalogue does not document the removed Graph view");
  const bands = stack.locator(".header-register:is(.filter-register, .instrument-register, .metadata-header-register) > .header-register-identity-row");
  assert.equal(await bands.count(), 9, "the catalogue documents the slice filter register beside the ATTENTION register");
  const inspectorBands = page.locator(".inspector-matrix-header > .inspector-identity-row");
  assert.equal(await inspectorBands.count(), 3);
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: 900 });
    for (const theme of ["light", "dark"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      await stack.locator(".header-register-control-row, .header-control-scroll").evaluateAll(rows => rows.forEach(row => row.scrollLeft = 0));
      // Reminders has right-aligned actions rather than a leading filter/parameter.
      for (const band of await stack.locator(".header-register:not(.reminder-queue-header) > .header-register-identity-row").all()) {
        const alignment = await band.evaluate(row => {
          const title = row.querySelector(".header-register-title");
          const cell = row.parentElement.querySelector(".header-register-control-row :is(.header-filter-cell, .header-register-control)");
          const contentLeft = el => el.getBoundingClientRect().left
            + parseFloat(getComputedStyle(el).borderLeftWidth)
            + parseFloat(getComputedStyle(el).paddingLeft);
          return { title: title.textContent, offset: contentLeft(title) - contentLeft(cell) };
        });
        assert.ok(Math.abs(alignment.offset) < 1, `${width}/${theme}/${alignment.title}: title aligns with first control label (${alignment.offset}px)`);
      }
      // A search field keeps its label beside it on the field's own control
      // band: the name centers on the input's box, not on the padded cell the
      // bottom-aligned input leaves short. Parameter cells center both on the
      // cell, so only the search cells can drift.
      if (width > 768) {
        const searchFields = await stack.locator(".header-filter-cell:has(> .filter-input)").evaluateAll((cells) => cells
          .map((cell) => {
            const field = cell.querySelector(":scope > .filter-input").getBoundingClientRect();
            const name = cell.querySelector(":scope > label, :scope > .filter-label").getBoundingClientRect();
            return {
              label: cell.querySelector(":scope > label, :scope > .filter-label").textContent.trim(),
              register: cell.closest(".header-register").querySelector(".header-register-title").textContent.trim(),
              offset: Math.round((name.top + name.height / 2 - field.top - field.height / 2) * 100) / 100,
              drawn: field.height > 0,
            };
          })
          .filter((cell) => cell.drawn));
        assert.ok(searchFields.length >= 5, "the catalogue documents register search fields");
        for (const cell of searchFields) {
          assert.ok(Math.abs(cell.offset) < 1,
            `${width}/${theme}/${cell.register}: ${cell.label} centers on its search field (${cell.offset}px)`);
        }
      }
      const { rowHeight, filterRowHeight } = await page.evaluate(() => {
        const root = getComputedStyle(document.documentElement);
        const fontSize = parseFloat(root.fontSize);
        return {
          rowHeight: parseFloat(root.getPropertyValue("--header-row-height")) * fontSize,
          filterRowHeight: parseFloat(root.getPropertyValue("--header-filter-row-height")) * fontSize,
        };
      });
      for (const band of [...await bands.all(), ...await inspectorBands.all()]) {
        assert.equal((await band.boundingBox()).height, 20, `${width}/${theme}: metadata height`);
        const dividers = await band.evaluate(row => [...row.querySelectorAll("*")].filter(el => {
          if (el.matches(".btn")) return false; // Action borders are not metadata dividers.
          const css = getComputedStyle(el);
          return parseFloat(css.borderLeftWidth) > 0 || parseFloat(css.borderRightWidth) > 0;
        }).map(el => el.className));
        assert.deepEqual(dividers, [], `${width}/${theme}: metadata has no vertical field dividers`);
        const header = band.locator("..");
        const controls = header.locator(":scope > :is(.header-register-control-row, .inspector-mode-row)");
        const controlBox = await controls.boundingBox();
        const expectedControlHeight = await controls.evaluate((row, heights) =>
          row.matches(".system-log-register, .inspector-mode-row") || row.closest(".filter-register") ? heights.filter : heights.standard,
        { standard: rowHeight, filter: filterRowHeight });
        assert.equal(controlBox.height, expectedControlHeight, `${width}/${theme}: control height matches its register role`);
        const headerBox = await header.boundingBox();
        const borders = await header.evaluate(el => {
          const css = getComputedStyle(el);
          return parseFloat(css.borderTopWidth) + parseFloat(css.borderBottomWidth);
        });
        assert.ok(Math.abs(headerBox.height - 20 - controlBox.height - borders) < 1, "no leftover minimum-height gap");
      }
      assert.equal((await page.locator(".compact-header-register > .header-register-identity-row").first().boundingBox()).height, rowHeight,
        "single-row action header uses the same control height");
      // The read-only plate keeps its one full-height row, but its export
      // actions are ordinary operations: one-line verbs without synthetic
      // OUT/OP cells, on the shared control height and bottom baseline.
      const shareActions = page.locator(".catalog-share-stage .note-share-header .header-operation");
      assert.equal(await shareActions.count(), 3, "the share plate keeps three export operations");
      const shareGeometry = await shareActions.evaluateAll(actions => actions.map(action => {
        const rect = action.getBoundingClientRect();
        const row = action.closest(".header-register-identity-row").getBoundingClientRect();
        return {
          label: action.textContent.trim(),
          synthetic: getComputedStyle(action, "::before").content,
          height: rect.height,
          baseline: Math.round(row.bottom - rect.bottom),
        };
      }));
      for (const action of shareGeometry) {
        assert.equal(action.synthetic, "none", `${width}/${theme}/${action.label}: export action carries no synthetic register label`);
      }
      assert.equal(new Set(shareGeometry.map(action => action.height)).size, 1,
        `${width}/${theme}: share export actions share one control height`);
      assert.equal(new Set(shareGeometry.map(action => action.baseline)).size, 1,
        `${width}/${theme}: share export actions share one bottom baseline`);
      if (width > 768) {
        assert.ok(Math.abs(shareGeometry[0].height - 1.2 * await page.evaluate(() => parseFloat(getComputedStyle(document.documentElement).fontSize))) < 1,
          `${width}/${theme}: share export actions use the shared desktop operation height`);
      }
      const inspectorState = inspectorBands.first().locator(".detail-save-state");
      for (const state of ["SAVING", "SAVED", "ERROR", "LOADING"]) {
        await inspectorState.evaluate((el, state) => { el.textContent = state; el.dataset.saveState = state; }, state);
        assert.deepEqual(await inspectorState.evaluate(el => ({
          fontSize: getComputedStyle(el).fontSize,
          clipped: el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth,
        })), { fontSize: "10px", clipped: false }, `${width}/${theme}/${state}: inspector state remains readable`);
      }
      const notes = stack.locator(".notes-header");
      for (const state of ["0 RESULTS", "LOADING…", "12345 RESULTS"]) {
        await notes.locator(".header-register-state").evaluate((el, state) => el.textContent = state, state);
        const overflow = await notes.locator(".header-register-state").evaluate(el => el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth);
        assert.equal(overflow, false, `${width}/${theme}/${state}: count remains readable`);
      }

      // Compare the actual cascade, not just class names. Record panels carry a
      // mode register instead of tabs; mode groups remain in reminders.
      for (const tab of await page.locator(".inspector .task-detail-tabs > .btn").all()) {
        const sizing = await tab.evaluate(el => {
          const css = getComputedStyle(el);
          const parts = [...el.children];
          const contentWidth = parts.reduce((sum, part) => {
            const partCss = getComputedStyle(part);
            return sum + part.getBoundingClientRect().width + parseFloat(partCss.marginLeft) + parseFloat(partCss.marginRight);
          }, 0);
          return {
            width: el.getBoundingClientRect().width,
            contentWidth: contentWidth + parseFloat(css.paddingLeft) + parseFloat(css.paddingRight),
            clipped: parts.some(part => part.scrollWidth > part.clientWidth),
          };
        });
        assert.ok(Math.abs(sizing.width - sizing.contentWidth) < 1, `${width}/${theme}: inspector tabs fit their labels`);
        assert.equal(sizing.clipped, false, "inspector tab labels remain readable");
      }
      for (const header of await page.locator(".inspector-matrix-header").all()) {
        const geometry = await header.evaluate(el => {
          const bounds = nodes => [...nodes].filter(node => getComputedStyle(node).display !== "none").map(node => {
            const rect = node.getBoundingClientRect();
            return { height: rect.height, bottom: rect.bottom };
          });
          const contentHeight = node => {
            const css = getComputedStyle(node);
            return node.getBoundingClientRect().height
              - parseFloat(css.borderTopWidth) - parseFloat(css.borderBottomWidth)
              - parseFloat(css.paddingTop) - parseFloat(css.paddingBottom);
          };
          const row = el.querySelector(":scope > .inspector-mode-row");
          const cell = row && row.querySelector(":scope > .inspector-view-cell");
          const group = cell && cell.querySelector(".task-detail-tabs");
          return {
            actions: bounds(el.querySelectorAll(":scope > .inspector-mode-row > .header-operation")),
            tabs: bounds(el.querySelectorAll(":scope > .inspector-mode-row .task-detail-tabs > .btn")),
            modeGroup: Boolean(group),
            hasCell: Boolean(cell),
            rowBand: row ? contentHeight(row) : 0,
            cellBand: cell ? contentHeight(cell) : 0,
            groupBand: group ? contentHeight(group) : 0,
          };
        });
        for (const [family, boxes] of Object.entries({ actions: geometry.actions, tabs: geometry.tabs })) {
          if (boxes.length < 2) continue;
          assert.ok(Math.max(...boxes.map(box => box.height)) - Math.min(...boxes.map(box => box.height)) < 1,
            `${width}/${theme}: inspector ${family} share one height`);
          assert.ok(Math.max(...boxes.map(box => box.bottom)) - Math.min(...boxes.map(box => box.bottom)) < 1,
            `${width}/${theme}: inspector ${family} share one bottom baseline`);
        }
        // A mode group fills the band that holds it; its segments fill the group.
        // Record panels carry no mode group: their operations sit on the row's
        // right edge (a customer record draws the same way).
        if (geometry.modeGroup) {
          assert.ok(Math.abs(geometry.cellBand - geometry.groupBand) < 1,
            `${width}/${theme}: the mode group fills its cell (${geometry.groupBand} of ${geometry.cellBand})`);
          assert.ok(Math.abs(geometry.rowBand - geometry.groupBand) < 1,
            `${width}/${theme}: the mode group fills the mode row (${geometry.groupBand} of ${geometry.rowBand})`);
          for (const box of geometry.tabs) assert.ok(Math.abs(box.height - geometry.rowBand) < 1,
            `${width}/${theme}: mode segments fill the mode row (${box.height} of ${geometry.rowBand})`);
        }
      }
      const families = [".catalog-tabs", ".reminder-header-controls .tab-group", ".note-link-picker-types"];
      const expected = new Map();
      for (const family of families) {
        const tab = page.locator(`${family} > .btn`).first();
        const wasActive = await tab.evaluate(el => el.classList.contains("active"));
        for (const state of ["idle", "active", "hover", "active-hover", "focus"]) {
          await tab.evaluate((el, active) => el.classList.toggle("active", active), state.startsWith("active"));
          await tab.scrollIntoViewIfNeeded();
          await page.mouse.move(0, 0);
          await tab.evaluate(el => el.blur());
          if (state.includes("hover")) await tab.hover();
          if (state === "focus") {
            await tab.focus();
            await page.keyboard.press("Tab");
            await page.keyboard.press("Shift+Tab");
          }
          const style = await tab.evaluate(el => {
            const css = getComputedStyle(el);
            const label = getComputedStyle(el.querySelector("span") || el);
            return { labelFont: label.fontFamily, labelSize: label.fontSize, labelWeight: label.fontWeight, ...Object.fromEntries([
              "padding", "margin", "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
              "borderRadius", "backgroundColor", "boxShadow", "color", "fontFamily", "fontSize", "fontWeight", "letterSpacing", "lineHeight",
              "outlineStyle", "outlineWidth", "outlineColor", "outlineOffset",
            ].map(key => [key, css[key]])) };
          });
          assert.equal(style.labelFont, style.fontFamily, `${family}: label inherits tab font`);
          for (const side of ["Top", "Right", "Bottom", "Left"]) assert.equal(style[`border${side}Width`], "0px", `${family}/${state}: no border`);
          // The band owns the height, so only the baseline travels with the tab.
          assert.equal(style.outlineStyle, state === "focus" ? "solid" : "none", `${family}/${state}: no resting outline, keyboard focus visible`);
          if (state === "focus") {
            assert.equal(style.outlineWidth, "2px", `${family}/${state}: focus ring width`);
            assert.equal(style.outlineOffset, "-2px", `${family}/${state}: focus ring stays inside the segment`);
          }
          if (state.startsWith("active")) assert.match(style.boxShadow, /0px -3px 0px 0px inset$/,
            `${family}/${state}: the selected segment replaces the group baseline`);
          else assert.match(style.boxShadow, /0px -1px 0px 0px inset$/,
            `${family}/${state}: the segment draws the group baseline`);
          if (!expected.has(state)) expected.set(state, style);
          else assert.deepEqual(style, expected.get(state), `${width}/${theme}/${family}/${state}: identical tab appearance`);
        }
        await tab.evaluate((el, active) => { el.classList.toggle("active", active); el.blur(); }, wasActive);
      }
      // A count owns a fixed slot: a second digit grows into reserved space
      // instead of moving the segment and the controls after it.
      const countGroup = page.locator(".reminder-header-controls .tab-group").first();
      const countCell = page.locator(".reminder-header-controls .header-filter-cell").first();
      const countSlot = countGroup.locator(".tab-count").first();
      const slotText = await countSlot.textContent();
      const oneDigit = { group: await countGroup.boundingBox(), cell: await countCell.boundingBox() };
      await countSlot.evaluate(el => { el.textContent = "12"; });
      const twoDigits = { group: await countGroup.boundingBox(), cell: await countCell.boundingBox() };
      await countSlot.evaluate((el, text) => { el.textContent = text; }, slotText);
      assert.equal(twoDigits.group.width, oneDigit.group.width,
        `${width}/${theme}: a two-digit count does not widen the tab group`);
      assert.equal(twoDigits.cell.width, oneDigit.cell.width,
        `${width}/${theme}: a two-digit count does not widen the register cell`);
      assert.equal(twoDigits.group.x, oneDigit.group.x, `${width}/${theme}: the group keeps its place`);
      // Every control in the register draws its own boundary. The cells are
      // placement, not separator columns: no divider between neighbours and no
      // inset box around a control that already owns its surface.
      for (const control of await stack.locator(".header-register-control, .filter-input, .filter-select:not(.custom-select--hidden), .custom-select__trigger, .filter-checkbox-label").all()) {
        if (!await control.isVisible()) continue;
        if (await control.evaluate(el => el.matches(".btn:not(.nav-tab)"))) continue;
        assert.equal(await control.evaluate(el => {
          const css = getComputedStyle(el);
          return css.outlineStyle === "solid" || css.borderStyle === "solid";
        }), true, `${width}/${theme}: filters and toggles retain a flat drawn edge`);
        if (width > 768) {
          assert.equal(await control.evaluate(el => {
            const cell = el.closest(".header-filter-cell");
            return cell ? getComputedStyle(cell).borderRightStyle : "none";
          }), "none", `${width}/${theme}: no divider is drawn between register cells`);
        }
      }
      for (const action of await page.locator(".catalog-header-register-stack .btn:not(.nav-tab), .inspector-matrix-header .btn:not(.nav-tab)").all()) {
        const appearance = await action.evaluate(el => {
          const css = getComputedStyle(el);
          return { radius: css.borderRadius, shadow: css.boxShadow };
        });
        assert.equal(appearance.radius, "0px", `${width}/${theme}: square header action`);
        assert.equal(appearance.shadow, "none", `${width}/${theme}: flat header action`);
      }
      assert.equal(await page.locator(".header-register button.btn:not(.nav-tab):not(.header-operation), .inspector-matrix-header button.btn:not(.nav-tab):not(.header-operation)").count(), 0,
        `${width}/${theme}: every non-tab header action uses the shared semantic operation contract`);
      const pressAction = stack.locator(".task-filter-bar .btn").last();
      await pressAction.hover();
      await page.mouse.down();
      assert.equal(await pressAction.evaluate(el => getComputedStyle(el).boxShadow), "none", "pressed action stays flat");
      await page.mouse.up();
      await pressAction.focus();
      await page.keyboard.press("Tab");
      await page.keyboard.press("Shift+Tab");
      assert.equal(await pressAction.evaluate(el => getComputedStyle(el).outlineWidth), "2px", "flat action keyboard focus remains visible");
      await pressAction.evaluate(el => el.blur());
      await page.mouse.move(0, 0);
      for (const field of await stack.locator(".filter-input, .custom-select__trigger").all()) {
        assert.equal(await field.evaluate(el => getComputedStyle(el).boxShadow), "none", "fields remain flat");
      }
      for (const readout of await stack.locator(".header-register-title, .header-register-state, .header-register-readout").all()) {
        assert.equal(await readout.evaluate(el => getComputedStyle(el).outlineStyle), "none",
          `${width}/${theme}: passive metadata is not styled as clickable`);
      }
      const chatSearch = stack.locator(".chat-search-cell").first();
      const chatSearchBounds = await chatSearch.evaluate(cell => {
        const row = cell.parentElement.getBoundingClientRect();
        const cellRect = cell.getBoundingClientRect();
        const clear = cell.querySelector(":scope > .btn--icon").getBoundingClientRect();
        return { controls: [...cell.querySelectorAll(":scope > .filter-input, :scope > .btn--icon")].map(control => {
          const rect = control.getBoundingClientRect();
          return { top: rect.top, bottom: rect.bottom, rowTop: row.top, rowBottom: row.bottom };
        }), clearInset: cellRect.right - clear.right };
      });
      assert.ok(chatSearchBounds.controls.every(({ top, bottom, rowTop, rowBottom }) => top >= rowTop && bottom <= rowBottom),
        `${width}/${theme}: chat search and clear action stay inside the compact control row`);
      assert.ok(chatSearchBounds.clearInset >= 10,
        `${width}/${theme}: chat search clear action stays inset from the field edge`);
      await stack.locator(".task-filter-bar .task-flags-filter").first().scrollIntoViewIfNeeded();
      if (width > 768) {
        // One desktop register contract for every filter cell that carries a
        // value: label, value and arrow share one button-height cell.
        const cells = await stack.locator(".header-filter-cell:has(> .custom-select)").all();
        assert.ok(cells.length >= 8, `${width}/${theme}: catalogue documents parameter cells across registers (${cells.length})`);
        for (const cell of cells) {
          const register = await cell.evaluate(el => el.closest(".header-register").querySelector(".header-register-title").textContent.trim());
          assert.deepEqual(await cell.evaluate(el => {
            const label = el.querySelector(".filter-label, label").getBoundingClientRect();
            const trigger = el.querySelector(".custom-select__trigger").getBoundingClientRect();
            const cell = el.getBoundingClientRect();
            const css = getComputedStyle(el);
            return {
              aligned: Math.abs((label.top + label.height / 2) - (trigger.top + trigger.height / 2)) < 1,
              buttonHeight: Math.abs(cell.height - 1.2 * parseFloat(getComputedStyle(document.documentElement).fontSize)) < 1,
              contained: trigger.top >= cell.top && trigger.bottom <= cell.bottom,
              arrowInset: parseFloat(getComputedStyle(el.querySelector(".custom-select__trigger")).paddingRight) > 0,
              opticalOffset: parseFloat(getComputedStyle(el.querySelector(".custom-select__trigger")).paddingBottom) > 0,
              // The dropdown owns its bounded surface; the cell is placement and
              // draws no divider of its own.
              controlEdge: getComputedStyle(el.querySelector(".custom-select__trigger")).outlineStyle === "solid" && css.borderTopStyle === "none",
            };
          }), { aligned: true, buttonHeight: true, contained: true, arrowInset: true, opticalOffset: true, controlEdge: true },
          `${width}/${theme}/${register}: label, value and arrow share one button-height register`);
        }
        for (const scroll of await stack.locator(".header-control-scroll").all()) {
          const register = await scroll.evaluate(el => el.closest(".header-register").querySelector(".header-register-title").textContent.trim());
          assert.equal(await scroll.evaluate(el => el.scrollWidth <= el.clientWidth + 1), true,
            `${width}/${theme}/${register}: filters expose the final right edge without horizontal clipping`);
        }
      }
      await stack.locator(".task-filter-bar .header-control-scroll").evaluateAll(rows => rows.forEach(row => row.scrollLeft = 0));
      await capture(`catalogue-${width}-${theme}-task-modes`, stack.locator(".task-filter-bar"));
    }
  }
  // Exercise the production view transition, not just catalogue classes.
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.routeWebSocket("**/*", socket => socket.onMessage(() => {}));
  await page.goto(base);
  await page.waitForFunction(() => window.NRCViewManager);
  // The task register below is the flat-list one: the slice grouping is the
  // default and swaps these parameter cells out for the slice register.
  await page.evaluate(() => window.NRCViewManager.setActiveView("kanban"));
  await page.waitForSelector('[data-task-grouping="flat"]');
  await page.locator('[data-task-grouping="flat"]').click();
  for (const view of ["systemLog", "chat", "sullivan", "notes", "chat"]) {
    await page.evaluate(view => window.NRCViewManager.setActiveView(view), view);
    assert.equal(await page.locator(".chat-header").evaluate(el => el.classList.contains("metadata-header-register")),
      true, `${view}: production metadata mode`);
    assert.equal(await page.locator(".users-bar").isVisible(), view === "chat",
      `${view}: presence occupies a header band only in Messages`);
    // System Log hides the inspector entirely.
    if (view === "systemLog") continue;
    const scope = page.locator("#inspectorHeader > .inspector-mode-row");
    assert.equal(await scope.evaluate(el => el.getBoundingClientRect().height),
      await page.evaluate(() => {
        const root = getComputedStyle(document.documentElement);
        return parseFloat(root.getPropertyValue("--header-filter-row-height")) * parseFloat(root.fontSize);
      }),
      `${view}: default inspector uses the shared action-row height`);
  }
  await page.evaluate(() => window.NRCSystemLog.show());
  assert.ok(await page.locator("#systemLogHeaderControls").isVisible());
  assert.equal((await page.locator(".chat-header > .header-register-identity-row").boundingBox()).height, 20);
  assert.equal(await page.locator("#chatStatsLabel").textContent(), "EVENTS / LAST");

  assert.deepEqual(await page.locator("#filterFlags option").allTextContents(), flagOptions,
    "production and catalogue FLAGS options match");
  assert.equal(await page.locator(".header-register [data-register-label]").count(), 0,
    "header actions do not expose synthetic OP/OUT labels, share registers included");
  for (const create of await page.locator(".header-create-action").all()) {
    const colors = await create.evaluate(el => {
      const css = getComputedStyle(el);
      return { background: css.backgroundColor, foreground: css.color, transparent: css.backgroundColor === "rgba(0, 0, 0, 0)" };
    });
    assert.equal(colors.transparent, false, `creation action is filled: ${JSON.stringify(colors)}`);
  }

  // Register readouts, control baselines and the inspector boundary are shared
  // contracts: count reads as scope identity, blocked stays neutral, only
  // overdue is danger, and every filter ends on one row baseline.
  const createBackgrounds = [];
  for (const theme of ["light", "dark"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    await page.evaluate(() => NRCViewManager.setActiveView("kanban"));
    const contract = await page.evaluate(() => {
      const token = (name) => {
        const probe = document.createElement("span");
        probe.style.color = `var(${name})`;
        probe.style.borderLeftColor = `var(${name})`;
        probe.style.backgroundColor = `var(${name})`;
        document.body.appendChild(probe);
        const css = getComputedStyle(probe);
        const value = { color: css.color, border: css.borderLeftColor, background: css.backgroundColor };
        probe.remove();
        return value;
      };
      const bar = document.getElementById("taskFilterBar");
      const color = (el) => getComputedStyle(el).color;
      const separator = (el) => getComputedStyle(el, "::before").content;
      const alerts = bar.querySelector(".header-register-alerts");
      const items = [...alerts.querySelectorAll(".header-register-alert")];
      const controls = {
        search: document.getElementById("taskSearch"),
        // The register carries the slice filters' dropdown too, and the grouping
        // that is off screen hides its cells; the baseline contract is about the
        // controls the reader can see.
        select: [...bar.querySelectorAll(".custom-select__trigger")].find((trigger) => trigger.getBoundingClientRect().height > 0),
        flags: bar.querySelector(".task-flags-filter .custom-select__trigger"),
        reset: document.getElementById("filterReset"),
        create: document.getElementById("createTaskHeaderBtn"),
      };
      const row = bar.querySelector(".header-register-control-row");
      const inspector = document.querySelector(".inspector.ledger-context.agenda-panel");
      return {
        title: color(bar.querySelector(".header-register-title")),
        count: color(bar.querySelector(".filter-result-count")),
        blocked: { label: color(items[0]), value: color(items[0].querySelector("b")) },
        overdue: { label: color(items[1]), value: color(items[1].querySelector("b")) },
        danger: token("--accent-danger").color,
        scope: token("--link-text").color,
        createBackground: getComputedStyle(controls.create).backgroundColor,
        createToken: token("--action-create-bg").background,
        separators: [separator(alerts), separator(items[1])],
        bottoms: Object.fromEntries(Object.entries(controls).map(([name, el]) => [name, el.getBoundingClientRect().bottom])),
        heights: Object.fromEntries(Object.entries(controls).map(([name, el]) => [name, el.getBoundingClientRect().height])),
        rowBottom: row.getBoundingClientRect().bottom,
        rowHeight: row.getBoundingClientRect().height,
        filterRowHeight: parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--header-filter-row-height"))
          * parseFloat(getComputedStyle(document.documentElement).fontSize),
        inspectorBorder: inspector ? getComputedStyle(inspector).borderLeftColor : null,
        frame: token("--border-primary").border,
      };
    });
    assert.equal(contract.count, contract.title, `${theme}: result count reads like the register title`);
    assert.equal(contract.count, contract.scope, `${theme}: result count uses the scope accent token`);
    assert.equal(contract.blocked.label, contract.blocked.value, `${theme}: blocked stays one neutral token`);
    assert.equal(contract.overdue.label, contract.overdue.value, `${theme}: overdue label and count share one color`);
    assert.equal(contract.overdue.value, contract.danger, `${theme}: overdue is the only danger readout`);
    assert.notEqual(contract.blocked.value, contract.danger, `${theme}: blocked is not painted as danger`);
    assert.equal(contract.createBackground, contract.createToken, `${theme}: creation uses the theme action token`);
    createBackgrounds.push(contract.createBackground);
    assert.deepEqual(contract.separators, ['"|"', '"|"'], `${theme}: readout tokens keep a rule between them`);
    const compactBottoms = [contract.bottoms.search, contract.bottoms.reset, contract.bottoms.create];
    assert.ok(Math.max(...compactBottoms) - Math.min(...compactBottoms) <= 1,
      `${theme}: search and actions share one baseline: ${JSON.stringify(contract.bottoms)}`);
    assert.ok(Math.max(...Object.values(contract.bottoms)) - Math.min(...Object.values(contract.bottoms)) <= 1,
      `${theme}: task filters and actions share one baseline: ${JSON.stringify(contract.bottoms)}`);
    assert.equal(contract.heights.flags, contract.heights.select,
      `${theme}: FLAGS uses the same control height as the other selects`);
    assert.ok(Object.values(contract.bottoms).every((bottom) => bottom <= contract.rowBottom + 0.5),
      `${theme}: no control leaves its register row: ${JSON.stringify(contract.bottoms)} vs ${contract.rowBottom}`);
    assert.equal(contract.rowHeight, contract.filterRowHeight, `${theme}: filter row uses the tightened register height`);
    assert.equal(contract.inspectorBorder, contract.frame, `${theme}: inspector boundary uses the shared frame rule`);
  }
  assert.notEqual(createBackgrounds[0], createBackgrounds[1], "creation color adapts between light and dark themes");

  // Production mobile register: query and creation survive collapsed filters,
  // and every visible operation stays inside the register at phone width.
  await page.setViewportSize({ width: 390, height: 900 });
  await page.evaluate(() => NRCViewManager.setActiveView("kanban"));
  for (const expanded of [false, true, false]) {
    const mobileBar = page.locator("#taskFilterBar");
    const toggle = mobileBar.locator("[data-mobile-filters]");
    if (await toggle.getAttribute("aria-expanded") !== String(expanded)) await toggle.click();
    assert.ok(await mobileBar.locator("#taskSearch").isVisible(), `${expanded}: production query survives collapsed filters`);
    const create = mobileBar.locator("#createTaskHeaderBtn");
    assert.ok(await create.isVisible(), `${expanded}: production creation stays directly available`);
    const box = await create.boundingBox();
    assert.ok(box.height >= 44, `${expanded}: creation keeps a 44px touch target (${box.height})`);
    const bar = await mobileBar.boundingBox();
    assert.ok(box.x + box.width <= bar.x + bar.width + 1, `${expanded}: creation stays inside the mobile register`);
    assert.ok(box.y >= bar.y && box.y + box.height <= bar.y + bar.height + 1,
      `${expanded}: creation stays in the visible mobile register viewport`);
    const toggleBox = await toggle.boundingBox();
    assert.ok(toggleBox.x + toggleBox.width < bar.x + bar.width,
      `${expanded}: filter toggle remains inset from the register edge`);
    assert.equal(toggleBox.height, 44, `${expanded}: filter toggle uses the shared mobile touch height`);
    assert.equal(await toggle.evaluate(el => getComputedStyle(el).borderStyle), "solid",
      `${expanded}: filter toggle remains a visibly framed button`);
    if (expanded) {
      const reset = mobileBar.locator("#filterReset");
      assert.ok(await reset.isVisible(), "expanded: reset remains directly available beside creation");
      assert.equal(await reset.evaluate(el => getComputedStyle(el).borderStyle), "solid",
        "expanded: reset keeps the shared button outline on mobile");
      assert.equal(await mobileBar.locator("#filterStatus").evaluate(el => getComputedStyle(el.parentElement.parentElement).borderRightWidth), "0px",
        "expanded: desktop cell dividers do not trail mobile select outlines");
    }
  }
  await page.evaluate(() => NRCViewManager.setActiveView("notes"));
  const notesBar = page.locator("#notesPanel .notes-header");
  await notesBar.locator("[data-mobile-filters]").click();
  const notesLayout = await notesBar.evaluate(bar => {
    const box = selector => {
      const rect = bar.querySelector(selector).getBoundingClientRect();
      return { top: rect.top, left: rect.left, right: rect.right };
    };
    const projectCell = bar.querySelector("#notesProjectFilter").parentElement.parentElement;
    return {
      create: box("#createNoteHeaderBtn"),
      project: box("#notesProjectFilter").top,
      tag: box("#notesTagFilter").top,
      projectDivider: getComputedStyle(projectCell).borderRightWidth,
    };
  });
  assert.ok(notesLayout.create.left > 0 && notesLayout.create.top < notesLayout.project,
    "expanded notes: creation occupies the upper-right action cell");
  assert.equal(notesLayout.project, notesLayout.tag,
    "expanded notes: project and tag share one balanced filter row");
  assert.equal(notesLayout.projectDivider, "0px",
    "expanded notes: desktop cell dividers do not trail mobile select outlines");
  await page.setViewportSize({ width: 1280, height: 900 });
  assert.equal(await page.locator("#graphBtn, #graphPanel, #graphContainer").count(), 0,
    "production omits the removed Graph view");
  assert.deepEqual(await page.evaluate(() => ["createTaskHeaderBtn", "createNoteHeaderBtn", "customerNew", "createReminderBtn"].map(id => document.getElementById(id).textContent)),
    ["+ TASK", "+ NOTE", "+ COMPANY", "+ REMINDER"], "creation-capable workspaces use explicit action labels");
  for (const [view, button, title] of [["kanban", "#createTaskHeaderBtn", "NEW TASK"], ["notes", "#createNoteHeaderBtn", "NEW NOTE"]]) {
    await page.evaluate(view => NRCViewManager.setActiveView(view), view);
    await page.locator(button).click();
    assert.equal(await page.locator("#nrcDialogTitle").textContent(), title, `${view}: header creation opens its existing prompt flow`);
    await page.keyboard.press("Escape");
  }
  for (const [view, register] of [["kanban", "#taskFilters"], ["notes", "#noteFilters"]]) {
    await page.evaluate(view => NRCViewManager.setActiveView(view), view);
    const geometry = await page.locator(register).evaluate(row => {
      const scroll = row.querySelector(".header-control-scroll").getBoundingClientRect();
      const create = row.querySelector(".header-create-action").getBoundingClientRect();
      return { scrollRight: scroll.right, createLeft: create.left, createRight: create.right, rowRight: row.getBoundingClientRect().right };
    });
    assert.ok(geometry.scrollRight <= geometry.createLeft + 1,
      `${view}: filters end before the fixed creation action: ${JSON.stringify(geometry)}`);
    assert.ok(geometry.createRight <= geometry.rowRight + 1,
      `${view}: creation action remains inside its register: ${JSON.stringify(geometry)}`);
  }

  // A populated production workbench has a more specific mobile cascade than
  // the catalogue. Exercise both action sets with an actual context selector.
  await page.route("**/ask/ready", route => route.fulfill({ json: { ai_username: "sullivan-headers" } }));
  await page.evaluate(() => {
    myNickname = "header-test";
    currentRoomId = 7n;
    activeDMs.set(DM_CONV_FLAG | 42n, { username: "sullivan-headers", online: true, unread: 0 });
    const stamp = BigInt(Date.now()) * 1000000n;
    NRCAssets.roomAssets.set(0n, new Map([[710n, {
      assetId: 710n, convId: 0n, assetType: AssetType.Reminder, owner: "header-test",
      createdAt: stamp, updatedAt: stamp, attachments: [],
      payload: JSON.stringify({ title: "Review headers", deadline_at: String(stamp + 86400000000000n), window_start_at: "0" }),
    }]]));
  });
  for (const width of [1280, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const theme of ["lupine", "matte-black"]) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      for (const focused of [false, true]) {
        await page.evaluate(focused => NRCAI.openSullivanWithContext(7n, { focused }), focused);
        const row = page.locator("#chatHeaderAIControls");
        await row.evaluate(el => el.scrollLeft = 0);
        const cell = row.locator(".ask-context-chip");
        assert.ok(await cell.evaluate(el => el.getBoundingClientRect().width >= 8 * parseFloat(getComputedStyle(document.documentElement).fontSize)),
          `${width}/${theme}/${focused}: context does not collapse`);
        const label = cell.locator("label");
        const trigger = cell.locator(".custom-select__trigger");
        const labelBox = await label.boundingBox();
        const triggerBox = await trigger.boundingBox();
        if (width > 768) {
          assert.ok(Math.abs((labelBox.y + labelBox.height / 2) - (triggerBox.y + triggerBox.height / 2)) < 1,
            `${width}/${theme}/${focused}: CONTEXT reads on the selector's baseline in its register cell`);
        } else {
          assert.ok(labelBox.y + labelBox.height <= triggerBox.y, "CONTEXT stays above the selector");
        }
        assert.equal(await trigger.evaluate(el => el.scrollWidth > el.clientWidth + 1), false, "selected room fits");
        const titleStyle = await page.locator("#chatHeaderTitle").evaluate(el => {
          const css = getComputedStyle(el);
          return [css.display, css.textOverflow, css.overflowX];
        });
        assert.deepEqual(titleStyle, ["block", "ellipsis", "hidden"], "title uses real text ellipsis, not flex clipping");
        await capture(`headers-${width}-${theme}-sullivan${focused ? "-share" : ""}`, page.locator(".chat-header"));
        assert.equal(await trigger.isDisabled(), true, "workspace context is fixed at narrow widths too");
        assert.equal(await cell.locator("select").inputValue(), "0");
        const lastAction = row.locator("button.header-register-control:visible").last();
        await lastAction.focus();
        const geometry = await lastAction.evaluate(el => {
          const button = el.getBoundingClientRect(), row = el.parentElement.getBoundingClientRect();
          return { visible: button.left >= row.left && button.right <= row.right + 1, button: { left: button.left, right: button.right }, row: { left: row.left, right: row.right }, scrollLeft: el.parentElement.scrollLeft };
        });
        assert.ok(geometry.visible, `${width}/${theme}/${focused}: keyboard focus scrolls the last operation into view: ${JSON.stringify(geometry)}`);
      }
      await page.evaluate(async () => {
        NRCViewManager.setActiveView("reminders");
        await NRCInspector.openEntity({ roomId: 7n, type: "reminder", id: 710n });
      });
      const view = page.locator("#inspectorHeader .inspector-view-cell");
      assert.equal(await view.locator(".filter-label").count(), 0, "the mode group names itself; no VIEW cell label");
      assert.equal(await view.locator("button").count(), 1, "reminder retains only DETAIL");
      assert.equal(await view.locator("button").innerText(), "DETAIL", "no inline MODE prefix");
      const viewBand = (await view.boundingBox()).height;
      assert.equal((await view.locator("button").boundingBox()).height, viewBand,
        "the single mode segment fills the inspector band");
      await capture(`headers-${width}-${theme}-reminder`, page.locator("#inspectorHeader"));
      await page.evaluate(() => NRCInspector.close());
    }
  }
  // Wide layouts must not distribute spare width into toggles or buttons.
  for (const theme of ["lupine", "matte-black"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    const sizes = [];
    for (const width of [1280, 2560]) {
      await page.setViewportSize({ width, height: 1440 });
      await page.evaluate(() => NRCViewManager.setActiveView("notes"));
      const query = await page.locator(".notes-header .filter-input").boundingBox();
      const dropdowns = await page.locator(".notes-header .custom-select__trigger").evaluateAll(els => els.map(el => el.getBoundingClientRect().width));
      await page.evaluate(() => NRCViewManager.setActiveView("reminders"));
      const reminders = page.locator(".reminder-header-controls:visible");
      const toggle = reminders.locator(".filter-checkbox-label");
      const toggleWidth = (await toggle.boundingBox()).width;
      const textWidth = (await toggle.locator("span").boundingBox()).width;
      assert.ok(toggleWidth - textWidth < 24, "HIDE LOCKED fits its label plus shared button padding rather than filling the row");
      const showWidth = (await reminders.locator(".header-filter-cell").first().boundingBox()).width;
      const newButton = await reminders.locator(".reminder-create-btn").boundingBox();
      const row = await reminders.boundingBox();
      const actionInset = row.x + row.width - newButton.x - newButton.width;
      assert.ok(actionInset > 0 && actionInset < 10, `NEW keeps a compact right inset (${actionInset}px)`);
      await capture(`wide-${width}-${theme}-reminders`, reminders.locator(".."));
      await page.evaluate(() => NRCAI.openSullivanWithContext(7n, { focused: true }));
      const actions = await page.locator("#chatHeaderAIControls button.header-register-control:visible").evaluateAll(els => els.map(el => el.getBoundingClientRect().width));
      assert.ok(actions.every(width => width < 180), "Sullivan operations fit their labels");
      await capture(`wide-${width}-${theme}-sullivan`, page.locator(".chat-header"));
      sizes.push({ query: query.width, dropdowns, toggleWidth, showWidth, actions });
    }
    assert.ok(sizes[1].query > sizes[0].query + 500, "search absorbs the additional viewport width");
    const { query: narrowQuery, ...narrowControls } = sizes[0];
    const { query: wideQuery, ...wideControls } = sizes[1];
    assert.deepEqual(wideControls, narrowControls, "dropdowns, reminder modes and Sullivan actions do not grow on wide screens");
  }

  // Navigate real entities, then resize through the production pointer handler.
  await page.evaluate(() => {
    const stamp = BigInt(Date.now()) * 1000000n;
    for (const id of [1n, 2n]) NRCAssets.roomAssets.get(0n).set(id, {
      assetId: id, convId: 0n, assetType: AssetType.Note, owner: "header-test",
      createdAt: stamp, updatedAt: stamp, attachments: [],
      preview: JSON.stringify({ title: `Header layout review ${id}`, format: "markdown" }),
      payload: "Synthetic preview content",
    });
    NRCViewManager.setActiveView("notes");
  });
  for (const theme of ["lupine", "matte-black"]) {
    await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
    for (const width of [440, 600, 900]) {
      await page.evaluate(async () => {
        await NRCInspector.close();
        await NRCInspector.openEntity({ roomId: 7n, type: "note", id: 1n });
      });
      const panel = page.locator(".agenda-panel");
      const handle = await page.locator(".agenda-resize-handle").boundingBox();
      const oldWidth = (await panel.boundingBox()).width;
      const x = handle.x + handle.width / 2, y = handle.y + handle.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x + oldWidth - width, y, { steps: 4 });
      await page.mouse.up();
      assert.equal((await panel.boundingBox()).width, width, "inspector resized through its handle");
      const header = page.locator("#inspectorHeader");
      const row = header.locator(".inspector-mode-row");
      const modeRowBox = await row.boundingBox();
      const lastOperation = await row.locator("> .header-operation").last().boundingBox();
      assert.ok(modeRowBox.x + modeRowBox.width - lastOperation.x - lastOperation.width < 10,
        "without a mode group the record's operations stay on the row's right edge");
      await capture(`inspector-${width}-${theme}-no-history`, header);
      await page.evaluate(() => NRCInspector.openEntity({ roomId: 7n, type: "note", id: 2n }));
      const back = await row.locator("#inspectorBack").boundingBox();
      const createNote = await page.locator("#createNoteHeaderBtn").boundingBox();
      assert.ok(Math.abs(back.y - createNote.y) <= 1,
        `${width}/${theme}: Inspector operations share the Notes header baseline`);
      const firstOpBox = await row.locator(":scope > button.header-operation").first().boundingBox();
      assert.ok(firstOpBox.x - back.x - back.width < 12,
        "BACK stays beside the record's operations, not across an auto-margin gap");
      assert.equal(await row.locator("#inspectorBack small").evaluate(el => getComputedStyle(el).display), "none",
        "history navigation uses the same single-line button contract as the other operations");
      const controls = await row.locator(":scope > *").evaluateAll(els => els.map(el => {
        const rect = el.getBoundingClientRect();
        return { left: rect.left, right: rect.right, clipped: el.scrollWidth > el.clientWidth + 1 };
      }));
      for (let i = 1; i < controls.length; i++) assert.ok(controls[i].left >= controls[i - 1].right, "inspector controls do not overlap");
      assert.ok(controls.every(control => !control.clipped), "inspector controls remain readable");
      const operations = await row.locator(":scope > button.header-operation").evaluateAll(buttons => buttons.map(button => {
        const css = getComputedStyle(button);
        return {
          height: button.getBoundingClientRect().height,
          borderStyle: css.borderStyle,
          background: css.backgroundColor,
          marginBottom: css.marginBottom,
          marginRight: css.marginRight,
        };
      }));
      assert.ok(operations.length >= 3, "note inspector exposes history and record operations");
      assert.ok(operations.every(operation => operation.height === operations[0].height && operation.borderStyle === "solid" &&
        operation.background === operations[0].background && operation.marginBottom === operations[0].marginBottom &&
        operation.marginRight === operations[0].marginRight),
      `BACK, EDIT, SHARE and CLOSE use one inset header-button contract: ${JSON.stringify(operations)}`);
      const railInset = parseFloat(operations.at(-1).marginRight);
      assert.ok(railInset >= 3 && railInset <= 5,
        "the final CLOSE button keeps the shared inset instead of sitting on the inspector edge");
      await row.locator("#noteDetailEdit").hover();
      const hoverState = await row.locator("#noteDetailEdit").evaluate(el => {
        const probe = document.createElement("span");
        probe.style.background = "var(--btn-hover-bg)";
        probe.style.color = "var(--btn-hover-text)";
        document.body.append(probe);
        const expected = getComputedStyle(probe);
        const actual = getComputedStyle(el);
        const result = {
          background: actual.backgroundColor,
          color: actual.color,
          expectedBackground: expected.backgroundColor,
          expectedColor: expected.color,
        };
        probe.remove();
        return result;
      });
      assert.deepEqual({ background: hoverState.background, color: hoverState.color },
        { background: hoverState.expectedBackground, color: hoverState.expectedColor },
        `${width}/${theme}: Inspector operations use the shared visible hover state`);
      await row.locator(".task-detail-close").hover();
      const closeHover = await row.locator(".task-detail-close").evaluate(el => {
        const css = getComputedStyle(el);
        return { background: css.backgroundColor, color: css.color, icon: getComputedStyle(el.querySelector("b")).color };
      });
      assert.deepEqual(closeHover, {
        background: hoverState.expectedBackground,
        color: hoverState.expectedColor,
        icon: hoverState.expectedColor,
      }, `${width}/${theme}: CLOSE is a normal navigation operation, not a danger action`);
      const rowBox = await row.boundingBox();
      const contentWidth = await row.evaluate(el => el.scrollWidth);
      assert.ok(contentWidth <= rowBox.width + 1, `${width}/${theme}: history controls fit without a scrollbar gutter`);
      const rightInset = parseFloat(operations.at(-1).marginRight);
      const trailingInset = rowBox.x + contentWidth - controls.at(-1).right;
      assert.ok(Math.abs(trailingInset - rightInset) <= 1,
        `${width}/${theme}: the action rail keeps its shared inset at the right edge (${trailingInset}px)`);
      await capture(`inspector-${width}-${theme}-history`, header);
      // A narrow panel closes the block to one register line; a wide panel
      // shows the messages as a column, where that line is inert.
      const messagesArea = page.locator("#inspectorEntityHost [data-messages-area]");
      const messagesBody = page.locator("#inspectorEntityHost [data-messages-body]");
      if (await messagesBody.isVisible()) {
        assert.equal(await messagesArea.getAttribute("data-messages-open"), "false",
          "the wide panel shows the messages column while the narrow state stays closed");
      } else {
        const messagesToggle = page.locator("#inspectorEntityHost [data-messages-toggle]");
        await messagesToggle.click();
        assert.equal(await messagesArea.getAttribute("data-messages-open"), "true",
          "the message block opens after resizing");
        await messagesToggle.click();
        assert.equal(await messagesArea.getAttribute("data-messages-open"), "false",
          "the message block closes again");
      }
      await capture(`inspector-${width}-${theme}-messages`, header);
      await row.locator(".task-detail-close").focus();
      const closeBounds = await row.locator(".task-detail-close").evaluate(el => {
        const button = el.getBoundingClientRect(), row = el.parentElement.getBoundingClientRect();
        return { left: button.left, right: button.right, rowLeft: row.left, rowRight: row.right };
      });
      assert.ok(closeBounds.left >= closeBounds.rowLeft && closeBounds.right <= closeBounds.rowRight + 1,
        `${width}/${theme}: keyboard focus exposes the entire close action: ${JSON.stringify(closeBounds)}`);
      await row.locator("#inspectorBack").click();
      const restoredBox = await row.boundingBox();
      const restoredLast = await row.locator("> .header-operation").last().boundingBox();
      assert.ok(restoredBox.x + restoredBox.width - restoredLast.x - restoredLast.width < 10,
        "returning clears history and keeps the record's operations on the row's right edge");
    }
  }
  console.log("PASS: compact controls at 1280/2560px; real inspector navigation, message block and pointer resizing at 440/600/900px in both themes");
  console.log("PASS: catalogue/production operation and mode labels, responsive Sullivan context/title/actions, and the reminder's single mode segment at 1280/390/320px in both themes");
  console.log("PASS: aligned headers, uniform control heights, content-width inspector tabs, three identical tab families in five states, groups filling their band on one baseline with counts in a fixed slot, two themes, desktop/narrow layouts and production view transitions");
} finally {
  await browser.close();
}
