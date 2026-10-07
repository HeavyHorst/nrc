// =============================================================================
// NRC HTML NOTES
// =============================================================================
// HTML notes run in a script-free sandboxed iframe. The iframe receives
// only NRC's semantic theme tokens and parent-created attachment blob URLs; it
// cannot access NRC state, storage, forms, or network APIs. The parent handles
// local fragment jumps and opens HTTP(S) links in isolated tabs on user clicks.

(function initHTMLNotes(global) {
  "use strict";

  const THEME_TOKENS = [
    "--bg-primary",
    "--bg-secondary",
    "--surface-1",
    "--surface-2",
    "--bg-hover",
    "--bg-header",
    "--border-primary",
    "--border-light",
    "--border-subtle",
    "--border-strong",
    "--surface-panel",
    "--surface-control",
    "--panel-border",
    "--control-border",
    "--panel-radius",
    "--control-radius",
    "--panel-shadow",
    "--control-shadow",
    "--text-primary",
    "--text-dim",
    "--text-muted",
    "--text-header",
    "--link-text",
    "--link-hover-bg",
    "--link-hover-text",
    "--accent-interactive",
    "--accent-current",
    "--accent-selected",
    "--accent-danger",
    "--accent-success",
    "--accent-priority",
    "--identity-scope",
    "--identity-actor",
    "--identity-reference",
    "--identity-artifact",
    "--font-sans",
    "--font-mono",
  ];

  const TOKEN_ALIASES = {
    "--nrc-bg": "--bg-primary",
    "--nrc-surface": "--surface-2",
    "--nrc-text": "--text-primary",
    "--nrc-text-dim": "--text-dim",
    "--nrc-border": "--border-primary",
    "--nrc-panel-border": "--panel-border",
    "--nrc-control-border": "--control-border",
    "--nrc-panel-radius": "--panel-radius",
    "--nrc-control-radius": "--control-radius",
    "--nrc-accent": "--accent-interactive",
    "--nrc-selected": "--accent-selected",
    "--nrc-danger": "--accent-danger",
    "--nrc-success": "--accent-success",
    "--nrc-font-sans": "--font-sans",
    "--nrc-font-mono": "--font-mono",
  };

  const SVG_ANIMATION_ELEMENTS = new Set([
    "animate",
    "animatemotion",
    "animatetransform",
    "discard",
    "set",
  ]);

  const BASE_STYLES = `
    html { color-scheme: var(--nrc-color-scheme); background: var(--nrc-bg); }
    body {
      box-sizing: border-box;
      min-height: 100vh;
      margin: 0;
      background: var(--nrc-bg);
      color: var(--nrc-text);
      font-family: var(--nrc-font-sans);
    }
    *, *::before, *::after { box-sizing: inherit; }
    *::-webkit-scrollbar { width: 0.375rem; height: 0.375rem; cursor: auto; }
    *::-webkit-scrollbar-track { background: var(--nrc-bg); cursor: auto; }
    *::-webkit-scrollbar-thumb { background: var(--nrc-border); cursor: auto; }
    a { color: var(--link-text); }
    code, pre, kbd, samp { font-family: var(--nrc-font-mono); }
    img, svg, video, canvas { max-width: 100%; }
  `;

  function normalizeFormat(format) {
    return String(format || "").toLowerCase() === "html" ? "html" : "markdown";
  }

  function getThemeSnapshot() {
    const root = document.documentElement;
    const computed = getComputedStyle(root);
    const tokens = {};
    for (const name of THEME_TOKENS) {
      tokens[name] = computed.getPropertyValue(name).trim();
    }
    for (const [alias, source] of Object.entries(TOKEN_ALIASES)) {
      tokens[alias] = tokens[source];
    }
    const colorScheme = computed.colorScheme.includes("dark") ? "dark" : "light";
    tokens["--nrc-color-scheme"] = colorScheme;
    return {
      theme: root.getAttribute("data-theme") || colorScheme,
      tokens,
    };
  }

  function themeCSS(snapshot) {
    const declarations = Object.entries(snapshot.tokens)
      .map(([name, value]) => `${name}:${value};`)
      .join("");
    return `:root{${declarations}}${BASE_STYLES}`;
  }

  function fragmentTarget(doc, href) {
    if (!href || !href.startsWith("#")) return null;
    try {
      return Document.prototype.getElementById.call(doc, decodeURIComponent(href.slice(1)));
    } catch {
      return null;
    }
  }

  function webURL(href) {
    try {
      const url = new URL(href);
      return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
    } catch {
      return null;
    }
  }

  function buildSource(source) {
    const parsed = new DOMParser().parseFromString(String(source || ""), "text/html");
    parsed.querySelectorAll("base, meta[http-equiv], script, form, iframe, frame, object, embed").forEach((node) => node.remove());
    parsed.querySelectorAll("*").forEach((node) => {
      if (node.namespaceURI === "http://www.w3.org/2000/svg" && SVG_ANIMATION_ELEMENTS.has(node.localName.toLowerCase())) {
        node.remove();
        return;
      }
      for (const attribute of Array.from(node.attributes)) {
        if (attribute.name.toLowerCase().startsWith("on") || attribute.name === "data-nrc-note-href") {
          node.removeAttributeNode(attribute);
        }
      }
    });
    parsed.querySelectorAll("*").forEach((node) => {
      for (const attribute of Array.from(node.attributes)) {
        if (attribute.localName !== "href") continue;
        const allowedLink = node.namespaceURI === "http://www.w3.org/1999/xhtml"
          && node.localName === "a" && attribute.name === "href"
          && (fragmentTarget(parsed, attribute.value) || webURL(attribute.value));
        // No native navigation is possible while resources delay iframe load.
        // Restore validated hrefs only after the parent installs its handlers.
        if (allowedLink) node.setAttribute("data-nrc-note-href", attribute.value);
        node.removeAttributeNode(attribute);
      }
      // Authored links cannot choose their browsing context or trigger downloads
      // or tracking pings. The parent owns all link activation.
      node.removeAttribute("target");
      node.removeAttribute("download");
      node.removeAttribute("ping");
    });

    const csp = parsed.createElement("meta");
    csp.httpEquiv = "Content-Security-Policy";
    csp.content = [
      "default-src 'none'",
      "img-src data: blob:",
      "media-src data: blob:",
      "style-src 'unsafe-inline'",
      "script-src 'none'",
      "font-src data:",
      "connect-src 'none'",
      "frame-src 'none'",
      "object-src 'none'",
      "form-action 'none'",
      "base-uri 'none'",
    ].join("; ");
    parsed.head.prepend(csp);

    const snapshot = getThemeSnapshot();
    parsed.documentElement.dataset.theme = snapshot.theme;
    const themeStyle = parsed.createElement("style");
    themeStyle.dataset.nrcTheme = "";
    themeStyle.textContent = themeCSS(snapshot);
    parsed.head.append(themeStyle);
    return `<!doctype html>\n${parsed.documentElement.outerHTML}`;
  }

  function createFrame(source, title = "HTML note") {
    const frame = document.createElement("iframe");
    frame.className = "note-html-frame";
    frame.title = title;
    // allow-same-origin is required for reliable srcdoc rendering in Chromium.
    // It is safe here because scripts, event handlers, navigation, forms, and
    // embedded browsing contexts are removed or blocked.
    frame.setAttribute("sandbox", "allow-same-origin");
    frame.setAttribute("referrerpolicy", "no-referrer");
    frame.addEventListener("load", () => {
      const doc = frame.contentDocument;
      // srcdoc inherits the parent's base URL. Handle fragments locally rather
      // than letting the browser navigate to that URL inside the note frame.
      const activateLink = (event) => {
        if (event.type === "auxclick" && event.button !== 1) return;
        const link = event.target.closest?.("a[href]");
        if (!link) return;
        event.preventDefault();
        const href = link.getAttribute("href");
        const target = fragmentTarget(doc, href);
        if (target) {
          if (event.type === "click") target.scrollIntoView();
        } else {
          const url = webURL(href);
          if (url) global.open(url, "_blank", "noopener,noreferrer");
        }
      };
      // Named images in authored HTML can shadow Document methods.
      EventTarget.prototype.addEventListener.call(doc, "click", activateLink);
      EventTarget.prototype.addEventListener.call(doc, "auxclick", activateLink);
      Document.prototype.querySelectorAll.call(doc, "a[data-nrc-note-href]").forEach((link) => {
        link.setAttribute("href", link.getAttribute("data-nrc-note-href"));
        link.removeAttribute("data-nrc-note-href");
      });
    });
    frame._nrcHTMLNoteSource = String(source || "");
    frame._nrcHTMLNoteBlobURLs = [];
    frame.srcdoc = buildSource(frame._nrcHTMLNoteSource);
    return frame;
  }

  function updateFrame(frame, source, blobURLs = []) {
    if (!frame) return;
    for (const url of frame._nrcHTMLNoteBlobURLs || []) URL.revokeObjectURL(url);
    frame._nrcHTMLNoteBlobURLs = blobURLs;
    frame._nrcHTMLNoteSource = String(source || "");
    frame.srcdoc = buildSource(frame._nrcHTMLNoteSource);
  }

  function refreshThemes() {
    document.querySelectorAll("iframe.note-html-frame").forEach((frame) => {
      frame.srcdoc = buildSource(frame._nrcHTMLNoteSource);
    });
  }

  document.addEventListener("nrc:theme-changed", refreshThemes);
  document.addEventListener("nrc:appearance-changed", refreshThemes);

  new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      for (const removed of mutation.removedNodes) {
        const frames = removed.matches?.("iframe.note-html-frame")
          ? [removed]
          : Array.from(removed.querySelectorAll?.("iframe.note-html-frame") || []);
        for (const frame of frames) {
          for (const url of frame._nrcHTMLNoteBlobURLs || []) URL.revokeObjectURL(url);
          frame._nrcHTMLNoteBlobURLs = [];
        }
      }
    }
  }).observe(document.documentElement, { childList: true, subtree: true });

  global.NRCHTMLNotes = {
    normalizeFormat,
    getThemeSnapshot,
    buildSource,
    createFrame,
    updateFrame,
    refreshThemes,
  };
})(window);
