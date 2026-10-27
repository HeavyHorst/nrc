const CACHE_NAME = "nrc-terminal-20261027columns3";

const APP_SHELL = [
  "./",
  "./index.html",
  "./favicon.png",
  "./favicon.png?v=20261013fold1",
  "./favicon.ico?v=20261013fold1",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/apple-touch-icon.png",
  "./icons/apple-touch-icon.png?v=20261013fold1",
  "./manifest.webmanifest",
  "./css/main.css?v=20261027columns3",
  "./css/foundation.css?v=20261020fill2",
  "./css/workspace.css?v=20261023attachment1",
  "./css/entities.css?v=20261023attachment1",
  "./css/ledger.css?v=20261023chatgroup2",
  "./css/mobile-tasks.css?v=20261019registers1",
  "./css/mobile.css?v=20261021taskslice1",
  "./css/custom-select.css?v=20261019compact1",
  "./dialog.js?v=20261021taskslice1",
  "./portal.js?v=20261021modal1",
  "./custom-picker.js?v=20260927appointment2",
  "./custom-select.js?v=20261019customerwidth1",
  "./attachments.js?v=20261008files1",
  "./protocol.js?v=20261023protocol2",
  "./frames.js?v=20261023protocol2",
  "./assets.js?v=20261023protocol2",
  "./transactions.js?v=20261023protocol2",
  "./edges.js?v=20261023protocol2",
  "./files.js?v=20261022cancel1",
  "./links-ui.js?v=20261018ticketregister1",
  "./inspector.js?v=20261019recurrence1",
  "./view-manager.js?v=20261017history5",
  "./list-navigation.js?v=20260805b",
  "./virtual-list.js?v=20260908a",
  "./loading-indicator.js?v=20261013loading1",
  "./page-loader.js?v=20261013loading1",
  "./task-state.js?v=20261020people1",
  "./query-controller.js?v=20260914workspace1",
  "./workspace-search.js?v=20261018inspectors5",
  "./task-search.js?v=20260917taskscroll1",
  "./detail-ui.js?v=20261022cancel1",
  "./column-resize.js?v=20261027columns3",
  "./record-activity.js?v=20261019ticketpages1",
  "./tasks.js?v=20261027columns3",
  "./attention.js?v=20261019followupattention1",
  "./calendar.js?v=20261023protocol2",
  "./appointments.js?v=20261022cancel1",
  "./appointment-notify.js?v=20261019recurrence1",
  "./reminder-notify.js?v=20260923attention7",
  "./task-query.js?v=20261023protocol2",
  "./slices.js?v=20261023protocol2",
  "./overview.js?v=20261023protocol2",
  "./history.js?v=20261023protocol2",
  "./note-html.js?v=20261007fragments1",
  "./notes.js?v=20261027columns2",
  "./task-references.js?v=20260914workspace1",
  "./ai.js?v=20261027sources1",
  "./retained-messages.js?v=20261023protocol2",
  "./chat.js?v=20261020composer1",
  "./app.js?v=20261027sources1",
  "./calls.js?v=20261022cancel1",
  "./newsletter.js?v=20261022cancel1",
  "./customers.js?v=20261022cancel1",
  "./tickets.js?v=20261027columns2",
  "./mobile-shell.js?v=20261019registers1",
  "./latency-worker.js",
];

const EXTERNAL_SHELL = [
  "https://fonts.googleapis.com/css2?family=Inter:opsz,wght@14..32,100..900&family=IBM+Plex+Mono:wght@400;500;700&display=swap",
  "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css",
  "https://cdn.jsdelivr.net/npm/marked@16.1.1/lib/marked.umd.js",
  "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js",
  "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js",
  "https://cdn.jsdelivr.net/npm/dompurify@3/dist/purify.min.js",
  "https://cdn.jsdelivr.net/npm/@oneidentity/zstd-js@1.0.3/asm/index.umd.js",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(async (cache) => {
      await cache.addAll(APP_SHELL);
      // These CDNs support CORS. Cache.add rejects opaque responses; requiring
      // successful fetches also keeps the previous worker if a CDN is unavailable.
      await Promise.all(
        EXTERNAL_SHELL.map((url) => cache.add(new Request(url, { mode: "cors" }))),
      );
    }),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) =>
        Promise.all(
          names
            .filter(
              (name) =>
                name.startsWith("nrc-terminal-") && name !== CACHE_NAME,
            )
            .map((name) => caches.delete(name)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  const url = new URL(event.request.url);

  if (event.request.mode === "navigate") {
    event.respondWith(
      fetch(event.request).catch(() =>
        caches.open(CACHE_NAME).then((cache) => cache.match("./index.html")),
      ),
    );
    return;
  }

  const isAppShellRequest =
    url.origin === self.location.origin &&
    APP_SHELL.some(
      (path) => new URL(path, self.registration.scope).href === url.href,
    );
  const isExternalShellRequest =
    EXTERNAL_SHELL.includes(url.href) || url.hostname === "fonts.gstatic.com";

  if (!isAppShellRequest && !isExternalShellRequest) return;

  event.respondWith(
    caches.open(CACHE_NAME).then(async (cache) => {
      const cached = await cache.match(event.request);
      if (cached) return cached;

      return fetch(event.request).then((response) => {
        if (response.ok || response.type === "opaque") {
          // Keep this handle: reopening by name after activation cleanup can
          // recreate an obsolete cache while a previous worker finishes a fetch.
          event.waitUntil(cache.put(event.request, response.clone()));
        }
        return response;
      });
    }),
  );
});
