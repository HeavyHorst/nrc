const CACHE_NAME = "nrc-terminal-20261005metadata4";

const APP_SHELL = [
  "./",
  "./index.html",
  "./favicon.png",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/apple-touch-icon.png",
  "./manifest.webmanifest",
  "./css/main.css?v=20261005metadata4",
  "./css/foundation.css?v=20261005danger1",
  "./css/workspace.css?v=20261005metadata4",
  "./css/entities.css?v=20261005metadata1",
  "./css/ledger.css?v=20260926nesting2",
  "./css/mobile-tasks.css?v=20260928slice1",
  "./css/mobile.css?v=20260926nesting2",
  "./css/custom-select.css?v=20260926nesting1",
  "./dialog.js?v=20260925document17",
  "./portal.js?v=20260803a",
  "./custom-picker.js?v=20260927appointment2",
  "./custom-select.js?v=20260924select1",
  "./attachments.js?v=20260924attachment1",
  "./assets.js?v=20260927appointment1",
  "./transactions.js?v=20260925inline1",
  "./edges.js?v=20260924slicelive1",
  "./files.js?v=20260926resources2",
  "./links-ui.js?v=20260929prefetch1",
  "./inspector.js?v=20260929parallel1",
  "./view-manager.js?v=20260926calendar1",
  "./list-navigation.js?v=20260805b",
  "./virtual-list.js?v=20260908a",
  "./page-loader.js?v=20260924pager1",
  "./task-state.js?v=20260926calendar7",
  "./query-controller.js?v=20260914workspace1",
  "./task-search.js?v=20260917taskscroll1",
  "./detail-ui.js?v=20260927appointment2",
  "./column-resize.js?v=20260913tables2",
  "./tasks.js?v=20261005metadata1",
  "./attention.js?v=20260926why4",
  "./calendar.js?v=20260928atomic1",
  "./appointments.js?v=20260928appointment8",
  "./appointment-notify.js?v=20260927appointment2",
  "./reminder-notify.js?v=20260923attention7",
  "./task-query.js?v=20260927calendar8",
  "./slices.js?v=20261005danger1",
  "./note-html.js?v=20260901a",
  "./notes.js?v=20261001messages1",
  "./task-references.js?v=20260914workspace1",
  "./ai.js?v=20260924select1",
  "./retained-messages.js?v=20260902a",
  "./chat.js?v=20260923attention7",
  "./app.js?v=20260927appointment2",
  "./customers.js?v=20260926direction1",
  "./mobile-shell.js?v=20260914chats1",
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
