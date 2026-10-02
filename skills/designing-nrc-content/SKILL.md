---
name: designing-nrc-content
description: Designs HTML documents, dashboards, reports, diagrams, and visual artifacts in the NRC-300 interface language. Use when generating rich NRC content or when content should match NRC's dense, flat, technical UI, including work outside the NRC repository.
---

# Designing NRC Content

Creates self-contained visual content that feels native to NRC-300. This skill bundles the portable design contract; do not require access to the NRC repository or its interactive catalogue at authoring time.

## Design Direction

NRC is a functional technical instrument, not a generic web application or marketing surface.

- **Functional and dense:** prioritize diagrams, tables, measurements, labels, and explicit state. Use compact spacing and keep useful complexity visible.
- **Flat and spatial:** establish hierarchy with square-corner panels, rules, grids, alignment, and surface changes. Avoid gradients, glass effects, floating cards, large shadows, decorative illustrations, and gratuitous rounded containers.
- **Technical hierarchy:** use compact uppercase labels, numbered sections, and restrained type scales. Use mono for controls, metrics, identifiers, diagrams, and operational prose; use sans for longer reading when helpful.
- **Explicit state:** expose scope, counts, units, status, timestamps, assumptions, provenance, legends, and exceptional branches near the data they qualify. Prefer visible control strips to hidden menus when choices fit.
- **Semantic color:** begin with text and borders. Color reinforces a written state; it never replaces one.
- **Rendering:** use native HTML controls and CSS. Limit simultaneous animations and avoid script dependencies in note content.

Do not force all content into a dashboard. Ordinary prose should remain ordinary prose; use the NRC language when a document genuinely benefits from a technical interface, visualization, or report composition.

## Stable Theme Contract

For HTML rendered by NRC, use only these stable aliases:

- Surfaces: `--nrc-bg`, `--nrc-surface`
- Text: `--nrc-text`, `--nrc-text-dim`
- Structure: `--nrc-border`
- Interaction/state: `--nrc-accent`, `--nrc-selected`, `--nrc-success`, `--nrc-danger`
- Type: `--nrc-font-sans`, `--nrc-font-mono`
- Browser controls: `--nrc-color-scheme`

Meanings are fixed:

- `accent`: interaction, focus, active processing, or scanning
- `selected`: current choice, priority, or emphasized selection
- `success`: confirmed healthy or completed outcome
- `danger`: fault, blocked path, destructive action, or critical condition

Never hard-code theme colors unless a color represents immutable source data and remains legible in every theme. Never infer semantic meaning from the literal color a token currently resolves to.

When content will not run inside NRC, define these aliases at `:root` for the target environment while preserving their meanings. Do not replace them throughout component CSS with literal colors.

## Composition Baseline

Give each document root one unique ID plus the shared `nrc-doc` class, and scope document-specific CSS beneath that ID.

Before authoring controls or data surfaces, read `reference/primitives.md`. It defines the canonical portable CSS and markup for the document root, buttons, segmented tabs, labels, fields, checkboxes, badges, panels, control strips, and dense tables. Use those exact primitive rules by default instead of inventing a nearby variant. Change a primitive only when the content has a concrete requirement it cannot satisfy, and keep its semantic states intact.

Recommended composition patterns:

- Instrument header: identity/title on the left, concise state and provenance on the right
- Control strip: compact native controls with visible active and focus states
- Panel grid: bordered regions with indexed headers and clear responsibility
- Fact register: aligned value/unit/label cells, not decorative statistic cards
- Data table: explicit headers, units, comparison states, and local horizontal overflow
- Diagram: actors, lifelines, arrows, labels, branches, legend, and adjacent explanation
- Footer ledger: environment, source, timestamp, methodology, or limitations

## Responsive Behavior

Preserve the information model instead of hiding it:

- Stack panel grids at narrower widths.
- Wrap control strips deliberately without separating a control from its label.
- Put wide tables and diagrams in local `overflow-x: auto` containers.
- Use a readable minimum width for dense diagrams rather than compressing labels into collisions.
- Verify desktop and mobile composition, text overflow, focus visibility, and both light and dark themes.

## Script-Free Interaction And Motion

For script-free NRC HTML notes, use native `<details>` state or real checkbox/radio inputs with labels for disclosure, selection, filters, and CSS animation state. CSS can style existing native state but cannot update `aria-pressed`, `aria-selected`, or persistent button state.

- Keep controls labeled, compact, keyboard reachable, and visually explicit.
- Define visible `:focus-visible`, hover, checked, open, and disabled states.
- Do not render inert action buttons or script-dependent tabs in an NRC note. Reserve button toggles and `role="tab"` patterns for external environments that provide the required scripting and ARIA state updates.
- Offer play/pause or restart only when a native input pattern actually controls the animation; otherwise show the complete static result.
- Animate only a concept the document explains: data flow, sequence, scanning, progress, or state transition.
- Prefer transforms and opacity, bound simultaneous motion, and provide pause/play for repeating sequences.
- Ensure the static document communicates the complete result.
- Always include `@media (prefers-reduced-motion: reduce)` and remove nonessential animation there.

NRC notes run in a script-free sandbox. Inline HTML and CSS are supported; scripts, event handlers, forms, network requests, external assets, navigation, nested frames, storage, cookies, and parent NRC DOM access are blocked. Keep required styling inline and use `att:N` note attachments for images.

## Final Check

Before delivering generated content, verify:

1. Every panel, color, animation, and control communicates information.
2. State remains understandable without color or motion.
3. Semantic NRC aliases are used consistently.
4. Layout remains usable at desktop and mobile widths.
5. Repeating motion can pause and reduced-motion users receive a static result.
6. The content works without repository access, external fonts, scripts, or network resources.

The upstream interactive catalogue lives in the NRC repository at `client/design-system/index.html`, with production contracts in `client/css/main.css`. Consult it when available for current component implementation details, but this bundled contract is sufficient for authoring outside that repository.
