// Claude Desktop Mods runtime. install.py bundles it with the enabled mods into one
// DevTools snippet; running the snippet calls this function with those mods.
//
// Each mod gets an API instead of touching the page on its own:
//   api.id, api.version     the mod's manifest id and version
//   api.settings            manifest defaults, overridden by the user's settings.json
//   api.assets              the manifest's JSON assets, already parsed
//   api.storage.get/set     JSON values kept in Claude, namespaced to the mod
//   api.css(text)           adds a stylesheet, removed when the mod stops
//   api.watch(callback)     runs callback once per frame after the page changes
//   api.onCleanup(fn)       runs fn when the mod stops
//   api.sidebar             what the runtime knows about Claude's sidebar markup
// A mod that throws is logged and stopped; the others keep running.
//
// The app changes settings while Claude runs with __cdm.configure({ id: { key: value } }):
// the mod stops and starts again with them. They're kept in Claude until the next bundle,
// built at builtAt, has them too.
function claudeDesktopMods(mods, builtAt) {
  window.__cdm?.destroy();

  // Claude's sidebar markup in one place, so a Claude update gets fixed here once
  // rather than in every mod (checked against Claude 4.29):
  //   .df-sortable-section                     the wrapper the user drags to reorder
  //     [data-group-section]                   one section (project or custom group)
  //       [data-sidebar-group-label]           the header row
  //         [data-group-name]                  the section title
  //         [data-group-toggle][aria-expanded] the collapse button
  //       [data-row-key="code:<id>"]           one session row
  //         [data-row-main-button]             the row's text
  //         [data-attention="working"]         set while the session runs ("unread" once done)
  //   [data-select-domain="scheduled"]         the routines list: not a [data-group-section],
  //     [data-row-key="label:scheduled"]       but the same header markup
  //     [data-row-key="scheduled-task:<id>"]   one routine row: data-attention="unread" once
  //                                            done, but never "working" while it runs
  const sidebar = {
    sections: () => [...document.querySelectorAll("[data-group-section]")],
    title: (section) => section.querySelector("[data-group-name]") ?? section.querySelector("h3 button > span"),
    routines: () => document.querySelector('[data-select-domain="scheduled"]'),
    label(section) {
      const title = sidebar.title(section);
      return section.getAttribute("data-group-label") || (title ? title.textContent.trim() : "");
    },
    isOpen: (section) => section.querySelector("[data-group-toggle]")?.getAttribute("aria-expanded") !== "false",
    rowList: (section) => [...section.children].find((child) => child.querySelector('[data-row-key^="code:"]')),
    nativeShowMore: (rowList) => rowList.querySelector(':scope > [data-row-key^="label:showmore:"]'),
    isRunning: (section) => Boolean(section.querySelector('[data-attention="working"]')),
  };

  const safely = (mod, fn) => {
    try {
      fn();
    } catch (error) {
      console.error(`[Claude Desktop Mods] ${mod.id} ${mod.version}:`, error);
    }
  };

  // One observer for every mod; each mod's callbacks run once per frame, before paint.
  const watchers = new Set();
  let pending = null;
  const observer = new MutationObserver(() => {
    pending ??= requestAnimationFrame(() => {
      pending = null;
      for (const watcher of watchers) safely(watcher.mod, watcher.callback);
    });
  });
  observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["aria-expanded"] });

  const liveKey = (mod) => `cdm:${mod.id}:live-settings`;
  const liveSettings = (mod) => {
    try {
      const live = JSON.parse(localStorage.getItem(liveKey(mod)));
      return live?.at > builtAt ? live.settings : {};
    } catch {
      return {};
    }
  };

  const running = new Map();
  const start = (mod) => {
    const cleanups = [];
    const storageKey = (key) => `cdm:${mod.id}:${key}`;
    const api = {
      id: mod.id,
      version: mod.version,
      settings: { ...mod.settings, ...liveSettings(mod) },
      assets: mod.assets,
      sidebar,
      storage: {
        get(key) {
          try {
            return JSON.parse(localStorage.getItem(storageKey(key)));
          } catch {
            return null;
          }
        },
        set(key, value) {
          localStorage.setItem(storageKey(key), JSON.stringify(value));
        },
      },
      css(text) {
        const style = document.createElement("style");
        style.dataset.cdmMod = mod.id;
        style.textContent = text;
        document.head.appendChild(style);
        cleanups.push(() => style.remove());
      },
      watch(callback) {
        const watcher = { mod, callback };
        watchers.add(watcher);
        cleanups.push(() => watchers.delete(watcher));
      },
      onCleanup(fn) {
        cleanups.push(fn);
      },
    };
    const stop = () => cleanups.reverse().forEach((fn) => safely(mod, fn));
    running.set(mod.id, stop);
    try {
      mod.activate(api);
    } catch (error) {
      console.error(`[Claude Desktop Mods] ${mod.id} ${mod.version} didn't start:`, error);
      stop();
      running.delete(mod.id);
    }
  };
  mods.forEach(start);

  window.__cdm = {
    mods: mods.filter((mod) => running.has(mod.id)).map((mod) => `${mod.id}@${mod.version}`),
    configure(changes) {
      for (const [id, settings] of Object.entries(changes)) {
        const mod = mods.find((m) => m.id === id);
        if (!mod) continue;
        const live = { ...liveSettings(mod), ...settings };
        localStorage.setItem(liveKey(mod), JSON.stringify({ at: Date.now(), settings: live }));
        running.get(id)?.();
        start(mod);
      }
    },
    destroy() {
      observer.disconnect();
      cancelAnimationFrame(pending);
      [...running.values()].reverse().forEach((stop) => stop());
    },
  };
}
