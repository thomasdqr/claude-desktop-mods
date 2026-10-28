#!/usr/bin/env python3
"""Build "Claude Colors.app": a copy of /Applications/Claude.app whose sidebar
shows project colors and icons. The original app is left untouched.

Run it again after each Claude update. Colors and icons live in config.json and
the styling logic in inject.js; the app applies edits to both live.
"""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops

SRC = "/Applications/Claude.app"
DST = os.path.expanduser("~/Applications/Claude Colors.app")
HERE = os.path.dirname(os.path.abspath(__file__))
BLOCK_SIZE = 4 * 1024 * 1024
LOADER_NAME = "claude-colors.js"
# The six pride flag colors along the icon's diagonal, as (position 0-1, hue in degrees):
# red, orange, yellow, green, blue, violet. The ends sit inside the rounded corners, so
# each color gets its own visible band.
RAINBOW = [(0.12, 0), (0.27, 33), (0.42, 56), (0.57, 137), (0.72, 224), (0.88, 290)]
ICON_HUE = 15
ICON_SATURATION_BOOST = 1.35


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# Electron checks each file read from the archive against these hashes.
def integrity(data):
    blocks = [sha256(data[i:i + BLOCK_SIZE]) for i in range(0, len(data), BLOCK_SIZE)]
    return {"algorithm": "SHA256", "hash": sha256(data), "blockSize": BLOCK_SIZE, "blocks": blocks}


def patch_asar(asar_path):
    with open(asar_path, "rb") as f:
        _, pickle_size, _, header_len = struct.unpack("<4I", f.read(16))
        header = json.loads(f.read(header_len))
        data_start = 8 + pickle_size
        f.seek(0, os.SEEK_END)
        data_end = f.tell() - data_start

        package_entry = header["files"]["package.json"]
        f.seek(data_start + int(package_entry["offset"]))
        package = json.loads(f.read(package_entry["size"]))

    build_dir = header["files"][".vite"]["files"]["build"]["files"]
    if package["main"].endswith(LOADER_NAME):
        sys.exit("The source app is already patched. Reinstall Claude first.")
    original_main = os.path.basename(package["main"])

    with open(os.path.join(HERE, "loader.js")) as f:
        loader = f.read().replace("__CLAUDE_COLORS_DIR__", json.dumps(HERE))
    loader = loader.replace('require("./index.pre.js")', f'require("./{original_main}")').encode()
    package["main"] = f".vite/build/{LOADER_NAME}"
    package_bytes = json.dumps(package, indent=2).encode()

    # New content goes after the existing data, so no existing offset moves.
    appended = b""
    for entry, content in ((package_entry, package_bytes), (build_dir.setdefault(LOADER_NAME, {}), loader)):
        entry.clear()
        entry.update(size=len(content), offset=str(data_end + len(appended)), integrity=integrity(content))
        appended += content

    header_bytes = json.dumps(header, separators=(",", ":")).encode()
    padding = (4 - len(header_bytes) % 4) % 4
    payload_size = 4 + len(header_bytes) + padding
    prefix = struct.pack("<4I", 4, payload_size + 4, payload_size, len(header_bytes))

    tmp_path = asar_path + ".tmp"
    with open(asar_path, "rb") as src, open(tmp_path, "wb") as out:
        out.write(prefix + header_bytes + b"\0" * padding)
        src.seek(data_start)
        shutil.copyfileobj(src, out)
        out.write(appended)
    os.replace(tmp_path, asar_path)
    return sha256(header_bytes)


def rainbow_hue(position):
    if position <= RAINBOW[0][0]:
        return RAINBOW[0][1]
    for (start, start_hue), (end, end_hue) in zip(RAINBOW, RAINBOW[1:]):
        if position <= end:
            delta = (end_hue - start_hue + 180) % 360 - 180
            return start_hue + delta * (position - start) / (end - start)
    return RAINBOW[-1][1]


def recolor_image(path):
    image = Image.open(path).convert("RGBA")
    hue, saturation, value = image.convert("RGB").convert("HSV").split()
    # Top-right corner is 0, bottom-left is 255.
    diagonal = ImageChops.add(
        Image.linear_gradient("L").rotate(90).transpose(Image.FLIP_LEFT_RIGHT),
        Image.linear_gradient("L"),
        scale=2,
    ).resize(image.size)
    shift = diagonal.point(lambda v: round((rainbow_hue(v / 255) - ICON_HUE) * 256 / 360) % 256)
    hue = ImageChops.add_modulo(hue, shift)
    saturation = saturation.point(lambda v: min(255, round(v * ICON_SATURATION_BOOST)))
    recolored = Image.merge("HSV", (hue, saturation, value)).convert("RGB")
    recolored.putalpha(image.getchannel("A"))
    recolored.save(path)


# Swaps the orange of the app icon for a gradient, so the copy stands out in the Dock.
def recolor_icon(app_path):
    icns = f"{app_path}/Contents/Resources/electron.icns"
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "icon.iconset")
        subprocess.run(["iconutil", "-c", "iconset", icns, "-o", iconset], check=True)
        for name in os.listdir(iconset):
            recolor_image(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    # Without this key macOS reads the original icon from Assets.car instead.
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Delete :CFBundleIconName", f"{app_path}/Contents/Info.plist"], check=True)


def main():
    if not os.path.isdir(SRC):
        sys.exit(f"{SRC} not found.")
    if subprocess.run(["pgrep", "-f", f"{DST}/Contents/MacOS/"], capture_output=True).returncode == 0:
        sys.exit("Claude Colors is running. Quit it first.")
    config = os.path.join(HERE, "config.json")
    if not os.path.exists(config):
        shutil.copy(os.path.join(HERE, "config.example.json"), config)

    version = subprocess.check_output(
        ["defaults", "read", f"{SRC}/Contents/Info.plist", "CFBundleShortVersionString"], text=True
    ).strip()
    print(f"Building Claude Colors from Claude {version}")

    shutil.rmtree(DST, ignore_errors=True)
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    subprocess.run(["ditto", SRC, DST], check=True)

    header_hash = patch_asar(f"{DST}/Contents/Resources/app.asar")
    subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", f"Set :ElectronAsarIntegrity:Resources/app.asar:hash {header_hash}",
         f"{DST}/Contents/Info.plist"],
        check=True,
    )
    recolor_icon(DST)
    subprocess.run(["xattr", "-cr", DST], check=True)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", DST], check=True, capture_output=True)
    subprocess.run(["codesign", "--verify", "--deep", DST], check=True)
    print(f"Done: {DST}")


if __name__ == "__main__":
    main()
