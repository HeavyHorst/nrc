# NRC Portable Primitive Contract

Use these primitives by default in generated NRC-styled HTML. They intentionally depend only on the stable `--nrc-*` theme aliases, so they work inside NRC notes without repository access.

Use the class names and declarations as written unless the content has a concrete requirement they cannot satisfy. Layout may compose primitives differently; do not restyle their visual states ad hoc.

## Canonical CSS

The document root should have a unique ID and the shared `nrc-doc` class:

```html
<div id="latency-report" class="nrc-doc">...</div>
```

```css
.nrc-doc {
  box-sizing: border-box;
  min-height: 100vh;
  margin: 0;
  background: var(--nrc-bg);
  color: var(--nrc-text);
  font: 0.75rem/1.45 var(--nrc-font-mono);
  letter-spacing: 0.02em;
}
.nrc-doc *, .nrc-doc *::before, .nrc-doc *::after { box-sizing: inherit; }
.nrc-doc h1, .nrc-doc h2, .nrc-doc h3, .nrc-doc p { margin: 0; }

/* Panels and headers */
.nrc-panel {
  min-width: 0;
  background: var(--nrc-bg);
  border: 1px solid var(--nrc-border);
}
.nrc-panel-header {
  background: var(--nrc-surface);
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 1.75rem;
  padding: 0.35rem 0.55rem;
  border-bottom: 1px solid var(--nrc-border);
  color: var(--nrc-text);
  font-size: 0.6875rem;
  font-weight: 700;
  line-height: 1.1;
  letter-spacing: 0.05em;
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
  min-height: 1.75rem;
  padding: 0.25rem 0.55rem;
  border: 1px solid var(--nrc-border);
  border-radius: 0;
  background: var(--nrc-bg);
  color: var(--nrc-text);
  box-shadow: none;
  font: 700 0.6875rem/1 var(--nrc-font-mono);
  letter-spacing: 0.04em;
  text-transform: uppercase;
  cursor: pointer;
  user-select: none;
}
.nrc-btn:hover {
  border-color: var(--nrc-accent);
  outline: 1px solid var(--nrc-accent);
  outline-offset: -2px;
}
.nrc-btn:focus-visible {
  border-color: var(--nrc-accent);
  outline: 1px solid var(--nrc-accent);
  outline-offset: 1px;
}
.nrc-btn[aria-pressed="true"], .nrc-btn.is-active {
  border-color: var(--nrc-selected);
  box-shadow: inset 0 -3px 0 var(--nrc-selected);
}
.nrc-btn--primary {
  border-color: var(--nrc-accent);
  color: var(--nrc-accent);
}
.nrc-btn--primary:hover, .nrc-btn--primary:focus-visible {
  box-shadow: inset 0 -3px 0 var(--nrc-accent);
}
.nrc-btn--danger {
  border-color: var(--nrc-danger);
  color: var(--nrc-danger);
}
.nrc-btn--danger:hover, .nrc-btn--danger:focus-visible {
  outline-color: var(--nrc-danger);
  box-shadow: inset 0 -3px 0 var(--nrc-danger);
}
.nrc-btn:disabled, .nrc-btn[aria-disabled="true"] {
  border-color: var(--nrc-border);
  color: var(--nrc-text-dim);
  opacity: 0.55;
  cursor: not-allowed;
  pointer-events: none;
}

/* Segmented tabs */
.nrc-tabs { display: inline-flex; align-items: stretch; gap: 0; }
.nrc-tabs .nrc-btn + .nrc-btn { margin-left: -1px; }
.nrc-tabs .nrc-btn[aria-selected="true"] {
  position: relative;
  z-index: 1;
  border-color: var(--nrc-text);
  background: var(--nrc-text);
  color: var(--nrc-bg);
  box-shadow: none;
}

/* Labels and fields */
.nrc-field { display: grid; gap: 0.25rem; min-width: 0; }
.nrc-label {
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
  border: 1px solid var(--nrc-border);
  border-radius: 0;
  background: var(--nrc-bg);
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
.nrc-table-wrap { max-width: 100%; overflow-x: auto; border: 1px solid var(--nrc-border); }
.nrc-table { width: 100%; border-collapse: collapse; font-size: 0.6875rem; }
.nrc-table th, .nrc-table td {
  padding: 0.375rem 0.5rem;
  border-right: 1px solid var(--nrc-border);
  border-bottom: 1px solid var(--nrc-border);
  text-align: left;
  vertical-align: top;
}
.nrc-table th:last-child, .nrc-table td:last-child { border-right: 0; }
.nrc-table tbody tr:last-child td { border-bottom: 0; }
.nrc-table th {
  background: var(--nrc-surface);
  color: var(--nrc-text);
  font-size: 0.5625rem;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
}
.nrc-table tbody tr:hover { box-shadow: inset 3px 0 0 var(--nrc-accent); }
.nrc-table .is-selected { box-shadow: inset 3px 0 0 var(--nrc-selected); }

@media (max-width: 40rem) {
  .nrc-panel-header { align-items: flex-start; }
  .nrc-controls { align-items: stretch; }
  .nrc-controls > .nrc-btn { flex: 1 1 auto; }
}
```

## Usage Rules

- In a script-enabled environment, use a real `<button type="button">`; do not style a `div` or `span` as a button. Do not put an inert button in a script-free NRC note.
- Use at most one primary action per panel or control strip.
- Use danger only for destructive, aborting, blocked, or fault actions—not ordinary emphasis.
- In a script-enabled environment, a toggle button uses `aria-pressed` and a tab uses `role="tab"` plus `aria-selected`; the script must update those states. Static attributes do not implement interaction.
- In script-free NRC notes, use native `<details>` or checkbox/radio inputs with associated labels for persistent state. Do not add tab/button semantics to those controls unless their complete keyboard and ARIA behavior is implemented.
- Tabs touch with no gap. Unrelated buttons retain the control-strip gap.
- Labels sit above text fields. Put units, limits, and validation state next to the label when relevant.
- Badges are compact textual state markers, never decorative pills.
- Tables carry comparison and record data; align numeric columns right with a local utility rule.
- Keep panel headers to one responsibility level. Use a second explicit row only when stable identity/state and local controls are genuinely separate.
- Do not introduce another button, field, badge, tab, panel, or table style in the same document unless it represents a distinct interaction contract.

## Minimal Script-Free Markup

```html
<section class="nrc-panel">
  <header class="nrc-panel-header"><span>01 / CONTROL</span><span class="nrc-badge nrc-badge--success">ONLINE</span></header>
  <div class="nrc-panel-body">
    <details>
      <summary>SHOW CURRENT STATE</summary>
      <p class="nrc-dim">The complete static state remains readable without scripts.</p>
    </details>
  </div>
</section>
```
