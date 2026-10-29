#!/usr/bin/env python3
"""Install or update Claude Desktop Mods in the Claude desktop app. Run it from Terminal.

It bundles the runtime and the enabled mods (mods/*/manifest.json, switched on or off
in settings.json) into one DevTools snippet, then, once Claude is quit, turns on
Developer Mode and saves the snippet in Claude's DevTools. Claude then reopens.
To run the mods after each launch: ⌥⌘I, ⌘P, !cdm, Enter, or let the app do it.
"""
import json
import os
import shutil
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = os.path.join(HERE, "mods")
SETTINGS = os.path.join(HERE, "settings.json")
BUNDLE = os.path.join(HERE, "dist", "cdm.js")
SNIPPET_NAME = "cdm"
# Snippets earlier versions installed, removed so they don't run alongside the bundle.
OLD_SNIPPET_NAMES = ["claude-colors"]
CLAUDE_DATA = os.path.expanduser("~/Library/Application Support/Claude")
# What Help → Enable Developer Mode… writes.
DEVELOPER_SETTINGS = os.path.join(CLAUDE_DATA, "developer_settings.json")
# Chromium keeps DevTools snippets in the app's preferences.
PREFERENCES = os.path.join(CLAUDE_DATA, "Preferences")


def read_json(path):
    with open(path) as f:
        return json.load(f)


def read_text(path):
    with open(path) as f:
        return f.read().strip()


def load_mods():
    mods = []
    for mod_id in sorted(os.listdir(MODS)):
        folder = os.path.join(MODS, mod_id)
        if os.path.exists(os.path.join(folder, "manifest.json")):
            mods.append((folder, read_json(os.path.join(folder, "manifest.json"))))
    return mods


def load_settings():
    """settings.json lists the installed mods: each one's switch and the user's settings.
    The app's catalog adds and removes entries; a mod without one isn't installed."""
    settings = read_json(SETTINGS) if os.path.exists(SETTINGS) else {"mods": {}}
    # Before mods, Claude Colors kept its starting colors in config.json.
    legacy = os.path.join(HERE, "config.json")
    if os.path.exists(legacy) and "color-tabs" not in settings["mods"]:
        projects = read_json(legacy).get("projects", {})
        settings["mods"]["color-tabs"] = {"enabled": True, "settings": {"projects": projects}}
    save_settings(settings)
    return settings


def save_settings(settings):
    with open(SETTINGS, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")


def bundle_mod(folder, manifest, user_settings):
    defaults = {spec["key"]: spec.get("default") for spec in manifest.get("settings", [])}
    assets = {name: read_text(os.path.join(folder, path)) for name, path in manifest.get("assets", {}).items()}
    assets_js = ", ".join(f"{json.dumps(name)}: {content}" for name, content in assets.items())
    # main.js defines activate(api); the wrapper hands that function to the runtime.
    return f"""{{
    id: {json.dumps(manifest["id"])},
    version: {json.dumps(manifest["version"])},
    settings: {json.dumps({**defaults, **user_settings}, ensure_ascii=False)},
    assets: {{ {assets_js} }},
    activate: (() => {{
{read_text(os.path.join(folder, manifest["main"]))}
return activate;
    }})(),
  }}"""


def build_bundle():
    installed = load_settings()["mods"]
    enabled = [(folder, manifest) for folder, manifest in load_mods()
               if installed.get(manifest["id"], {}).get("enabled")]
    bundled = ",\n  ".join(
        bundle_mod(folder, manifest, installed[manifest["id"]].get("settings", {})) for folder, manifest in enabled
    )
    bundle = f"""// Claude Desktop Mods: run in the DevTools of the Claude desktop app's claude.ai page.
// Mods: {", ".join(f'{m["id"]}@{m["version"]}' for _, m in enabled) or "none"}
({read_text(os.path.join(HERE, "runtime", "runtime.js"))})([
  {bundled}
], {int(time.time() * 1000)});
"""
    os.makedirs(os.path.dirname(BUNDLE), exist_ok=True)
    with open(BUNDLE, "w") as f:
        f.write(bundle)
    return bundle, [manifest["id"] for _, manifest in enabled]


def claude_is_running():
    processes = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True).stdout
    return any(line.endswith("/Contents/MacOS/Claude") for line in processes.splitlines())


def update_json(path, change):
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            data = json.load(f)
    change(data)
    with open(path, "w") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)


def installed_snippet_names():
    if not os.path.exists(PREFERENCES):
        return []
    preferences = read_json(PREFERENCES).get("electron", {}).get("devtools", {}).get("preferences", {})
    return [s.get("name") for s in json.loads(preferences.get("script-snippets", "[]"))]


def remember_developer_mode():
    """Notes once whether Developer Mode was on before CDM, so uninstall.py leaves it as
    it found it. With a CDM snippet already there, CDM is the one that turned it on."""
    settings = load_settings()
    if "developerModeWasOn" in settings:
        return
    was_on = os.path.exists(DEVELOPER_SETTINGS) and read_json(DEVELOPER_SETTINGS).get("allowDevTools") is True
    ours = {SNIPPET_NAME, *OLD_SNIPPET_NAMES}
    settings["developerModeWasOn"] = was_on and not ours.intersection(installed_snippet_names())
    save_settings(settings)


def install_snippet(data, bundle):
    preferences = data.setdefault("electron", {}).setdefault("devtools", {}).setdefault("preferences", {})
    replaced = {SNIPPET_NAME, *OLD_SNIPPET_NAMES}
    snippets = [s for s in json.loads(preferences.get("script-snippets", "[]")) if s.get("name") not in replaced]
    snippets.append({"name": SNIPPET_NAME, "content": bundle})
    preferences["script-snippets"] = json.dumps(snippets, separators=(",", ":"), ensure_ascii=False)
    preferences.setdefault("script-snippets-last-identifier", "1")
    # In its own window, DevTools can be closed without closing Claude's window.
    preferences["currentDockState"] = json.dumps("undocked")


def main():
    bundle, enabled = build_bundle()
    print(f"Bundled {len(enabled)} mod(s): {', '.join(enabled) or 'none'} ({len(bundle) // 1024} KB).")

    # Claude rewrites its preferences when it quits, so they can only change while it's closed.
    if claude_is_running():
        print("Quit Claude (⌘Q) to finish the setup. Waiting…")
        while claude_is_running():
            time.sleep(1)

    remember_developer_mode()
    update_json(DEVELOPER_SETTINGS, lambda data: data.update(allowDevTools=True))
    if os.path.exists(PREFERENCES):
        shutil.copy(PREFERENCES, PREFERENCES + ".cdm-backup")
    update_json(PREFERENCES, lambda data: install_snippet(data, bundle))
    print("Developer Mode is on and the mods are saved in Claude's DevTools.")

    subprocess.run(["open", "-b", "com.anthropic.claudefordesktop"], check=True)
    print("Claude is reopening. To run the mods: ⌥⌘I, then ⌘P, type !cdm, press Enter.")


if __name__ == "__main__":
    main()
