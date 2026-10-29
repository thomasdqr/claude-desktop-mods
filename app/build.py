#!/usr/bin/env python3
"""Build the Claude Desktop Mods app into ~/Applications/Claude Desktop Mods.app.

Needs the Xcode command line tools (swiftc).
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
APP = os.path.expanduser("~/Applications/Claude Desktop Mods.app")
EXECUTABLE = "ClaudeDesktopMods"
BUNDLE_ID = "local.claude-desktop-mods"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def build_icon(resources):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                subprocess.run(
                    ["sips", "-z", str(size * scale), str(size * scale), os.path.join(HERE, "AppIcon.png"),
                     "--out", os.path.join(iconset, name)],
                    check=True, capture_output=True,
                )
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(resources, "AppIcon.icns")], check=True)


def main():
    running = subprocess.run(["pgrep", "-f", f"{APP}/Contents/MacOS/{EXECUTABLE}"], capture_output=True)
    if running.returncode == 0:
        sys.exit("Claude Desktop Mods is running. Quit it from its menu bar icon first.")

    # Compile before touching the installed app, so a failed build doesn't leave a broken one.
    binary = os.path.join(tempfile.mkdtemp(), EXECUTABLE)
    compiled = subprocess.run(
        ["swiftc", "-O", "-parse-as-library", "-swift-version", "5",
         "-target", f"{platform.machine()}-apple-macos14.0",
         os.path.join(HERE, "ClaudeDesktopMods.swift"), "-o", binary],
    )
    if compiled.returncode != 0:
        sys.exit("\nThe app didn't compile (errors above). Installing Xcode from the App Store, "
                 "or updating the command line tools with `xcode-select --install`, usually fixes it.")

    shutil.rmtree(APP, ignore_errors=True)
    macos = os.path.join(APP, "Contents", "MacOS")
    resources = os.path.join(APP, "Contents", "Resources")
    os.makedirs(macos)
    os.makedirs(resources)
    shutil.move(binary, os.path.join(macos, EXECUTABLE))
    build_icon(resources)

    info = {
        "CFBundleName": "Claude Desktop Mods",
        "CFBundleDisplayName": "Claude Desktop Mods",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleExecutable": EXECUTABLE,
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        # Lives in the menu bar, without a Dock icon.
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "CDMRepo": REPO,
    }
    with open(os.path.join(APP, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump(info, f)

    # An ad-hoc signature only names the exact build, so macOS would forget the Accessibility
    # permission on each rebuild, or not match it at all. Naming the app by its ID instead
    # keeps the permission tied to Claude Desktop Mods.
    requirement = f'designated => identifier "{BUNDLE_ID}"'
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", "-r=" + requirement, APP],
                   check=True, capture_output=True)
    subprocess.run([LSREGISTER, "-f", APP], check=True)
    print(f"Built {APP}")


if __name__ == "__main__":
    main()
