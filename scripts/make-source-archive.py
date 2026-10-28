#!/usr/bin/env python3
"""Builds the "corresponding source" archive for a release (GPL compliance).

    scripts/make-source-archive.py OUT.tar.gz [--manifest PATH]

The Flatpak bundle we publish contains GPL software (mpv; FFmpeg built
with --enable-gpl --enable-version3, i.e. GPL-3.0-or-later). Whoever
distributes those binaries must make their exact source available, so every
release carries this archive next to the bundle (docs/DECISIONS.md D36).

It contains, for every module of the Flatpak manifest:
  - git sources: the pinned commit, with its submodules (flatpak-builder
    builds them too), without .git directories;
  - archive/file sources: the original download, checksum-verified;
  - the app itself (the `dir` source): `git archive` of this repository's
    HEAD, i.e. the tagged release when run by CI.
plus the manifest and a SOURCES.md index. The Freedesktop runtime is not
included: it is distributed by Flathub, which provides its source.

Needs git, curl and PyYAML (python3-yaml); no Flatpak tooling.
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEFAULT_MANIFEST = os.path.join(ROOT, "packaging", "flatpak", "io.github.nicocarbone.DeckVideoPlayer.yml")


# No automatic gc / maintenance: a background git process could still be
# writing in .git (e.g. .git/modules) while it is removed below. The
# environment form also reaches the git processes of submodule updates.
GIT_ENV = dict(os.environ, GIT_CONFIG_COUNT="2",
               GIT_CONFIG_KEY_0="gc.auto", GIT_CONFIG_VALUE_0="0",
               GIT_CONFIG_KEY_1="maintenance.auto", GIT_CONFIG_VALUE_1="false")


def run(*cmd, cwd=None):
    env = GIT_ENV if cmd[0] == "git" else None
    subprocess.run(cmd, cwd=cwd, check=True, stdout=subprocess.DEVNULL, env=env)


def remove_tree(path):
    """shutil.rmtree, retried briefly if something still writes in it."""
    for attempt in range(5):
        try:
            shutil.rmtree(path)
            return
        except OSError:
            if attempt == 4:
                raise
            time.sleep(2)


def log(*a):
    print("[sources]", *a, flush=True)


def modules(manifest):
    """All modules, depth first (manifests may nest them)."""
    for mod in manifest.get("modules", []):
        if isinstance(mod, dict):
            yield mod
            yield from modules(mod)


def fetch_git(url, commit, dest):
    os.makedirs(dest)
    run("git", "init", "-q", cwd=dest)
    run("git", "remote", "add", "origin", url, cwd=dest)
    run("git", "fetch", "-q", "--depth", "1", "origin", commit, cwd=dest)
    run("git", "checkout", "-q", "FETCH_HEAD", cwd=dest)
    if os.path.exists(os.path.join(dest, ".gitmodules")):
        run("git", "submodule", "update", "-q", "--init", "--recursive", "--depth", "1", cwd=dest)
    for dirpath, dirnames, filenames in os.walk(dest):
        if ".git" in dirnames:
            remove_tree(os.path.join(dirpath, ".git"))
            dirnames.remove(".git")
        if ".git" in filenames:  # submodule gitlink file
            os.remove(os.path.join(dirpath, ".git"))


def fetch_file(url, sha256, dest_dir, name=None):
    os.makedirs(dest_dir, exist_ok=True)
    path = os.path.join(dest_dir, name or os.path.basename(url.rstrip("/")))
    run("curl", "-fsSL", "--retry", "3", "-o", path, url)
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if sha256 and digest != sha256:
        sys.exit(f"checksum mismatch for {url}: {digest} != {sha256}")
    return os.path.basename(path)


def main():
    ap = argparse.ArgumentParser(description="Build the corresponding-source archive")
    ap.add_argument("out")
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    args = ap.parse_args()
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML is needed (python3-yaml)")
    manifest = yaml.safe_load(open(args.manifest))
    app_id = manifest.get("id", "app")
    head = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True,
                          check=True).stdout.strip()

    work = tempfile.mkdtemp(prefix="dvp-sources-")
    top = os.path.join(work, f"{app_id}-sources")
    os.makedirs(top)
    index = [f"# Corresponding source for {app_id}\n",
             f"App source: this repository at commit `{head}` (in `deckvideoplayer/`).\n",
             "Third-party modules, exactly as pinned in the Flatpak manifest "
             f"(`{os.path.basename(args.manifest)}`, included):\n",
             "| Module | Source | Revision / SHA-256 | Folder |", "|---|---|---|---|"]
    try:
        for mod in modules(manifest):
            name = mod["name"]
            for src in mod.get("sources", []):
                if not isinstance(src, dict):
                    continue
                kind = src.get("type")
                if kind == "git":
                    folder = f"{name}-{src['commit'][:12]}"
                    log("git", name, src["url"], src["commit"][:12])
                    fetch_git(src["url"], src["commit"], os.path.join(top, folder))
                    index.append(f"| {name} | {src['url']} (tag {src.get('tag', '-')}) | `{src['commit']}` | `{folder}/` |")
                elif kind in ("archive", "file"):
                    folder = name
                    log(kind, name, src["url"])
                    # GitHub API tarball URLs ("…/tarball/release-3.0.6") have no
                    # archive extension: name them after the module.
                    base = src["url"].rstrip("/").rsplit("/", 1)[-1]
                    fname = None if re.search(r"\.(tar\.\w+|tgz|zip)$", base) else f"{name}.tar.gz"
                    got = fetch_file(src["url"], src.get("sha256"), os.path.join(top, folder), fname)
                    index.append(f"| {name} | {src['url']} | `{src.get('sha256', '')}` | `{folder}/{got}` |")
                elif kind == "dir":
                    log("app", name, "git archive", head[:12])
                    dest = os.path.join(top, "deckvideoplayer")
                    os.makedirs(dest)
                    tar = subprocess.run(["git", "-C", ROOT, "archive", "--format=tar", "HEAD"],
                                         capture_output=True, check=True).stdout
                    subprocess.run(["tar", "-x", "-C", dest], input=tar, check=True)
                else:
                    sys.exit(f"unsupported source type {kind!r} in module {name}")
        shutil.copy(args.manifest, top)
        index.append("\nThe Freedesktop Platform runtime (org.freedesktop.Platform) is "
                     "distributed by Flathub, which publishes its source.\n"
                     "Licences of each component are in its folder; the built Flatpak also "
                     "carries them in /app/share/licenses/.\n")
        with open(os.path.join(top, "SOURCES.md"), "w") as f:
            f.write("\n".join(index) + "\n")
        log("writing", args.out)
        with tarfile.open(args.out, "w:gz") as tar:
            tar.add(top, arcname=os.path.basename(top))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    log("done:", f"{os.path.getsize(args.out) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
