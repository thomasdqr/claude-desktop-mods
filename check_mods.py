#!/usr/bin/env python3
"""Check every mod in mods/ before it reaches the catalog. CI runs it on each pull request.

    python3 check_mods.py                     check the manifests, the code and the bundle
    python3 check_mods.py --base origin/main  also require a version bump for each changed mod,
                                              and for the app

Exits with 1 and lists the problems when there are any.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

from install import HERE, MODS, bundle_mod, load_mods, read_text

ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
VERSION = re.compile(r"^\d+\.\d+\.\d+$")
COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")
REQUIRED = ["id", "name", "version", "description", "author", "main"]
# A mod runs with the user's Claude session, so it must ship all of its code for review.
FORBIDDEN = {
    r"\beval\s*\(": "eval()",
    r"\bnew\s+Function\b": "new Function",
    r"\bimport\s*\(": "import()",
    r"\bfetch\s*\(": "fetch()",
    r"\bXMLHttpRequest\b": "XMLHttpRequest",
    r"\bWebSocket\b": "WebSocket",
    r"createElement\(\s*['\"]script": "a <script> element",
}


def check_settings(settings):
    problems, keys = [], set()
    for spec in settings:
        key, kind, default = spec.get("key"), spec.get("type"), spec.get("default")
        if not key or key in keys:
            problems.append(f"setting {key!r}: needs a unique key")
        keys.add(key)
        if kind != "hidden" and not spec.get("label"):
            problems.append(f"setting {key!r}: needs a label")
        if kind == "toggle" and not isinstance(default, bool):
            problems.append(f"setting {key!r}: a toggle's default is true or false")
        elif kind == "choice":
            values = [option.get("value") for option in spec.get("options", [])]
            if not values or default not in values:
                problems.append(f"setting {key!r}: a choice needs options and a default among them")
        elif kind == "number":
            low, high = spec.get("min"), spec.get("max")
            if not all(isinstance(n, int) for n in (low, high, default)) or not low <= default <= high:
                problems.append(f"setting {key!r}: a number needs whole min, max and default, in that order")
        elif kind not in ("toggle", "choice", "number", "hidden"):
            problems.append(f"setting {key!r}: type is choice, toggle, number or hidden")
    return problems


def check_mod(folder, manifest):
    problems = [f"missing {field!r}" for field in REQUIRED if not manifest.get(field)]
    mod_id = manifest.get("id", "")
    if mod_id != os.path.basename(folder) or not ID.match(mod_id):
        problems.append("id must be the folder's name, in lowercase-with-dashes")
    if not VERSION.match(manifest.get("version", "")):
        problems.append("version must look like 1.2.3")
    icon = manifest.get("icon", {})
    if icon and (not icon.get("symbol") or not COLOR.match(icon.get("color", ""))):
        problems.append('icon needs an SF Symbol name and a color like "#F0609E"')
    problems += check_settings(manifest.get("settings", []))
    for name, path in manifest.get("assets", {}).items():
        try:
            json.loads(read_text(os.path.join(folder, path)))
        except (OSError, ValueError):
            problems.append(f"asset {name!r}: {path} must be a JSON file in the mod's folder")
    main = os.path.join(folder, manifest.get("main", ""))
    if not os.path.isfile(main):
        return problems + [f"{manifest.get('main')} doesn't exist"]
    code = read_text(main)
    if not re.search(r"\bfunction\s+activate\s*\(", code):
        problems.append(f"{manifest['main']} must define function activate(api)")
    problems += [f"{manifest['main']} uses {what}" for pattern, what in FORBIDDEN.items() if re.search(pattern, code)]
    return problems


def check_bundle(mods):
    """The bundle install.py would make with every mod on must at least parse."""
    if not shutil.which("node"):
        return []
    bundled = ",\n".join(bundle_mod(folder, manifest, {}) for folder, manifest in mods)
    code = f"({read_text(os.path.join(HERE, 'runtime', 'runtime.js'))})([{bundled}]);"
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(code)
    result = subprocess.run(["node", "--check", f.name], capture_output=True, text=True)
    os.remove(f.name)
    return [] if result.returncode == 0 else [f"the bundle doesn't parse:\n{result.stderr.strip()}"]


def git(*args):
    return subprocess.run(["git", "-C", HERE, *args], capture_output=True, text=True).stdout


def version_tuple(version):
    return tuple(int(part) for part in version.split("."))


def check_versions(mods, base):
    """A changed mod needs a higher version, or the app can't tell users to update."""
    changed = {path.split("/")[1] for path in git("diff", "--name-only", f"{base}...HEAD", "--", "mods").split()}
    problems = []
    for folder, manifest in mods:
        mod_id = os.path.basename(folder)
        old = git("show", f"{base}:mods/{mod_id}/manifest.json")
        if mod_id not in changed or not old:
            continue
        old_version = json.loads(old)["version"]
        if version_tuple(manifest["version"]) <= version_tuple(old_version):
            problems.append(f"{mod_id}: changed, so its version must go above {old_version}")
    old_app = git("show", f"{base}:app/VERSION").strip()
    app_version = read_text(os.path.join(HERE, "app", "VERSION")).strip()
    if old_app and git("diff", "--name-only", f"{base}...HEAD", "--", "app").strip() \
            and version_tuple(app_version) <= version_tuple(old_app):
        problems.append(f"app: changed, so app/VERSION must go above {old_app}")
    return problems


def main():
    mods = load_mods()
    folders = sorted(os.listdir(MODS))
    problems = [f"mods/{name}: no manifest.json" for name in folders
                if os.path.isdir(os.path.join(MODS, name)) and name not in {os.path.basename(f) for f, _ in mods}]
    for folder, manifest in mods:
        problems += [f"mods/{os.path.basename(folder)}: {p}" for p in check_mod(folder, manifest)]
    if not problems:
        problems += check_bundle(mods)
    if "--base" in sys.argv:
        problems += check_versions(mods, sys.argv[sys.argv.index("--base") + 1])
    for problem in problems:
        print(f"✗ {problem}")
    if problems:
        sys.exit(1)
    print(f"✓ {len(mods)} mod(s) look good: {', '.join(m['id'] + '@' + m['version'] for _, m in mods)}")


if __name__ == "__main__":
    main()
