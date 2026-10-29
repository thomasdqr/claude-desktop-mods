#!/usr/bin/env python3
"""Remove Claude Desktop Mods from the Claude desktop app. Run it from Terminal.

Once Claude is quit, it removes the mods' snippet from Claude's DevTools and turns
Developer Mode off, unless it was on before CDM. It deletes the Preferences backup
install.py made, then reopens Claude. It touches nothing else of Claude: not the app,
not your conversations or settings. What the mods saved stays in Claude's storage,
unused, so a reinstall picks it up again.
"""
import json
import os
import subprocess
import time

from install import (DEVELOPER_SETTINGS, OLD_SNIPPET_NAMES, PREFERENCES, SETTINGS, SNIPPET_NAME, claude_is_running,
                     read_json, save_settings, update_json)


def remove_snippets(data):
    preferences = data.get("electron", {}).get("devtools", {}).get("preferences", {})
    if "script-snippets" in preferences:
        removed = {SNIPPET_NAME, *OLD_SNIPPET_NAMES}
        kept = [s for s in json.loads(preferences["script-snippets"]) if s.get("name") not in removed]
        preferences["script-snippets"] = json.dumps(kept, separators=(",", ":"), ensure_ascii=False)


def main():
    if claude_is_running():
        print("Quit Claude (⌘Q) to finish the uninstall. Waiting…")
        while claude_is_running():
            time.sleep(1)

    settings = read_json(SETTINGS) if os.path.exists(SETTINGS) else {}
    if os.path.exists(DEVELOPER_SETTINGS) and not settings.get("developerModeWasOn"):
        update_json(DEVELOPER_SETTINGS, lambda data: data.update(allowDevTools=False))
    if "developerModeWasOn" in settings:
        # The next install notes it again.
        del settings["developerModeWasOn"]
        save_settings(settings)
    if os.path.exists(PREFERENCES):
        update_json(PREFERENCES, remove_snippets)
    if os.path.exists(PREFERENCES + ".cdm-backup"):
        os.remove(PREFERENCES + ".cdm-backup")
    print("The mods are removed from Claude's DevTools, and Developer Mode is back as it was.")

    subprocess.run(["open", "-b", "com.anthropic.claudefordesktop"], check=True)
    print("Claude is reopening, without mods.")


if __name__ == "__main__":
    main()
