#!/usr/bin/env python3
"""Seed a throwaway KOReader home with a public-domain library.

Books come from tools/make_dummy_library.py (generated covers, Calibre
metadata, a few sidecars). They are cached outside the repo. This script
writes the KOReader settings that open Library GUI on that library.

    seed.py --home DIR [--count N] [--seed N]

--home is the KOReader HOME. Settings and history go in HOME/.config/koreader.
The books themselves stay in the cache; settings point at them.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DUMMY = ROOT / "tools" / "make_dummy_library.py"


def lua_str(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def cache_root():
    explicit = os.environ.get("KOREADER_CACHE_ROOT")
    if explicit:
        return Path(explicit)
    base = os.environ.get("XDG_CACHE_HOME")
    if base:
        return Path(base) / "koreader-library-gui"
    return Path.home() / ".cache" / "koreader-library-gui"


def ensure_library(dest, count, seed):
    """Generate straight into dest so sidecar and history paths stay valid."""
    stamp = dest / ".seed-stamp"
    want = f"{count} {seed}\n"
    if stamp.is_file() and stamp.read_text(encoding="utf-8") == want and (dest / "metadata.calibre").is_file():
        print(f"reusing {dest}", file=sys.stderr)
        return dest
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    try:
        subprocess.check_call(
            [sys.executable, str(DUMMY), "--out", str(dest), "--count", str(count), "--seed", str(seed)]
        )
    except Exception:
        shutil.rmtree(dest, ignore_errors=True)
        raise
    stamp.write_text(want, encoding="utf-8")
    print(f"seeded {dest}", file=sys.stderr)
    return dest


def write_settings(home, library):
    data = home / ".config" / "koreader"
    (data / "settings").mkdir(parents=True, exist_ok=True)
    history = library / "koreader" / "history.lua"
    if history.is_file():
        shutil.copy(history, data / "history.lua")
    collection = library / "koreader" / "settings" / "collection.lua"
    if collection.is_file():
        shutil.copy(collection, data / "settings" / "collection.lua")
    # quickstart_shown_version must be >= KOReader's quickstart_force_show_version
    # (2021070000 in v2026.07.1) or the desktop build opens the guide instead of
    # the file browser. color_rendering skips the one-time color notice.
    settings = f"""return {{
    ["home_dir"] = {lua_str(library)},
    ["start_with"] = "filemanager",
    ["quickstart_shown_version"] = 2026070100,
    ["color_rendering"] = true,
    ["emulator_fake_wifi_connected"] = false,
    -- The statistics importer's "Tap to continue" notice would sit on the
    -- library until something dismisses it. Reading state comes from sidecars.
    ["plugins_disabled"] = {{
        ["statistics"] = true,
    }},
    ["library_plugin"] = {{
        ["start_with_library"] = true,
        ["root"] = {lua_str(library)},
        ["show_continue"] = false,
        ["view"] = "grid",
        ["columns"] = 4,
        ["sort"] = "title",
        ["show_clock"] = true,
        ["show_battery"] = true,
    }},
}}
"""
    (data / "settings.reader.lua").write_text(settings, encoding="utf-8")
    print(f"settings {data / 'settings.reader.lua'}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description="Seed a KOReader home for the emulator harness")
    ap.add_argument("--home", required=True, help="KOReader HOME (config is written under .config/koreader)")
    ap.add_argument("--count", type=int, default=200, help="how many public-domain books to generate")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    try:
        import PIL  # noqa: F401  (make_dummy_library needs it)
    except ImportError:
        sys.exit("Pillow is required (the dummy covers). Install it with: pip install pillow")
    home = Path(args.home).resolve()
    home.mkdir(parents=True, exist_ok=True)
    dest = cache_root() / "dummy-library" / f"count-{args.count}-seed-{args.seed}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    library = ensure_library(dest, args.count, args.seed)
    write_settings(home, library.resolve())


if __name__ == "__main__":
    main()
