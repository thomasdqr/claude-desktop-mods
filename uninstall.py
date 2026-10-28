#!/usr/bin/env python3
"""Remove Claude Colors from the Claude desktop app. Run it from Terminal.

Once Claude is quit, it turns Developer Mode off, removes the snippet from Claude's
DevTools, moves an old patched "Claude Colors.app" to the Trash, then reopens Claude.
Picker choices stay in Claude's storage, unused, so a reinstall picks them up again.
"""
import json
import os
import plistlib
import subprocess
import time

from setup import DEVELOPER_SETTINGS, PREFERENCES, SNIPPET_NAME, claude_is_running, update_json

PATCHED_COPY = os.path.expanduser("~/Applications/Claude Colors.app")


def bundle_id(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except OSError:
        return None


def remove_snippet(data):
    preferences = data.get("electron", {}).get("devtools", {}).get("preferences", {})
    if "script-snippets" in preferences:
        snippets = json.loads(preferences["script-snippets"])
        kept = [s for s in snippets if s.get("name") != SNIPPET_NAME]
        preferences["script-snippets"] = json.dumps(kept, separators=(",", ":"), ensure_ascii=False)


def main():
    if claude_is_running():
        print("Quit Claude (⌘Q) to finish the uninstall. Waiting…")
        while claude_is_running():
            time.sleep(1)

    if os.path.exists(DEVELOPER_SETTINGS):
        update_json(DEVELOPER_SETTINGS, lambda data: data.update(allowDevTools=False))
    if os.path.exists(PREFERENCES):
        update_json(PREFERENCES, remove_snippet)
    print("Developer Mode is off and the snippet is removed from Claude's DevTools.")

    # The launcher lives at the same path, so only the old patched copy, known by its ID, goes.
    if bundle_id(PATCHED_COPY) == "local.claude-colors":
        subprocess.run(
            ["osascript", "-e", f'tell application "Finder" to delete POSIX file "{PATCHED_COPY}"'],
            check=True, capture_output=True,
        )
        print("Moved the old patched Claude Colors.app to the Trash.")

    subprocess.run(["open", "-b", "com.anthropic.claudefordesktop"], check=True)
    print("Claude is reopening, without Claude Colors.")


if __name__ == "__main__":
    main()
