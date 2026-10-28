#!/usr/bin/env python3
"""Build the DevTools snippet: one file that styles the Claude desktop sidebar.

Run it once to build the snippet and copy it to the clipboard, then paste it into
DevTools (see README). The snippet starts from config.json; picker choices are
then saved in the app's own storage, so they survive restarts.
"""
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "dist", "claude-colors-snippet.js")


def read(name):
    with open(os.path.join(HERE, name)) as f:
        return f.read().strip()


if not os.path.exists(os.path.join(HERE, "config.json")):
    shutil.copy(os.path.join(HERE, "config.example.json"), os.path.join(HERE, "config.json"))


snippet = f"""// Claude Colors: run in the DevTools of the Claude desktop app's claude.ai page.
(() => {{
  const STORAGE_KEY = "claude-colors";
  let config;
  try {{
    config = JSON.parse(localStorage.getItem(STORAGE_KEY));
  }} catch {{}}
  config ??= {read("config.json")};
  const onSave = (name, project) => {{
    if (project) config.projects[name] = project;
    else delete config.projects[name];
    localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
  }};
  ({read("inject.js")})({{ config, icons: {read("icons.json")}, onSave }});
}})();
"""

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    f.write(snippet)
subprocess.run(["pbcopy"], input=snippet.encode(), check=True)
print(f"Built {OUT} ({len(snippet) // 1024} KB) and copied it to the clipboard.")
