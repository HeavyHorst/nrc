# AGENTS.md - Client

## Project Overview
This is the NRC web client, an HTML/JavaScript interface to the Odin WebSocket
server. See `docs/DEVELOPMENT.md` for the complete development setup.

## Project Structure

### Core Files:
- `index.html` - Main HTML interface
- `app.js` - Client-side JavaScript WebSocket logic
- `tasks.js` - Kanban task management module
- `task-references.js` - Chat-to-task integration (task reference parsing and preview)
- `css/` - Stylesheets and visual assets

### Module Documentation:
- `TASK_REFERENCES.md` - Task reference feature (typing #123 in chat to reference tasks)

## Development Commands

### Serving the client:
```bash
# Simple HTTP server (Python 3)
python -m http.server 8000

# Or with Node.js (if http-server is installed)
npx http-server -p 8000

# Or with any other static file server
```

### Production client:
```bash
# From the repository root; Docker Compose also builds this into the Nginx image.
npm ci --prefix client
npm run build --prefix client
npm run test:build --prefix client
node client/build/production.e2e.mjs
```
Serve `client/dist/` in production. Never hand-edit its generated CSS/font/script assets or
service worker. Local classic scripts are minified in groups that preserve shared globals
and execution boundaries; source development remains unbundled.

### Testing WebSocket connection:
- The browser connects to its serving origin, with the workspace as URL path.
- Use the auth proxy or a disposable authenticated fixture; serving static files
  alone does not supply a JWT for a direct connection to the Odin server.

### Verification scope:
- For frontend-only changes, run `node --test client/*.test.mjs` from the repository root plus any
  targeted browser check needed for the affected behavior. Do not run the complete repository test
  matrix unless the change also affects server or protocol behavior, or the user explicitly requests it.

## Architecture Notes

- **Client-side only**: Static HTML/CSS/JavaScript in development; production builds CSS/fonts/classic scripts with `build.mjs`
- **WebSocket connection**: Connects to the Odin server on port 8080
- **Real-time communication**: Handles WebSocket messages and connection lifecycle

## PWA Cache Updates

The service worker uses a versioned, cache-first application shell. Every frontend change that
affects a file listed in `APP_SHELL` in `service-worker.js` must update the PWA cache contract in the
same change:

1. For a versioned CSS or JavaScript asset, bump its `?v=` value in `index.html`.
2. Apply the identical URL and `?v=` value to its entry in `APP_SHELL`.
3. Bump `CACHE_NAME` in `service-worker.js` (use a new date/revision suffix).
4. Add new shell dependencies to `APP_SHELL`, and remove entries for deleted dependencies. Keep
   changed third-party URLs synchronized with `EXTERNAL_SHELL`.
5. Run `node --test client/pwa.test.mjs` and `node --check client/service-worker.js`.

Bump `CACHE_NAME` for HTML-only shell changes too, so a newly installed worker refreshes the offline
copy of `index.html`. A currently open page does not hot-reload when a new worker activates; the new
assets appear after the next page reload. Do not rely on Nginx's `no-cache` headers alone: previously
cached shell assets are deliberately served cache-first by the service worker.

## Code Style Conventions

- **JavaScript**: Use modern ES6+ features
- **Naming**: camelCase for JavaScript variables and functions
- **Error handling**: Proper WebSocket connection error handling
- **Logging**: Use console.log for debugging, structured logging preferred

## Adding New Commands

When adding a new command to `COMMANDS` array in `app.js`:
1. Add the command entry with `cmd`, `alias`, `desc`, and `group` fields
2. **IMPORTANT**: Add the new group name to the `groupOrder` array in the autocomplete rendering function (search for `groupOrder`), otherwise the command won't appear in autocomplete

## Design System

The client shares components and theme tokens across its workspace views.

- **Philosophy**: Functionalism, high density, explicit state. No decorative elements.
- **Catalogue**: `design-system/index.html`, served at `/design-system/` during local development.
- **Source of truth**: `css/main.css` is the production entry point. Tokens live in `css/foundation.css`; shell/shared controls in `css/workspace.css`; entity views in `css/entities.css`; chat and shared header registers in `css/ledger.css`; phone compositions in `css/mobile.css` and `css/mobile-tasks.css`. Preserve cascade order when moving rules. `design-system/catalog.css` is for catalogue layout only.
- **Themes**: Themes use the semantic tokens defined in `css/foundation.css`. Do not introduce hard-coded production colors or undefined token aliases. Reuse its `--mobile-font-*` scale for shared phone typography; keep input text at 16px rather than inheriting desktop root-size scaling.
- **Catalogue assets**: Keep production stylesheet URLs and cache versions identical in `index.html` and `design-system/index.html` (apart from the relative path prefix).
- **HTML notes**: Self-contained HTML/CSS note payloads render in the script-free sandbox implemented by `note-html.js`. Authored note HTML should use the stable `--nrc-*` variables documented in `../skills/maintaining-room-memory/reference/operations.md`. Do not weaken the iframe sandbox or CSP, enable scripts, add navigation capabilities, or expose application state to note content.

Before adding or changing UI functionality:

1. Inspect the catalogue and complete inventory for an existing component family or interaction contract.
2. Reuse the existing production classes, semantic tokens, controls, and state vocabulary before creating a new variant.
3. If a genuinely new family or contract is required, add or update its catalogue example and inventory entry in the same change.
4. Catalogue examples must use production markup and production CSS. Do not recreate component appearance in `design-system/catalog.css`.
5. Validate affected UI in both themes and at representative desktop and mobile widths. Check state visibility, overflow, and focused/share layouts where relevant.

Treat divergence between the catalogue and production as a bug. Do not use an existing local hard-coded style as precedent merely because it predates the catalogue.

## Header Conventions

Use the shared `panel-header` class for panel/topbar-style section headers (memo, AI portals, and future panel headers). Do not create one-off header styling unless there is a strong product reason.

- **Shared header class**: `panel-header` (base in `css/workspace.css`, register contracts in `css/ledger.css`)
- **Structure**: A standard `panel-header` contains one direct child `div`. Inspector headers contain two direct rows: `inspector-identity-row` and `inspector-mode-row`.
- **Row rule**: Use one row for one responsibility level. Use two rows only when stable identity/system state must remain separate from local modes, navigation, and object actions.
- **Responsive behavior**: Lack of space must not create a semantic second row through wrapping; compact controls or use the mobile panel composition instead.
- **Header row content**: Prefer `span` elements for title/meta tokens and existing `.btn` variants for actions
- **Standardization rule**: Panel-like section headers in any view should reuse `panel-header` + inner row `div` by default; avoid introducing alternate header base classes for similar UI regions
- **Close control**: Use existing close styling (`btn btn--danger task-detail-close`) for close `×` actions in header rows
- **Typography/layout**: Keep uppercase labels, compact height, and border treatment inherited from `panel-header`
- **Avoid**: New bespoke header color schemes for standard panels when `panel-header` can be reused

## Server Integration

This client connects to the parent Odin WebSocket server located at `../`:
- **Server build**: `cd .. && odin build . -out:server`
- **Server run**: `cd .. && odin run .`
- **Default connection**: WebSocket server on `localhost:8080`
