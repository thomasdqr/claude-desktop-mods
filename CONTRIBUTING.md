# Writing a mod

A mod is a folder in `mods/` with a manifest and some JavaScript. Once its pull request is
merged, it shows up in everyone's **Catalog**.

## 1. Start from the template

```bash
cd ~/Documents/GitHub/claude-desktop-mods
cp -R template/my-mod mods/my-mod
```

Rename the folder and set the same `id` in `manifest.json`: lowercase, words joined by
dashes.

```
mods/my-mod/
  manifest.json   what the app shows, and the settings it builds controls for
  main.js         defines activate(api), which runs inside Claude
  README.md       a screenshot and the settings, for the catalog's readers
```

## 2. Fill in the manifest

```json
{
  "id": "my-mod",
  "name": "My Mod",
  "version": "0.1.0",
  "description": "One sentence on what it changes in Claude.",
  "author": "your-github-name",
  "icon": { "symbol": "sparkles", "color": "#4F86F7" },
  "main": "main.js",
  "assets": { "words": "words.json" },
  "settings": [],
  "testedOn": "Claude 4.29"
}
```

- `icon` is an [SF Symbol](https://developer.apple.com/sf-symbols/) name and a color. The
  app draws it on a tint of that color.
- `assets` are JSON files in the mod's folder. The mod gets them already parsed.
- `settings` is a list, and the app builds a control for each one, in that order:

```json
"settings": [
  { "key": "style", "type": "choice", "label": "Style", "description": "How it looks.",
    "options": [{ "value": "soft", "label": "Soft" }, { "value": "bold", "label": "Bold" }],
    "default": "soft" },
  { "key": "compact", "type": "toggle", "label": "Compact", "description": "Tighter rows.", "default": false },
  { "key": "limit", "type": "number", "label": "Limit", "description": "How many.", "min": 1, "max": 20, "default": 5 },
  { "key": "data", "type": "hidden", "description": "Edited elsewhere, like color-tabs' projects.", "default": {} }
]
```

## 3. Write `activate(api)`

```js
function activate(api) {
  api.css(`[data-group-name] { letter-spacing: 0.02em; }`);
  api.watch(() => {
    for (const section of api.sidebar.sections()) {
      // runs once per frame after Claude's page changes
    }
  });
}
```

What `api` gives a mod:

| | |
|---|---|
| `api.settings` | the manifest's defaults, overridden by the user's choices |
| `api.assets` | the manifest's JSON assets, already parsed |
| `api.storage.get/set` | JSON values kept in Claude, namespaced to the mod |
| `api.css(text)` | a stylesheet, removed when the mod stops |
| `api.watch(callback)` | runs once per frame after the page changes |
| `api.onCleanup(fn)` | runs when the mod stops |
| `api.sidebar` | helpers for Claude's sidebar: `sections()`, `routines()`, `title()`, `label()`, `rowList()`, `isRunning()`… |

Claude's markup is listed at the top of [`runtime/runtime.js`](runtime/runtime.js). Use the
`api.sidebar` helpers rather than your own selectors where you can: when a Claude update
changes its markup, the fix happens there once for every mod. A mod that throws is logged and
stopped, and the others keep running.

## 4. Try it

1. In the app, open **Catalog**: your mod is there. Click **Install**, then **Restart Claude**.
2. After a change to your code, run `python3 install.py`. It rebuilds the snippet, waits for
   you to quit Claude, and reopens it.
3. Errors show in Claude's DevTools console (**⌥⌘I**), prefixed with `[Claude Desktop Mods]`.

Then check it like CI will:

```bash
python3 check_mods.py
```

## 5. Propose it for the catalog

1. Fork the repo, add your folder, and open a pull request.
2. Add a `README.md` to your mod with a screenshot of Claude with the mod on. Use made-up
   project and session names.
3. CI runs `check_mods.py`. A maintainer reviews the code, then merges it. After the next
   update, everyone sees your mod in **Catalog**.

### The rules

A mod runs inside Claude with the user's session, so it can read their conversations and act
as them. So every mod:

- ships all of its code in its folder. No `fetch`, `eval`, `new Function`, `import()`,
  WebSocket or added `<script>`. `check_mods.py` refuses them.
- only changes how Claude looks and behaves on screen. It never sends anything anywhere.
- cleans up after itself with `api.onCleanup`: a mod switched off leaves no trace.

## 6. Update a mod

Raise `version` in `manifest.json` with every change: `1.1.0` → `1.2.0` for something new,
`1.2.0` → `1.2.1` for a fix. CI refuses a changed mod with the same version, because the app
compares versions to tell users an update is ready.

Once merged, the app's Installed page shows the update in a blue banner, with **Update all**.
A click pulls the repository, then **Restart Claude** loads the new version.

To tell users what changed, title the commit that raises the version
`my-mod 1.2.0: what changed`. Pull requests here are squashed, so the pull request's title
counts. The banner then reads "My Mod 1.2.0: what changed". It's
optional: with any other title, the banner shows the name and version only.
