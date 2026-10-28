#!/usr/bin/env python3
"""Install or update Claude Colors in the Claude desktop app. Run it from Terminal.

It builds the DevTools snippet from inject.js, config.json and the icons, then, once
Claude is quit, turns on Developer Mode and saves the snippet in Claude's DevTools.
Claude then reopens. To apply the colors after each launch: ⌥⌘I, ⌘P, !claude-colors, Enter.

Picker choices are saved in Claude's own storage, so they survive restarts.
"""
import json
import os
import shutil
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SNIPPET = os.path.join(HERE, "dist", "claude-colors-snippet.js")
SNIPPET_NAME = "claude-colors"
CLAUDE_DATA = os.path.expanduser("~/Library/Application Support/Claude")
# What Help → Enable Developer Mode… writes.
DEVELOPER_SETTINGS = os.path.join(CLAUDE_DATA, "developer_settings.json")
# Chromium keeps DevTools snippets in the app's preferences.
PREFERENCES = os.path.join(CLAUDE_DATA, "Preferences")


def read(name):
    with open(os.path.join(HERE, name)) as f:
        return f.read().strip()


def build_snippet():
    if not os.path.exists(os.path.join(HERE, "config.json")):
        shutil.copy(os.path.join(HERE, "config.example.json"), os.path.join(HERE, "config.json"))
    snippet = f"""// Claude Colors: run in the DevTools of the Claude desktop app's claude.ai page.
(() => {{
  // Picker choices are kept in Claude's storage and win over config.json, project by project.
  const STORAGE_KEY = "claude-colors";
  const defaults = {read("config.json")};
  let saved = {{}};
  try {{
    saved = JSON.parse(localStorage.getItem(STORAGE_KEY))?.projects ?? {{}};
  }} catch {{}}
  const config = {{ ...defaults, projects: {{ ...defaults.projects, ...saved }} }};
  const onSave = (name, project) => {{
    if (project) saved[name] = project;
    else delete saved[name];
    localStorage.setItem(STORAGE_KEY, JSON.stringify({{ projects: saved }}));
  }};
  ({read("inject.js")})({{ config, icons: {read("icons.json")}, onSave }});
}})();
"""
    os.makedirs(os.path.dirname(SNIPPET), exist_ok=True)
    with open(SNIPPET, "w") as f:
        f.write(snippet)
    return snippet


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


def install_snippet(data, snippet):
    preferences = data.setdefault("electron", {}).setdefault("devtools", {}).setdefault("preferences", {})
    snippets = [s for s in json.loads(preferences.get("script-snippets", "[]")) if s.get("name") != SNIPPET_NAME]
    snippets.append({"name": SNIPPET_NAME, "content": snippet})
    preferences["script-snippets"] = json.dumps(snippets, separators=(",", ":"), ensure_ascii=False)
    preferences.setdefault("script-snippets-last-identifier", "1")
    # In its own window, DevTools can be closed with ⌘W without closing Claude's window.
    preferences["currentDockState"] = json.dumps("undocked")


def main():
    snippet = build_snippet()
    print(f"Built the snippet ({len(snippet) // 1024} KB).")

    # Claude rewrites its preferences when it quits, so they can only change while it's closed.
    if claude_is_running():
        print("Quit Claude (⌘Q) to finish the setup. Waiting…")
        while claude_is_running():
            time.sleep(1)

    update_json(DEVELOPER_SETTINGS, lambda data: data.update(allowDevTools=True))
    if os.path.exists(PREFERENCES):
        shutil.copy(PREFERENCES, PREFERENCES + ".claude-colors-backup")
    update_json(PREFERENCES, lambda data: install_snippet(data, snippet))
    print("Developer Mode is on and the snippet is saved in Claude's DevTools.")

    subprocess.run(["open", "-b", "com.anthropic.claudefordesktop"], check=True)
    print("Claude is reopening. To apply the colors: ⌥⌘I, then ⌘P, type !claude-colors, press Enter.")


if __name__ == "__main__":
    main()
