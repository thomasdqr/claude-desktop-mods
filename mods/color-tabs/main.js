// Color Tabs: turns each project in Claude's sidebar into a colored block, like tab
// groups in Arc, with a Lucide icon picker, a session limit with "Show more", and an
// animation while a session runs. Scheduled routines can get a block of their own.
//
// Rows read the app's own --df-row-* and --df-hover / --df-selected variables,
// so each section overrides those instead of restyling rows one by one.
function activate(api) {
  const { sidebar } = api;
  const icons = api.assets.icons;
  const VISIBLE_ROWS = api.settings.visibleRows;
  const ANIMATION = api.settings.runningAnimation;
  const ORBIT_DASH = 84;
  const ORBIT_SPEED = 210; // px per second
  const ORBIT_RADIUS = 11.25;
  const PROJECT_LOOK = { color: "#9AA3AE", icon: "folder" };
  // Clay, Claude's own color, for what Claude runs on its own.
  const ROUTINES_LOOK = { color: "#D97757", icon: "calendar-clock" };
  const PALETTE = [
    "#F0609E", "#E5484D", "#F08A3C", "#F5B83D", "#D4D96A", "#3DBE7A",
    "#6FC2B4", "#5BC0F8", "#4F86F7", "#A07CF0", "#C8915F", "#9AA3AE",
  ];
  const ATTRIBUTES = [
    "data-ct-section", "data-ct-expanded", "data-ct-title", "data-ct-name", "data-ct-rows", "data-ct-running", "data-ct-routines",
  ];
  const LEADING_EMOJI = /^[^\p{L}\p{N}]+/u;
  const displayName = (label) => label.replace(LEADING_EMOJI, "").trim();
  const keyOf = (label) => displayName(label).toLowerCase();

  // Picker choices win over the settings, project by project. Before it was a mod,
  // Claude Colors kept them under its own key.
  const legacy = JSON.parse(localStorage.getItem("claude-colors") || "null")?.projects;
  const saved = api.storage.get("projects") ?? legacy ?? {};
  const projects = new Map(
    Object.entries({ ...api.settings.projects, ...saved }).map(([name, project]) => [keyOf(name), { ...project, name }])
  );
  const expanded = new Set();
  let picker = null;

  // How a block shows a running session. "orbit", the moving light, is drawn by
  // stepOrbits below; the others are CSS on [data-ct-running].
  const RUNNING_CSS = {
    pulse: `
      @keyframes ct-pulse {
        50% { box-shadow: inset 0 0 0 1.5px color-mix(in srgb, var(--ct-accent) 75%, transparent),
                          0 0 12px color-mix(in srgb, var(--ct-accent) 30%, transparent); }
      }
      @media (prefers-reduced-motion: no-preference) {
        [data-ct-section][data-ct-running] { animation: ct-pulse 2.4s ease-in-out infinite; }
      }
      @media (prefers-reduced-motion: reduce) {
        [data-ct-section][data-ct-running] { box-shadow: inset 0 0 0 1.5px color-mix(in srgb, var(--ct-accent) 60%, transparent); }
      }`,
    dot: `
      @keyframes ct-ping { to { box-shadow: 0 0 0 6px transparent; } }
      [data-ct-running] [data-ct-badge] { position: relative; }
      [data-ct-running] [data-ct-badge]::after {
        content: ""; position: absolute; top: -2px; right: -2px; width: 7px; height: 7px; border-radius: 50%;
        background: var(--ct-accent); box-shadow: 0 0 0 0 color-mix(in srgb, var(--ct-accent) 60%, transparent);
      }
      @media (prefers-reduced-motion: no-preference) {
        [data-ct-running] [data-ct-badge]::after { animation: ct-ping 1.4s ease-out infinite; }
      }`,
  };

  api.css(`
    .df-sortable-section:has(> [data-ct-section]) { margin: 0 0 6px !important; }

    [data-ct-section] {
      --ct-text: color-mix(in oklab, var(--ct-accent) 72%, currentColor);
      --ct-soft-text: color-mix(in oklab, var(--ct-accent) 28%, currentColor);
      --df-row-font: 13px;
      --df-row-h: 28px;
      --df-group-pt: 0px;
      --df-hover: color-mix(in srgb, var(--ct-accent) 16%, transparent);
      --df-selected: color-mix(in srgb, var(--ct-accent) 26%, transparent);
      /* Concentric corners: an inner radius is the outer one minus the gap between them. */
      --ct-radius: 12px;
      --ct-padding: 3px;
      --ct-inner-radius: calc(var(--ct-radius) - var(--ct-padding));
      --df-radius-pill: var(--ct-inner-radius);
      gap: 1px !important; margin: 0 !important; padding: var(--ct-padding);
      border-radius: var(--ct-radius);
      background: color-mix(in srgb, var(--ct-accent) 11%, transparent);
      box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--ct-accent) 14%, transparent);
    }
    [data-ct-section] [data-gap-after] { margin-top: 0 !important; }
    /* Routines aren't in a .df-sortable-section, so their block spaces itself. */
    [data-ct-section][data-ct-routines] { margin: 0 0 6px !important; }

    ${RUNNING_CSS[ANIMATION] ?? ""}
    [data-ct-orbit] {
      position: absolute; inset: 0; width: 100%; height: 100%; z-index: 1;
      pointer-events: none; overflow: visible;
      filter: drop-shadow(0 0 3px var(--ct-accent));
    }
    [data-ct-orbit] rect {
      x: 0.75px; y: 0.75px; width: calc(100% - 1.5px); height: calc(100% - 1.5px); rx: calc(var(--ct-radius) - 0.75px);
      fill: none; stroke: var(--ct-accent); stroke-width: 1.5px; stroke-linecap: round;
      stroke-dasharray: 0 100000;
    }
    @media (prefers-reduced-motion: reduce) {
      [data-ct-orbit] rect { stroke-dasharray: none; opacity: 0.6; }
    }
    [data-ct-section] [data-sidebar-group-label] {
      min-height: 32px; margin-block: 0 !important; padding-block: 0 !important; padding-inline-start: var(--ct-padding); border-radius: var(--ct-inner-radius);
    }
    [data-ct-section] [data-sidebar-group-label]:hover { background: var(--df-hover); }

    [data-ct-title] {
      display: inline-flex !important; align-items: center; gap: 8px; min-width: 0;
      font-size: 13px !important; font-weight: 600 !important; color: var(--ct-text) !important;
    }
    [data-ct-title] > :not([data-ct-badge]) { display: none !important; }
    [data-ct-title]::after { content: attr(data-ct-name); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    [data-ct-badge] {
      display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0;
      width: 22px; height: 22px; border-radius: calc(var(--ct-inner-radius) - var(--ct-padding)); cursor: pointer;
      color: var(--ct-text);
      background: color-mix(in srgb, var(--ct-accent) 26%, transparent);
    }
    [data-ct-badge]:hover { background: color-mix(in srgb, var(--ct-accent) 40%, transparent); }
    [data-ct-badge] svg { width: 14px; height: 14px; }

    /* The app spaces rows with a margin below each; above each keeps the last row flush with the block's padding. */
    [data-ct-section] [data-row] { border-radius: var(--ct-inner-radius) !important; margin: 2px 0 0 !important; }
    [data-ct-section] [data-row-main-button] { color: var(--ct-soft-text) !important; font-weight: 400 !important; }
    [data-ct-section] [data-row][data-selected] [data-row-main-button],
    [data-ct-section] [data-row-main-button]:hover { color: var(--ct-text) !important; }
    /* Pure CSS, so rows the app adds while unfolding a block are hidden before they're painted. */
    [data-ct-section]:not([data-ct-expanded]) [data-ct-rows] > :nth-child(n + ${VISIBLE_ROWS + 1}):not([data-ct-more]) {
      display: none !important;
    }

    [data-ct-more] {
      all: unset; box-sizing: border-box; display: flex; align-items: center; gap: 6px; width: 100%;
      height: 26px; margin-top: 2px; padding: 0 var(--df-row-px, 10px); border-radius: var(--ct-inner-radius); cursor: pointer;
      font-size: 12px; color: var(--ct-soft-text); opacity: 0.75;
    }
    [data-ct-more]:hover { opacity: 1; background: var(--df-hover); }
    [data-ct-more] svg { width: 13px; height: 13px; }

    [data-ct-picker] {
      position: fixed; z-index: 2147483647; width: 320px; padding: 12px; box-sizing: border-box;
      border-radius: 12px; font: 13px system-ui, sans-serif;
      background: var(--cds-surface-2, var(--cds-surface-1, #262624)); color: var(--cds-text-primary, #ecebe4);
      border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
      box-shadow: 0 12px 32px rgba(0, 0, 0, 0.35);
    }
    [data-ct-picker] input[type=search] {
      width: 100%; box-sizing: border-box; padding: 6px 8px; border-radius: 8px; font: inherit; color: inherit;
      background: color-mix(in srgb, currentColor 8%, transparent); border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
    }
    [data-ct-picker] [data-ct-grid] {
      display: grid; grid-template-columns: repeat(8, 1fr); gap: 4px; margin: 10px 0;
      max-height: 200px; overflow-y: auto;
    }
    [data-ct-picker] button {
      all: unset; display: flex; align-items: center; justify-content: center; cursor: pointer; border-radius: 7px;
    }
    [data-ct-grid] button { height: 32px; color: var(--ct-pick); }
    [data-ct-grid] button:hover, [data-ct-grid] button[data-selected] { background: color-mix(in srgb, var(--ct-pick) 22%, transparent); }
    [data-ct-grid] svg { width: 18px; height: 18px; }
    [data-ct-swatches] { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
    [data-ct-swatches] button { width: 20px; height: 20px; border-radius: 50%; }
    [data-ct-swatches] button[data-selected] { box-shadow: 0 0 0 2px var(--cds-surface-1, #1f1f1e), 0 0 0 4px currentColor; }
    [data-ct-swatches] input { width: 24px; height: 24px; padding: 0; border: none; background: none; cursor: pointer; }
    [data-ct-footer] { display: flex; justify-content: space-between; margin-top: 10px; opacity: 0.7; font-size: 12px; }
    [data-ct-footer] button:hover { text-decoration: underline; }
  `);

  function iconMarkup(icon) {
    const lucide = icons[icon];
    if (!lucide) return `<span style="font-size: 0.95em">${icon.replace(/[<&]/g, "")}</span>`;
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${lucide.svg}</svg>`;
  }

  function save(name, project) {
    if (project) {
      projects.set(keyOf(name), { ...project, name });
      saved[name] = project;
    } else {
      projects.delete(keyOf(name));
      delete saved[name];
    }
    api.storage.set("projects", saved);
    apply();
  }

  function decorateTitle(section, icon, label) {
    const title = sidebar.title(section);
    if (!title) return;
    title.setAttribute("data-ct-title", "");
    title.setAttribute("data-ct-name", displayName(label));
    let badge = title.querySelector(":scope > [data-ct-badge]");
    if (!badge) {
      badge = document.createElement("span");
      badge.setAttribute("data-ct-badge", "");
      badge.title = "Change icon and color";
      for (const type of ["pointerdown", "mousedown", "click"]) {
        badge.addEventListener(type, (event) => {
          event.stopPropagation();
          event.preventDefault();
          if (type === "click") openPicker(section, badge);
        });
      }
      title.prepend(badge);
    }
    if (badge.dataset.icon !== icon) {
      badge.dataset.icon = icon;
      badge.innerHTML = iconMarkup(icon);
    }
  }

  // Items are the row list's children: a session, or a session followed by its
  // sub-sessions. They come sorted by recency, so the first VISIBLE_ROWS are the latest.
  // The app's own "Show more" comes after the items: it loads sessions it hasn't
  // rendered yet, so the CSS hides it along with the extra items until the block expands.
  function limitRows(section, label) {
    const rowList = sidebar.rowList(section);
    let more = section.querySelector("[data-ct-more]");
    if (!rowList) {
      more?.remove();
      return;
    }
    rowList.setAttribute("data-ct-rows", "");
    const nativeMore = sidebar.nativeShowMore(rowList);
    const items = [...rowList.children].filter((item) => item !== nativeMore && item !== more);
    const unrendered = Number(nativeMore?.querySelector("[aria-label]")?.getAttribute("aria-label").match(/\d+/)?.[0] || 0);
    const hiddenCount = Math.max(items.length - VISIBLE_ROWS, 0);
    if (hiddenCount === 0) {
      more?.remove();
      return;
    }
    if (!more) {
      more = document.createElement("button");
      more.setAttribute("data-ct-more", "");
      more.addEventListener("click", () => {
        const key = keyOf(sidebar.label(section));
        expanded.has(key) ? expanded.delete(key) : expanded.add(key);
        apply();
      });
    }
    const isOpen = expanded.has(keyOf(label));
    const text = isOpen ? "Show less" : `Show ${hiddenCount + unrendered} more`;
    if (more.dataset.text !== text) {
      more.dataset.text = text;
      more.innerHTML = iconMarkup(isOpen ? "chevron-up" : "chevron-down");
      more.append(text);
    }
    // Inside the rows' own container, so collapsing the section hides it too.
    if (rowList.lastElementChild !== more) rowList.appendChild(more);
  }

  function decorate(section, label, fallback) {
    const look = { ...fallback, ...projects.get(keyOf(label)) };
    section.setAttribute("data-ct-section", "");
    section.toggleAttribute("data-ct-expanded", expanded.has(keyOf(label)));
    section.toggleAttribute("data-ct-running", sidebar.isRunning(section));
    section.style.setProperty("--ct-accent", look.color);
    decorateTitle(section, look.icon, label);
    limitRows(section, label);
    if (ANIMATION === "orbit") updateOrbit(section, label);
  }

  function apply() {
    for (const section of sidebar.sections()) {
      const label = sidebar.label(section);
      if (label) decorate(section, label, PROJECT_LOOK);
    }
    const routines = api.settings.routinesBlock && sidebar.routines();
    if (routines) {
      routines.setAttribute("data-ct-routines", "");
      decorate(routines, "Routines", ROUTINES_LOOK);
    }
  }

  // Each light keeps its place as a fraction of the lap, per section. When a block
  // grows or shrinks, the light stays at the same relative spot instead of jumping,
  // and a block the app re-renders picks up where its light was.
  const orbitPhases = new Map();
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  let orbitFrame = null;
  let lastFrameTime = null;

  function stepOrbits(now) {
    const elapsed = lastFrameTime === null ? 0 : Math.min((now - lastFrameTime) / 1000, 0.1);
    lastFrameTime = now;
    const orbits = [...document.querySelectorAll("[data-ct-orbit]")].map((orbit) => ({
      orbit,
      perimeter: 2 * (orbit.parentElement.offsetWidth + orbit.parentElement.offsetHeight - 3) - (8 - 2 * Math.PI) * ORBIT_RADIUS,
    }));
    for (const { orbit, perimeter } of orbits) {
      const phase = ((orbitPhases.get(orbit.dataset.key) || 0) + (ORBIT_SPEED * elapsed) / perimeter) % 1;
      orbitPhases.set(orbit.dataset.key, phase);
      orbit.firstChild.style.strokeDasharray = `${ORBIT_DASH} ${perimeter - ORBIT_DASH}`;
      orbit.firstChild.style.strokeDashoffset = String(-phase * perimeter);
    }
    orbitFrame = orbits.length ? requestAnimationFrame(stepOrbits) : null;
    if (!orbitFrame) lastFrameTime = null;
  }

  function updateOrbit(section, label) {
    let orbit = section.querySelector(":scope > [data-ct-orbit]");
    if (!sidebar.isRunning(section)) {
      orbit?.remove();
      return;
    }
    if (!orbit) {
      orbit = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      orbit.setAttribute("data-ct-orbit", "");
      orbit.setAttribute("aria-hidden", "true");
      orbit.dataset.key = keyOf(label);
      orbit.appendChild(document.createElementNS("http://www.w3.org/2000/svg", "rect"));
      section.appendChild(orbit);
    }
    if (!orbitFrame && !reducedMotion.matches) orbitFrame = requestAnimationFrame(stepOrbits);
  }

  function closePicker() {
    picker?.remove();
    picker = null;
    document.removeEventListener("mousedown", onOutsideClick, true);
  }

  function onOutsideClick(event) {
    if (picker && !picker.contains(event.target)) closePicker();
  }

  function openPicker(section, anchor) {
    closePicker();
    const isRoutines = section.hasAttribute("data-ct-routines");
    const label = isRoutines ? "Routines" : sidebar.label(section);
    const fallback = isRoutines ? ROUTINES_LOOK : PROJECT_LOOK;
    const existing = projects.get(keyOf(label));
    const name = existing?.name || displayName(label);
    let choice = { color: existing?.color || fallback.color, icon: existing?.icon || fallback.icon };

    picker = document.createElement("div");
    picker.setAttribute("data-ct-picker", "");
    picker.innerHTML = `
      <input type="search" placeholder="Search ${Object.keys(icons).length} icons">
      <div data-ct-grid></div>
      <div data-ct-swatches></div>
      <div data-ct-footer><span></span><button type="button">Reset</button></div>`;
    const search = picker.querySelector("input");
    const grid = picker.querySelector("[data-ct-grid]");
    const swatches = picker.querySelector("[data-ct-swatches]");
    picker.querySelector("[data-ct-footer] span").textContent = name;

    function choose(change) {
      choice = { ...choice, ...change };
      save(name, choice);
      render();
    }

    function render() {
      picker.style.setProperty("--ct-pick", choice.color);
      const query = search.value.trim().toLowerCase();
      const matches = Object.entries(icons)
        .filter(([iconName, { tags }]) => !query || iconName.includes(query) || tags.some((tag) => tag.includes(query)))
        .slice(0, 160);
      grid.innerHTML = "";
      for (const [iconName] of matches) {
        const button = document.createElement("button");
        button.type = "button";
        button.title = iconName;
        button.innerHTML = iconMarkup(iconName);
        button.toggleAttribute("data-selected", iconName === choice.icon);
        button.addEventListener("click", () => choose({ icon: iconName }));
        grid.appendChild(button);
      }
      swatches.innerHTML = "";
      for (const color of PALETTE) {
        const button = document.createElement("button");
        button.type = "button";
        button.style.background = color;
        button.style.color = color;
        button.toggleAttribute("data-selected", color.toLowerCase() === choice.color.toLowerCase());
        button.addEventListener("click", () => choose({ color }));
        swatches.appendChild(button);
      }
      const custom = document.createElement("input");
      custom.type = "color";
      custom.value = choice.color;
      custom.title = "Custom color";
      custom.addEventListener("change", () => choose({ color: custom.value }));
      swatches.appendChild(custom);
    }

    search.addEventListener("input", render);
    picker.addEventListener("keydown", (event) => {
      event.stopPropagation();
      if (event.key === "Escape") closePicker();
    });
    picker.querySelector("[data-ct-footer] button").addEventListener("click", () => {
      save(name, null);
      closePicker();
    });

    render();
    document.body.appendChild(picker);
    const rect = anchor.getBoundingClientRect();
    picker.style.left = `${Math.min(rect.left, window.innerWidth - picker.offsetWidth - 8)}px`;
    picker.style.top = `${Math.min(rect.bottom + 6, window.innerHeight - picker.offsetHeight - 8)}px`;
    search.focus();
    document.addEventListener("mousedown", onOutsideClick, true);
  }

  api.watch(apply);
  api.onCleanup(() => {
    cancelAnimationFrame(orbitFrame);
    closePicker();
    document.querySelectorAll("[data-ct-badge], [data-ct-more], [data-ct-orbit]").forEach((el) => el.remove());
    document.querySelectorAll("[data-ct-section]").forEach((el) => el.style.removeProperty("--ct-accent"));
    for (const attribute of ATTRIBUTES) {
      document.querySelectorAll(`[${attribute}]`).forEach((el) => el.removeAttribute(attribute));
    }
  });
  apply();
}
