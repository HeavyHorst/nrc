(() => {
  const root = document.documentElement;
  const embedded = window.self !== window.top;
  const themeToggle = document.getElementById("themeToggle");
  const inventoryFilter = document.getElementById("inventoryFilter");
  const inventoryRows = [...document.querySelectorAll("#inventoryBody tr")];
  const inventoryCount = document.getElementById("inventoryCount");
  const themes = [
    "lupine",
    "matte-black",
    "tokyo-night",
    "ayu",
    "modus-vivendi",
    "catppuccin",
    "catppuccin-latte",
    "ethereal",
    "everforest",
    "flexoki-light",
    "forest-night",
    "gruvbox",
    "hackerman",
    "kanagawa",
    "last-horizon",
    "lumon",
    "miasma",
    "nord",
    "osaka-jade",
    "retro-82",
    "ristretto",
    "solitude",
    "rose-pine",
    "vantablack",
    "white",
  ];

  function resolvedColor(element) {
    const color = getComputedStyle(element).backgroundColor;
    const srgb = color.match(/^color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\)$/);
    if (!srgb) return color;

    const hex = srgb
      .slice(1)
      .map((channel) => Math.round(Number(channel) * 255).toString(16).padStart(2, "0"))
      .join("");
    return `#${hex}`;
  }

  function updateSwatches() {
    const styles = getComputedStyle(root);
    document.querySelectorAll("[data-token]").forEach((swatch) => {
      const token = swatch.dataset.token;
      const value = styles.getPropertyValue(token).trim();
      const colorSample = swatch.querySelector("i");
      colorSample.style.background = value;
      const displayedValue = value.startsWith("color-mix(") ? resolvedColor(colorSample) : value;
      swatch.querySelector("code").textContent = `${token} / ${displayedValue}`;
    });
  }

  function setTheme(theme) {
    root.dataset.theme = theme;
    const nextTheme = themes[(themes.indexOf(theme) + 1) % themes.length];
    themeToggle.textContent = `NEXT: ${nextTheme.toUpperCase()}`;
    themeToggle.setAttribute("aria-label", `Current theme: ${theme}. Switch to ${nextTheme}.`);
    document.querySelectorAll("[data-catalog-theme-status]").forEach((status) => {
      status.textContent = theme.toUpperCase();
    });
    if (!embedded) localStorage.setItem("nrc-design-system-theme", theme);
    updateSwatches();
    document.dispatchEvent(new CustomEvent("nrc:theme-changed", { detail: { theme } }));
  }

  themeToggle.addEventListener("click", () => {
    const currentIndex = themes.indexOf(root.dataset.theme);
    setTheme(themes[(currentIndex + 1) % themes.length]);
  });

  document.querySelectorAll("[data-mobile-filters]").forEach((button) => {
    button.addEventListener("click", () => {
      const open = button.closest(".panel-header").classList.toggle("mobile-filters-open");
      button.setAttribute("aria-expanded", String(open));
    });
  });

  document.querySelectorAll(".catalog-tabs .nav-tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      document.querySelectorAll(".catalog-tabs .nav-tab").forEach((item) => {
        item.classList.remove("active");
        item.setAttribute("aria-pressed", "false");
      });
      tab.classList.add("active");
      tab.setAttribute("aria-pressed", "true");
    });
  });

  document.querySelectorAll(".catalog-sidebar-demo .sidebar-nav-item").forEach((view) => {
    view.addEventListener("click", () => {
      document.querySelectorAll(".catalog-sidebar-demo .sidebar-nav-item").forEach((item) => {
        item.classList.remove("active");
        item.setAttribute("aria-pressed", "false");
      });
      view.classList.add("active");
      view.setAttribute("aria-pressed", "true");
    });
  });

  inventoryFilter.addEventListener("input", () => {
    const query = inventoryFilter.value.trim().toLowerCase();
    let visible = 0;
    inventoryRows.forEach((row) => {
      const matches = !query || row.textContent.toLowerCase().includes(query);
      row.hidden = !matches;
      if (matches) visible += 1;
    });
    inventoryCount.textContent = `${visible} / ${inventoryRows.length} VISIBLE`;
  });

  const htmlNoteHost = document.getElementById("catalogHtmlNote");
  if (htmlNoteHost && window.NRCHTMLNotes) {
    htmlNoteHost.append(window.NRCHTMLNotes.createFrame(`
      <!doctype html>
      <html><head><style>
        body { padding: 1rem; background: var(--nrc-bg); color: var(--nrc-text); }
        .plate { border: var(--nrc-panel-border); border-radius: var(--nrc-panel-radius); background: var(--nrc-surface); padding: 0.75rem; }
        h2 { margin: 0 0 0.5rem; color: var(--nrc-accent); }
        .status { display: inline-block; border: var(--nrc-control-border); border-radius: var(--nrc-control-radius); background: var(--nrc-bg); color: var(--nrc-selected); padding: 0.25rem 0.5rem; }
      </style></head><body><section class="plate"><h2>THEME-CONTROLLED DOCUMENT</h2><p>All colors and type come from the selected NRC theme.</p><span class="status">SANDBOX / STATIC HTML</span></section></body></html>
    `, "HTML note sandbox example"));
  }

  const params = new URLSearchParams(window.location.search);
  const requestedTheme = params.get("theme");
  const storedTheme = localStorage.getItem("nrc-design-system-theme");
  setTheme(
    themes.includes(requestedTheme)
      ? requestedTheme
      : themes.includes(storedTheme)
        ? storedTheme
        : themes[0],
  );
})();
