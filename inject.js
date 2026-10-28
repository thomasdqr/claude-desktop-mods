// Runs inside the claude.ai page of the desktop app. loader.js runs it again
// whenever this file or config.json changes, so edits apply live.
//
// Sidebar markup it relies on (Claude 3.6556.2):
//   .df-sortable-section                     the wrapper the user drags to reorder
//     [data-group-section]                   one section (project or custom group)
//       [data-sidebar-group-label]           the header row
//         [data-group-name]                  the section title
//         [data-group-toggle][aria-expanded] the collapse button
//       [data-row-key="code:local_<id>"]     one session row (nested for sub-sessions)
//         [data-row-main-button]             the row's text
// Rows read the app's own --df-row-* and --df-hover / --df-selected variables,
// so each section overrides those instead of restyling rows one by one.
function claudeColors({ config, icons }) {
  window.__claudeColors?.destroy();

  const VISIBLE_ROWS = 5;
  const SAVE_PREFIX = "__claude_colors_save__";
  const DEFAULT_ICON = "folder";
  const DEFAULT_COLOR = "#9AA3AE";
  const PALETTE = [
    "#F0609E", "#E5484D", "#F08A3C", "#F5B83D", "#D4D96A", "#3DBE7A",
    "#6FC2B4", "#5BC0F8", "#4F86F7", "#A07CF0", "#C8915F", "#9AA3AE",
  ];
  const ATTRIBUTES = ["data-cc-section", "data-cc-expanded", "data-cc-title", "data-cc-name", "data-cc-extra"];
  const LEADING_EMOJI = /^[^\p{L}\p{N}]+/u;
  const displayName = (label) => label.replace(LEADING_EMOJI, "").trim();
  const keyOf = (label) => displayName(label).toLowerCase();

  let projects = new Map();
  const expanded = new Set();
  let picker = null;

  const style = document.createElement("style");
  style.id = "claude-colors";
  style.textContent = `
    .df-sortable-section:has(> [data-cc-section]) { margin: 0 0 6px !important; }

    [data-cc-section] {
      --cc-text: color-mix(in oklab, var(--cc-accent) 72%, currentColor);
      --cc-soft-text: color-mix(in oklab, var(--cc-accent) 28%, currentColor);
      --df-row-font: 13px;
      --df-row-h: 28px;
      --df-group-pt: 0px;
      --df-hover: color-mix(in srgb, var(--cc-accent) 16%, transparent);
      --df-selected: color-mix(in srgb, var(--cc-accent) 26%, transparent);
      gap: 1px !important; margin: 0 !important; padding: 3px;
      border-radius: 12px;
      background: color-mix(in srgb, var(--cc-accent) 11%, transparent);
      box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--cc-accent) 14%, transparent);
    }
    [data-cc-section] [data-gap-after] { margin-top: 0 !important; }
    [data-cc-section] [data-sidebar-group-label] {
      min-height: 32px; margin-top: 0 !important; padding-block: 0 !important; padding-inline-start: 3px; border-radius: 9px;
    }
    [data-cc-section] [data-sidebar-group-label]:hover { background: var(--df-hover); }

    [data-cc-title] {
      display: inline-flex !important; align-items: center; gap: 8px; min-width: 0;
      font-size: 13px !important; font-weight: 600 !important; color: var(--cc-text) !important;
    }
    [data-cc-title] > :not([data-cc-badge]) { display: none !important; }
    [data-cc-title]::after { content: attr(data-cc-name); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    [data-cc-badge] {
      display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0;
      width: 22px; height: 22px; border-radius: 6px; cursor: pointer;
      color: var(--cc-text);
      background: color-mix(in srgb, var(--cc-accent) 26%, transparent);
    }
    [data-cc-badge]:hover { background: color-mix(in srgb, var(--cc-accent) 40%, transparent); }
    [data-cc-badge] svg { width: 14px; height: 14px; }

    [data-cc-section] [data-row] { border-radius: 8px !important; }
    [data-cc-section] [data-row-main-button] { color: var(--cc-soft-text) !important; font-weight: 400 !important; }
    [data-cc-section] [data-row][data-selected] [data-row-main-button],
    [data-cc-section] [data-row-main-button]:hover { color: var(--cc-text) !important; }
    [data-cc-section]:not([data-cc-expanded]) [data-cc-extra] { display: none !important; }

    [data-cc-more] {
      all: unset; box-sizing: border-box; display: flex; align-items: center; gap: 6px; width: 100%;
      height: 26px; padding: 0 var(--df-row-px, 10px); border-radius: 8px; cursor: pointer;
      font-size: 12px; color: var(--cc-soft-text); opacity: 0.75;
    }
    [data-cc-more]:hover { opacity: 1; background: var(--df-hover); }
    [data-cc-more] svg { width: 13px; height: 13px; }

    [data-cc-picker] {
      position: fixed; z-index: 2147483647; width: 320px; padding: 12px; box-sizing: border-box;
      border-radius: 12px; font: 13px system-ui, sans-serif;
      background: var(--cds-surface-2, var(--cds-surface-1, #262624)); color: var(--cds-text-primary, #ecebe4);
      border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
      box-shadow: 0 12px 32px rgba(0, 0, 0, 0.35);
    }
    [data-cc-picker] input[type=search] {
      width: 100%; box-sizing: border-box; padding: 6px 8px; border-radius: 8px; font: inherit; color: inherit;
      background: color-mix(in srgb, currentColor 8%, transparent); border: 1px solid color-mix(in srgb, currentColor 18%, transparent);
    }
    [data-cc-picker] [data-cc-grid] {
      display: grid; grid-template-columns: repeat(8, 1fr); gap: 4px; margin: 10px 0;
      max-height: 200px; overflow-y: auto;
    }
    [data-cc-picker] button {
      all: unset; display: flex; align-items: center; justify-content: center; cursor: pointer; border-radius: 7px;
    }
    [data-cc-grid] button { height: 32px; color: var(--cc-pick); }
    [data-cc-grid] button:hover, [data-cc-grid] button[data-selected] { background: color-mix(in srgb, var(--cc-pick) 22%, transparent); }
    [data-cc-grid] svg { width: 18px; height: 18px; }
    [data-cc-swatches] { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
    [data-cc-swatches] button { width: 20px; height: 20px; border-radius: 50%; }
    [data-cc-swatches] button[data-selected] { box-shadow: 0 0 0 2px var(--cds-surface-1, #1f1f1e), 0 0 0 4px currentColor; }
    [data-cc-swatches] input { width: 24px; height: 24px; padding: 0; border: none; background: none; cursor: pointer; }
    [data-cc-footer] { display: flex; justify-content: space-between; margin-top: 10px; opacity: 0.7; font-size: 12px; }
    [data-cc-footer] button:hover { text-decoration: underline; }
  `;
  document.head.appendChild(style);

  function iconMarkup(icon) {
    const lucide = icons[icon];
    if (!lucide) return `<span style="font-size: 0.95em">${icon.replace(/[<&]/g, "")}</span>`;
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${lucide.svg}</svg>`;
  }

  function save(name, project) {
    if (project) projects.set(keyOf(name), { ...project, name });
    else projects.delete(keyOf(name));
    console.log(SAVE_PREFIX + JSON.stringify({ name, project }));
    apply();
  }

  function sectionLabel(section) {
    const title = section.querySelector("[data-group-name]");
    return section.getAttribute("data-group-label") || (title ? title.textContent.trim() : "");
  }

  function decorateTitle(section, project, label) {
    const title = section.querySelector("[data-group-name]");
    if (!title) return;
    title.setAttribute("data-cc-title", "");
    title.setAttribute("data-cc-name", displayName(label));
    const icon = project?.icon || DEFAULT_ICON;
    let badge = title.querySelector(":scope > [data-cc-badge]");
    if (!badge) {
      badge = document.createElement("span");
      badge.setAttribute("data-cc-badge", "");
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
  // The app's own "Show more" loads sessions it hasn't rendered yet, so it stays
  // available once the section is expanded.
  function limitRows(section, label) {
    const rowList = [...section.children].find((child) => child.querySelector('[data-row-key^="code:"]'));
    let more = section.querySelector("[data-cc-more]");
    if (!rowList) {
      more?.remove();
      return;
    }
    const nativeMore = rowList.querySelector(':scope > [data-row-key^="label:showmore:"]');
    const items = [...rowList.children].filter((item) => item !== nativeMore && item !== more);
    items.forEach((item, index) => item.toggleAttribute("data-cc-extra", index >= VISIBLE_ROWS));
    const unrendered = Number(nativeMore?.querySelector("[aria-label]")?.getAttribute("aria-label").match(/\d+/)?.[0] || 0);
    const hiddenCount = Math.max(items.length - VISIBLE_ROWS, 0);
    nativeMore?.toggleAttribute("data-cc-extra", hiddenCount > 0);
    if (hiddenCount === 0) {
      more?.remove();
      return;
    }
    if (!more) {
      more = document.createElement("button");
      more.setAttribute("data-cc-more", "");
      more.addEventListener("click", () => {
        const key = keyOf(sectionLabel(section));
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

  function apply() {
    for (const section of document.querySelectorAll("[data-group-section]")) {
      const label = sectionLabel(section);
      if (!label) continue;
      const project = projects.get(keyOf(label));
      section.setAttribute("data-cc-section", "");
      section.toggleAttribute("data-cc-expanded", expanded.has(keyOf(label)));
      section.style.setProperty("--cc-accent", project?.color || DEFAULT_COLOR);
      decorateTitle(section, project, label);
      limitRows(section, label);
    }
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
    const label = sectionLabel(section);
    const existing = projects.get(keyOf(label));
    const name = existing?.name || displayName(label);
    let choice = { color: existing?.color || DEFAULT_COLOR, icon: existing?.icon || DEFAULT_ICON };

    picker = document.createElement("div");
    picker.setAttribute("data-cc-picker", "");
    picker.innerHTML = `
      <input type="search" placeholder="Search ${Object.keys(icons).length} icons">
      <div data-cc-grid></div>
      <div data-cc-swatches></div>
      <div data-cc-footer><span></span><button type="button">Reset</button></div>`;
    const search = picker.querySelector("input");
    const grid = picker.querySelector("[data-cc-grid]");
    const swatches = picker.querySelector("[data-cc-swatches]");
    picker.querySelector("[data-cc-footer] span").textContent = name;

    function choose(change) {
      choice = { ...choice, ...change };
      save(name, choice);
      render();
    }

    function render() {
      picker.style.setProperty("--cc-pick", choice.color);
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
    picker.querySelector("[data-cc-footer] button").addEventListener("click", () => {
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

  let pending = null;
  const observer = new MutationObserver(() => {
    if (pending) return;
    pending = setTimeout(() => {
      pending = null;
      apply();
    }, 150);
  });

  function destroy() {
    observer.disconnect();
    clearTimeout(pending);
    closePicker();
    style.remove();
    document.querySelectorAll("[data-cc-badge], [data-cc-more]").forEach((el) => el.remove());
    for (const attribute of ATTRIBUTES) {
      document.querySelectorAll(`[${attribute}]`).forEach((el) => el.removeAttribute(attribute));
    }
    document.querySelectorAll("[data-group-section]").forEach((el) => el.style.removeProperty("--cc-accent"));
  }

  projects = new Map(
    Object.entries(config.projects || {}).map(([name, project]) => [keyOf(name), { ...project, name }])
  );
  observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["aria-expanded"] });
  window.__claudeColors = { destroy };
  apply();
}
