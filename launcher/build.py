#!/usr/bin/env python3
"""Build the Claude Colors launcher into ~/Applications/Claude Colors.app.

Needs the Xcode command line tools (swiftc). The app icon is Claude's, recolored as a
rainbow, which needs Pillow; without it the app keeps a plain icon.
"""
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
APP = os.path.expanduser("~/Applications/Claude Colors.app")
EXECUTABLE = "ClaudeColors"
CLAUDE_ICON = "/Applications/Claude.app/Contents/Resources/electron.icns"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def build_icon(resources):
    try:
        sys.path.insert(0, REPO)
        from patch import recolor_image
    except ImportError:
        print("Pillow is missing, so the app keeps a plain icon.")
        return None
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        subprocess.run(["iconutil", "-c", "iconset", CLAUDE_ICON, "-o", iconset], check=True)
        for name in os.listdir(iconset):
            recolor_image(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(resources, "AppIcon.icns")], check=True)
    return "AppIcon"


def main():
    running = subprocess.run(["pgrep", "-f", f"{APP}/Contents/MacOS/{EXECUTABLE}"], capture_output=True)
    if running.returncode == 0:
        sys.exit("Claude Colors is running. Quit it from its menu bar icon first.")

    # Compile before touching the installed app, so a failed build doesn't leave a broken one.
    binary = os.path.join(tempfile.mkdtemp(), EXECUTABLE)
    compiled = subprocess.run(
        ["swiftc", "-O", "-parse-as-library", "-swift-version", "5",
         "-target", f"{platform.machine()}-apple-macos14.0",
         os.path.join(HERE, "ClaudeColors.swift"), "-o", binary],
    )
    if compiled.returncode != 0:
        sys.exit("\nThe launcher didn't compile (errors above). Installing Xcode from the App Store, "
                 "or updating the command line tools with `xcode-select --install`, usually fixes it.")

    shutil.rmtree(APP, ignore_errors=True)
    macos = os.path.join(APP, "Contents", "MacOS")
    resources = os.path.join(APP, "Contents", "Resources")
    os.makedirs(macos)
    os.makedirs(resources)
    shutil.move(binary, os.path.join(macos, EXECUTABLE))
    info = {
        "CFBundleName": "Claude Colors",
        "CFBundleDisplayName": "Claude Colors",
        "CFBundleIdentifier": "local.claude-colors.launcher",
        "CFBundleExecutable": EXECUTABLE,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        # Lives in the menu bar, without a Dock icon.
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "ClaudeColorsRepo": REPO,
    }
    icon = build_icon(resources)
    if icon:
        info["CFBundleIconFile"] = icon
    with open(os.path.join(APP, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump(info, f)

    # An ad-hoc signature only names the exact build, so macOS would forget the Accessibility
    # permission on each rebuild, or not match it at all. Naming the app by its ID instead
    # keeps the permission tied to Claude Colors.
    requirement = f'designated => identifier "{info["CFBundleIdentifier"]}"'
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", "-r=" + requirement, APP],
                   check=True, capture_output=True)
    subprocess.run([LSREGISTER, "-f", APP], check=True)
    print(f"Built {APP}")


if __name__ == "__main__":
    main()
