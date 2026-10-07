# NRC Portable Primitive Contract

Use these primitives by default in generated NRC-styled HTML. They intentionally depend only on the stable `--nrc-*` theme aliases, so they work inside NRC notes without repository access.

Include only the primitives the document uses. These are portable equivalents of production roles, not a second application shell. The `--doc-*` variables below are document-local derivations, not exported NRC aliases. Border colors are approximations where the stable contract does not expose a production token; button inversion and selected underlines preserve the production state vocabulary.

## Canonical CSS

The document root should have a unique ID and the shared `nrc-doc` class:

```html
<div id="latency-report" class="nrc-doc">...</div>
```

```css
.nrc-doc {
  --doc-panel: color-mix(in srgb, var(--nrc-bg) 96%, var(--nrc-text));
  --doc-content: color-mix(in srgb, var(--nrc-bg) 99%, var(--nrc-text));
  --doc-control: color-mix(in srgb, var(--nrc-bg) 92%, var(--nrc-text));
  --doc-rule: color-mix(in srgb, var(--nrc-bg) 80%, var(--nrc-border));
  box-sizing: border-box;
  min-height: 100vh;
  margin: 0;
  background: var(--nrc-bg);
  color: var(--nrc-text);
  font: 0.75rem/1.5 var(--nrc-font-sans);
}
.nrc-doc *, .nrc-doc *::before, .nrc-doc *::after { box-sizing: inherit; }
.nrc-doc :where(h1, h2, h3, p) { margin: 0; }
.nrc-prose { max-width: 72ch; }
.nrc-prose > * + * { margin-top: 0.75rem; }
.nrc-prose h1 { font-size: 1.25rem; line-height: 1.25; }
.nrc-prose h2 { font-size: 1rem; line-height: 1.3; }
.nrc-prose h3 { font-size: 0.875rem; line-height: 1.3; }
.nrc-prose code, .nrc-prose pre { font-family: var(--nrc-font-mono); }
.nrc-prose pre { overflow-x: auto; }

/* Panels and headers */
.nrc-panel {
  min-width: 0;
  background: var(--doc-content);
}
.nrc-panel--framed { border: var(--nrc-panel-border); border-radius: var(--nrc-panel-radius); }
.nrc-panel-header {
  background: var(--doc-panel);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.375rem;
  min-height: 1.6rem;
  padding: 0.25rem 0.5rem;
  border-block: 1px solid var(--doc-rule);
  color: var(--nrc-text);
  font-family: var(--nrc-font-mono);
  font-size: 0.5625rem;
  font-weight: 700;
  line-height: 1.1;
  letter-spacing: 0.03125rem;
  text-transform: uppercase;
}
.nrc-panel-body { padding: 0.65rem; }
.nrc-dim { color: var(--nrc-text-dim); }

/* Control strips */
.nrc-controls {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.375rem;
}

/* Buttons */
.nrc-btn {
  appearance: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0.1875rem 0.5rem;
  border: var(--nrc-control-border);
  border-color: var(--nrc-text);
  border-radius: var(--nrc-control-radius);
  background: var(--doc-control);
  color: var(--nrc-text);
  box-shadow: 1px 1px 0 var(--nrc-border);
  font: 700 0.5625rem/1.3 var(--nrc-font-mono);
  text-transform: uppercase;
  cursor: pointer;
  user-select: none;
}
.nrc-btn:hover {
  background: var(--nrc-accent);
  color: var(--nrc-bg);
  border-color: var(--nrc-accent);
}
.nrc-btn:focus-visible {
  outline: 2px solid var(--nrc-accent);
  outline-offset: 2px;
}
.nrc-btn:active:not(:disabled):not([aria-pressed="true"]):not(.is-active):not([role="tab"]) { box-shadow: none; }
.nrc-btn[aria-pressed="true"], .nrc-btn.is-active {
  border-color: var(--nrc-border);
  background: transparent;
  color: var(--nrc-text);
  box-shadow: inset 0 -2px 0 var(--nrc-selected);
}
.nrc-btn--primary {
  background: var(--nrc-bg);
  border-color: var(--nrc-accent);
  color: var(--nrc-accent);
}
.nrc-btn--primary:hover {
  background: var(--nrc-text);
  border-color: var(--nrc-text);
  color: var(--nrc-bg);
}
.nrc-btn--danger {
  background: var(--nrc-surface);
  border-color: var(--nrc-danger);
  color: var(--nrc-danger);
}
.nrc-btn--danger:hover {
  background: var(--nrc-bg);
  border-color: var(--nrc-danger);
  color: var(--nrc-danger);
  box-shadow: inset 0 -2px 0 var(--nrc-danger);
}
.nrc-btn:disabled, .nrc-btn[aria-disabled="true"] {
  background: var(--nrc-surface);
  border-color: var(--nrc-border);
  color: var(--nrc-text-dim);
  opacity: 0.55;
  box-shadow: none;
  cursor: not-allowed;
  pointer-events: none;
}

/* Segmented tabs */
.nrc-tabs { display: inline-flex; align-items: stretch; gap: 0; }
.nrc-tabs .nrc-btn {
  margin: 0;
  padding: 0.375rem 0.6rem;
  border: 0;
  background: transparent;
  color: var(--nrc-text-dim);
  box-shadow: inset 0 -1px 0 var(--nrc-border);
  font-weight: 600;
  letter-spacing: 0.015625rem;
}
.nrc-tabs .nrc-btn:hover { background: var(--doc-panel); color: var(--nrc-text); }
.nrc-tabs .nrc-btn[aria-selected="true"] {
  background: transparent;
  color: var(--nrc-text);
  font-weight: 800;
  box-shadow: inset 0 -3px 0 var(--nrc-selected);
}

/* Labels and fields */
.nrc-field { display: grid; gap: 0.25rem; min-width: 0; }
.nrc-label {
  font-family: var(--nrc-font-mono);
  color: var(--nrc-text-dim);
  font-size: 0.5625rem;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
}
.nrc-input, .nrc-select, .nrc-textarea {
  width: 100%;
  min-height: 1.75rem;
  padding: 0.25rem 0.375rem;
  border: var(--nrc-panel-border);
  border-radius: var(--nrc-control-radius);
  background: var(--doc-content);
  color: var(--nrc-text);
  box-shadow: none;
  font: 0.6875rem/1.3 var(--nrc-font-mono);
}
.nrc-textarea { min-height: 5rem; resize: vertical; }
.nrc-input::placeholder, .nrc-textarea::placeholder { color: var(--nrc-text-dim); opacity: 1; }
.nrc-input:hover, .nrc-select:hover, .nrc-textarea:hover { border-color: var(--nrc-accent); }
.nrc-input:focus, .nrc-select:focus, .nrc-textarea:focus {
  border-color: var(--nrc-accent);
  outline: 1px solid var(--nrc-accent);
  outline-offset: 1px;
}
.nrc-input:disabled, .nrc-select:disabled, .nrc-textarea:disabled {
  color: var(--nrc-text-dim);
  opacity: 0.55;
  cursor: not-allowed;
}

/* Checkboxes */
.nrc-check {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  color: var(--nrc-text);
  font-family: var(--nrc-font-mono);
  font-size: 0.6875rem;
  font-weight: 700;
  text-transform: uppercase;
  cursor: pointer;
}
.nrc-check input {
  appearance: none;
  position: relative;
  width: 0.75rem;
  height: 0.75rem;
  margin: 0;
  flex: 0 0 auto;
  border: 1px solid var(--nrc-border);
  border-radius: 0;
  background: var(--nrc-bg);
}
.nrc-check input:checked::before, .nrc-check input:checked::after {
  content: "";
  position: absolute;
  top: 50%;
  left: 50%;
  width: 0.5rem;
  height: 1px;
  background: var(--nrc-text);
}
.nrc-check input:checked::before { transform: translate(-50%, -50%) rotate(45deg); }
.nrc-check input:checked::after { transform: translate(-50%, -50%) rotate(-45deg); }
.nrc-check input:hover, .nrc-check input:focus-visible {
  border-color: var(--nrc-accent);
  outline: 1px solid var(--nrc-accent);
  outline-offset: 1px;
}

/* Status labels */
.nrc-badge {
  display: inline-flex;
  align-items: center;
  min-height: 1.25rem;
  padding: 0.1rem 0.35rem;
  border: 1px solid var(--nrc-border);
  border-radius: 0;
  color: var(--nrc-text);
  background: var(--nrc-bg);
  font-family: var(--nrc-font-mono);
  font-size: 0.5625rem;
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}
.nrc-badge--active { border-color: var(--nrc-accent); color: var(--nrc-accent); }
.nrc-badge--selected { border-color: var(--nrc-selected); color: var(--nrc-selected); }
.nrc-badge--success { border-color: var(--nrc-success); color: var(--nrc-success); }
.nrc-badge--danger { border-color: var(--nrc-danger); color: var(--nrc-danger); }

/* Dense data tables */
.nrc-table-wrap { max-width: 100%; overflow-x: auto; }
.nrc-table { width: 100%; border-collapse: collapse; font-size: 0.6875rem; }
.nrc-table th, .nrc-table td {
  padding: 0.375rem 0.5rem;
  border-bottom: 1px solid var(--doc-rule);
  text-align: left;
  vertical-align: top;
}
.nrc-table tbody tr:last-child td { border-bottom: 0; }
.nrc-table th {
  background: var(--doc-panel);
  color: var(--nrc-text);
  font-family: var(--nrc-font-mono);
  font-size: 0.5625rem;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
}
/* Ordinary report rows are not interactive. Add state only to selectable rows. */
.nrc-table .is-selected {
  background: color-mix(in srgb, var(--nrc-bg) 85%, var(--nrc-selected));
  box-shadow: inset 3px 0 0 var(--nrc-selected);
  outline: 1px solid var(--nrc-accent);
  outline-offset: -1px;
}
.nrc-table .nrc-number { text-align: right; font-family: var(--nrc-font-mono); font-variant-numeric: tabular-nums; }
.nrc-disclosure > summary {
  padding: 0.375rem 0;
  font: 700 0.6875rem/1.3 var(--nrc-font-mono);
  cursor: pointer;
}
.nrc-disclosure > summary:hover { color: var(--nrc-accent); }
.nrc-disclosure > summary:focus-visible { outline: 2px solid var(--nrc-accent); outline-offset: 2px; }
.nrc-disclosure[open] > summary { box-shadow: inset 0 -2px 0 var(--nrc-selected); margin-bottom: 0.5rem; }

@media (max-width: 40rem) {
  .nrc-doc { font-size: 14px; }
  .nrc-panel-header { font-size: 11px; flex-wrap: wrap; }
  .nrc-label, .nrc-badge { font-size: 10px; }
  .nrc-btn, .nrc-check, .nrc-disclosure > summary { font-size: 11px; }
  .nrc-input, .nrc-select, .nrc-textarea { font-size: 16px; }
  .nrc-table { font-size: 14px; }
  .nrc-table th { font-size: 10px; }
  .nrc-controls { align-items: stretch; }
  .nrc-controls > .nrc-btn { flex: 1 1 auto; }
}
```

## Usage Rules

- In a script-enabled environment, use a real `<button type="button">`; do not style a `div` or `span` as a button. Do not put an inert button in a script-free NRC note.
- Use at most one primary action per panel or control strip.
- Use danger only for destructive, aborting, blocked, or fault actions—not ordinary emphasis.
- The stable aliases do not include production's theme-specific on-color foregrounds. Primary hover therefore uses neutral text/background inversion; danger hover retains its readable foreground and adds an underline. Do not fill a control with selected/danger color and assume ordinary text will contrast with it.
- In a script-enabled environment, a toggle button uses `aria-pressed` and a tab uses `role="tab"` plus `aria-selected`; the script must update those states. Static attributes do not implement interaction.
- In script-free NRC notes, use native `<details>` or checkbox/radio inputs with associated labels for persistent state. Do not add tab/button semantics to those controls unless their complete keyboard and ARIA behavior is implemented.
- Tabs touch with no gap and use an underline for selection, not a filled tile. Unrelated buttons retain the control-strip gap. The small offset edge belongs to ordinary actions, not tabs or row actions.
- Labels sit above text fields. Put units, limits, and validation state next to the label when relevant.
- Badges are compact textual state markers, never decorative pills.
- Tables carry comparison and record data; align numeric columns right with a local utility rule.
- Keep panel headers to one responsibility level. Use a second explicit row only when stable identity/state and local controls are genuinely separate. On phones, wrapping text is acceptable for document headings; a control register needs a deliberate stacked composition, not accidental wrapping.
- Do not introduce another button, field, badge, tab, panel, or table style in the same document unless it represents a distinct interaction contract.

## Minimal Script-Free Markup

```html
<section class="nrc-panel">
  <header class="nrc-panel-header"><span>01 / CONTROL</span><span class="nrc-badge nrc-badge--success">ONLINE</span></header>
  <div class="nrc-panel-body">
    <details class="nrc-disclosure">
      <summary>SHOW CURRENT STATE</summary>
      <p class="nrc-dim">The complete static state remains readable without scripts.</p>
    </details>
  </div>
</section>
```
