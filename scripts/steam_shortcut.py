#!/usr/bin/env python3
"""Add Deck Video Player to Steam as a non-Steam game and install its artwork.

    steam_shortcut.py add       Add the shortcut (Steam must NOT be running)
    steam_shortcut.py artwork   Copy library artwork for an existing shortcut
    steam_shortcut.py remove    Remove the shortcut (Steam must NOT be running)
    steam_shortcut.py repair    Unpin the shortcut from a Flatpak branch
    steam_shortcut.py status    Show the shortcut's app id per Steam user

Works on Steam's binary shortcuts.vdf in every local Steam user profile.
"""

import argparse
import binascii
import os
import re
import shutil
import struct
import subprocess
import sys

APP_NAME = "Deck Video Player"
FLATPAK_ID = "io.github.nicocarbone.DeckVideoPlayer"
HERE = os.path.dirname(os.path.abspath(__file__))
ART_DIR = os.path.join(HERE, "..", "packaging", "steam")

# Steam artwork naming: <appid>p.png portrait capsule, <appid>.png wide
# capsule, <appid>_hero.png hero banner, <appid>_logo.png logo.
ARTWORK = {
    "p.png": "capsule.png",
    ".png": "header.png",
    "_hero.png": "hero.png",
    "_logo.png": "logo.png",
    "_icon.png": "icon.png",
}


# --- binary VDF ------------------------------------------------------------
#
# Type bytes: 0x00 map, 0x01 string, 0x02 int32, 0x07 uint64, 0x08 end of map.
# Every value read is written back with the same type (round-trip safe).


class UInt64(int):
    """Marks a value read as VDF type 0x07 so it is written back as such."""

def _read_cstr(data, i):
    end = data.index(b"\x00", i)
    return data[i:end].decode("utf-8", "replace"), end + 1


def vdf_load(data, i=0):
    out = {}
    while i < len(data):
        t = data[i]
        i += 1
        if t == 0x08:
            return out, i
        key, i = _read_cstr(data, i)
        if t == 0x00:
            out[key], i = vdf_load(data, i)
        elif t == 0x01:
            out[key], i = _read_cstr(data, i)
        elif t == 0x02:
            out[key] = struct.unpack_from("<i", data, i)[0]
            i += 4
        elif t == 0x07:
            out[key] = UInt64(struct.unpack_from("<Q", data, i)[0])
            i += 8
        else:
            raise ValueError("unsupported VDF type 0x%02x at %d" % (t, i))
    return out, i


def vdf_dump(obj):
    out = bytearray()
    for key, value in obj.items():
        k = key.encode("utf-8") + b"\x00"
        if isinstance(value, dict):
            out += b"\x00" + k + vdf_dump(value)
        elif isinstance(value, str):
            out += b"\x01" + k + value.encode("utf-8") + b"\x00"
        elif isinstance(value, UInt64):
            out += b"\x07" + k + struct.pack("<Q", value)
        elif isinstance(value, int):
            out += b"\x02" + k + struct.pack("<i", value)
        else:
            raise TypeError(key)
    out += b"\x08"
    return bytes(out)


# --- Steam paths -------------------------------------------------------------

def steam_roots():
    home = os.path.expanduser("~")
    candidates = [
        os.path.join(home, ".local/share/Steam"),
        os.path.join(home, ".steam/steam"),
        os.path.join(home, ".var/app/com.valvesoftware.Steam/.local/share/Steam"),
    ]
    seen, out = set(), []
    for c in candidates:
        real = os.path.realpath(c)
        if os.path.isdir(os.path.join(real, "userdata")) and real not in seen:
            seen.add(real)
            out.append(real)
    return out


def user_config_dirs():
    for root in steam_roots():
        userdata = os.path.join(root, "userdata")
        for uid in sorted(os.listdir(userdata)):
            if uid.isdigit() and uid != "0":
                yield os.path.join(userdata, uid, "config")


def steam_running():
    return subprocess.run(["pgrep", "-x", "steam"], stdout=subprocess.DEVNULL).returncode == 0


def load_shortcuts(config_dir):
    path = os.path.join(config_dir, "shortcuts.vdf")
    if not os.path.exists(path):
        return path, {"shortcuts": {}}
    with open(path, "rb") as f:
        data, _ = vdf_load(f.read())
    data.setdefault("shortcuts", {})
    return path, data


def save_shortcuts(path, data):
    """Serialise first, then replace the file atomically, keeping a backup.

    Serialising before touching the file means an error can never leave
    shortcuts.vdf truncated (it holds all of the user's non-Steam games).
    """
    payload = vdf_dump(data)
    if os.path.exists(path):
        shutil.copyfile(path, path + ".bak")
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def find_ours(shortcuts):
    for key, sc in shortcuts["shortcuts"].items():
        name = sc.get("AppName") or sc.get("appname") or ""
        if name == APP_NAME or sc.get("FlatpakAppID") == FLATPAK_ID:
            return key, sc
    return None, None


# "--branch=master" / "--branch master", as copied from the Flatpak menu
# entry by "Add a Non-Steam Game" or steamos-add-to-steam.
BRANCH_RE = re.compile(r"\s*--branch(?:=|\s+)(\S+)")
CURRENT_BRANCH = "stable"   # scripts/build-flatpak.sh and CI


def pinned_branch(sc):
    """The Flatpak branch the shortcut's command line names, or None."""
    for field in ("Exe", "LaunchOptions"):
        value = sc.get(field)
        m = isinstance(value, str) and BRANCH_RE.search(value)
        if m:
            return m.group(1)
    return None


def unpin_branch(sc):
    """Removes a Flatpak branch from the shortcut's command line, so it keeps
    working when the app moves to another branch (v0.3.3: master -> stable).
    Returns True if anything changed."""
    changed = False
    for field in ("Exe", "LaunchOptions"):
        value = sc.get(field)
        if isinstance(value, str) and BRANCH_RE.search(value):
            sc[field] = BRANCH_RE.sub("", value).strip()
            changed = True
    return changed


def unsigned(appid):
    return appid & 0xFFFFFFFF


# --- commands --------------------------------------------------------------

def shortcut_entry(icon_path):
    exe = '"/usr/bin/flatpak"'
    appid = binascii.crc32((exe + APP_NAME).encode("utf-8")) | 0x80000000
    appid = struct.unpack("<i", struct.pack("<I", appid))[0]
    return {
        "appid": appid,
        "AppName": APP_NAME,
        "Exe": exe,
        "StartDir": '"/usr/bin/"',
        "icon": icon_path,
        "ShortcutPath": "",
        "LaunchOptions": "run --command=deckvideoplayer " + FLATPAK_ID,
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 0,
        "FlatpakAppID": FLATPAK_ID,
        "tags": {},
    }


def install_artwork(config_dir, appid):
    grid = os.path.join(config_dir, "grid")
    os.makedirs(grid, exist_ok=True)
    for suffix, src in ARTWORK.items():
        shutil.copyfile(os.path.join(ART_DIR, src), os.path.join(grid, "%d%s" % (unsigned(appid), suffix)))
    return os.path.join(grid, "%d_icon.png" % unsigned(appid))


def cmd_add(_):
    if steam_running():
        sys.exit("Steam is running. Close it first, or use steamos-add-to-steam.")
    dirs = list(user_config_dirs())
    if not dirs:
        sys.exit("No Steam user profile found.")
    for config_dir in dirs:
        path, data = load_shortcuts(config_dir)
        key, sc = find_ours(data)
        if sc is None:
            key = str(max([int(k) for k in data["shortcuts"] if k.isdigit()] + [-1]) + 1)
            sc = shortcut_entry("")
            data["shortcuts"][key] = sc
        unpin_branch(sc)
        sc["icon"] = install_artwork(config_dir, sc["appid"])
        os.makedirs(config_dir, exist_ok=True)
        save_shortcuts(path, data)
        print("Added to %s (app id %d)" % (path, unsigned(sc["appid"])))


def cmd_artwork(_):
    found = False
    for config_dir in user_config_dirs():
        _, data = load_shortcuts(config_dir)
        _, sc = find_ours(data)
        if sc is not None and "appid" in sc:
            install_artwork(config_dir, sc["appid"])
            print("Artwork installed for %s (app id %d)" % (config_dir, unsigned(sc["appid"])))
            found = True
    if not found:
        sys.exit("Shortcut not found yet. Add it to Steam first, then run this again.")


def cmd_remove(_):
    if steam_running():
        sys.exit("Steam is running. Close it first.")
    for config_dir in user_config_dirs():
        path, data = load_shortcuts(config_dir)
        key, sc = find_ours(data)
        if sc is None:
            continue
        del data["shortcuts"][key]
        # Keep keys contiguous ("0", "1", ...), as Steam writes them.
        data["shortcuts"] = {str(i): v for i, v in enumerate(data["shortcuts"].values())}
        save_shortcuts(path, data)
        for suffix in ARTWORK:
            p = os.path.join(config_dir, "grid", "%d%s" % (unsigned(sc.get("appid", 0)), suffix))
            if os.path.exists(p):
                os.remove(p)
        print("Removed from", path)


def cmd_status(_):
    for config_dir in user_config_dirs():
        _, data = load_shortcuts(config_dir)
        _, sc = find_ours(data)
        if not sc or "appid" not in sc:
            print(config_dir, "-> not added")
            continue
        branch = pinned_branch(sc)
        pinned = " (pinned to Flatpak branch %s: run repair)" % branch if branch else ""
        print(config_dir, "-> app id %d%s" % (unsigned(sc["appid"]), pinned))


def cmd_repair(_):
    """Unpins the app's own shortcut from a Flatpak branch. While Steam runs
    (it would overwrite the change) nothing is written; exit status 3 when
    the shortcut names a branch that no longer exists."""
    todo, broken = [], False
    for config_dir in user_config_dirs():
        path, data = load_shortcuts(config_dir)
        _, sc = find_ours(data)
        branch = sc is not None and pinned_branch(sc)
        if branch:
            broken = broken or branch != CURRENT_BRANCH
            unpin_branch(sc)
            todo.append((path, data))
    if not todo:
        return
    if steam_running():
        if broken:
            print("The Steam shortcut names an old Flatpak branch; close Steam to repair it.")
            sys.exit(3)
        return
    for path, data in todo:
        save_shortcuts(path, data)
        print("Repaired the shortcut in", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["add", "artwork", "remove", "repair", "status"])
    args = parser.parse_args()
    {"add": cmd_add, "artwork": cmd_artwork, "remove": cmd_remove, "repair": cmd_repair,
     "status": cmd_status}[args.command](args)


if __name__ == "__main__":
    main()
