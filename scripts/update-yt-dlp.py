#!/usr/bin/env python3
"""Points the Flatpak manifest at the newest yt-dlp release (D84).

    scripts/update-yt-dlp.py [--manifest PATH] [--notices PATH] [--version TAG]

YouTube changes often break older yt-dlp versions, so the bundled one is
kept current: CI runs this every week (.github/workflows/update-yt-dlp.yml)
and opens a pull request when it changed something; a person merges it and
tags a release. It rewrites the yt-dlp module's two sources (the official
zipapp, checked against the release's SHA2-256SUMS, and its LICENSE) and the
version in THIRD_PARTY_NOTICES.md.

Prints "updated <version>" or "current <version>"; exits 1 on errors. With
GITHUB_TOKEN set, GitHub's API is asked with it (higher rate limits).
"""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MANIFEST = os.path.join(ROOT, "packaging", "flatpak", "io.github.nicocarbone.DeckVideoPlayer.yml")
NOTICES = os.path.join(ROOT, "THIRD_PARTY_NOTICES.md")
RELEASES = "https://github.com/yt-dlp/yt-dlp/releases/download"
RAW = "https://raw.githubusercontent.com/yt-dlp/yt-dlp"
TAG_RE = re.compile(r"^\d{4}\.\d{2}\.\d{2}(\.\d+)?$")


def fetch(url, api=False):
    req = urllib.request.Request(url, headers={"User-Agent": "update-yt-dlp"})
    token = os.environ.get("GITHUB_TOKEN")
    if api and token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def latest_tag():
    data = json.loads(fetch("https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest", api=True))
    return data["tag_name"]


def module_block(text):
    """Where the yt-dlp module is in the manifest: (start, end), or None."""
    start = text.find("\n  - name: yt-dlp\n")
    if start < 0:
        return None
    end = text.find("\n  - name: ", start + 1)
    return start, len(text) if end < 0 else end


def current_tag(text):
    """The yt-dlp release the manifest's yt-dlp module points at, or None."""
    where = module_block(text)
    if not where:
        return None
    m = re.search(re.escape(RELEASES) + r"/([^/\s]+)/yt-dlp\s", text[where[0]:where[1]])
    return m.group(1) if m else None


def sums_entry(sums, name):
    """The SHA-256 of `name` in a SHA2-256SUMS file (lowercase)."""
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("*") == name and re.fullmatch(r"[0-9a-fA-F]{64}", parts[0]):
            return parts[0].lower()
    return None


def rewrite_manifest(text, tag, zipapp_sha, license_sha):
    """The manifest with the yt-dlp module's sources on `tag`. Only that
    module's lines change; raises ValueError if it isn't found as expected."""
    where = module_block(text)
    if not where:
        raise ValueError("no yt-dlp module in the manifest")
    start, end = where
    block = text[start:end]
    new, n1 = re.subn(r"(url: )" + re.escape(RELEASES) + r"/[^/\s]+/yt-dlp\n(\s+sha256: )[0-9a-f]{64}",
                      lambda m: f"{m.group(1)}{RELEASES}/{tag}/yt-dlp\n{m.group(2)}{zipapp_sha}", block)
    new, n2 = re.subn(r"(url: )" + re.escape(RAW) + r"/[^/\s]+/LICENSE\n(\s+sha256: )[0-9a-f]{64}",
                      lambda m: f"{m.group(1)}{RAW}/{tag}/LICENSE\n{m.group(2)}{license_sha}", new)
    if n1 != 1 or n2 != 1:
        raise ValueError("the yt-dlp module's sources aren't in the expected form")
    return text[:start] + new + text[end:]


def rewrite_notices(text, tag):
    new, n = re.subn(r"(\| \[yt-dlp\]\([^)]*\) \| )[^|]+( \|)", lambda m: f"{m.group(1)}{tag}{m.group(2)}", text)
    if n != 1:
        raise ValueError("no yt-dlp row in THIRD_PARTY_NOTICES.md")
    return new


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--notices", default=NOTICES)
    ap.add_argument("--version", help="this release instead of the latest")
    args = ap.parse_args()
    manifest = open(args.manifest, encoding="utf-8").read()
    notices = open(args.notices, encoding="utf-8").read()
    tag = args.version or latest_tag()
    if not TAG_RE.match(tag):
        sys.exit(f"unexpected yt-dlp tag {tag!r}")
    if current_tag(manifest) == tag:
        print("current " + tag)
        return
    zipapp_sha = sums_entry(fetch(f"{RELEASES}/{tag}/SHA2-256SUMS").decode(), "yt-dlp")
    if not zipapp_sha:
        sys.exit(f"no checksum for the yt-dlp zipapp in release {tag}")
    if hashlib.sha256(fetch(f"{RELEASES}/{tag}/yt-dlp")).hexdigest() != zipapp_sha:
        sys.exit(f"the yt-dlp zipapp of {tag} doesn't match its published checksum")
    license_sha = hashlib.sha256(fetch(f"{RAW}/{tag}/LICENSE")).hexdigest()
    try:
        manifest = rewrite_manifest(manifest, tag, zipapp_sha, license_sha)
        notices = rewrite_notices(notices, tag)
    except ValueError as e:
        sys.exit(str(e))
    with open(args.manifest, "w", encoding="utf-8") as f:
        f.write(manifest)
    with open(args.notices, "w", encoding="utf-8") as f:
        f.write(notices)
    print("updated " + tag)


if __name__ == "__main__":
    main()
