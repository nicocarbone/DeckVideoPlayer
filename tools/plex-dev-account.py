#!/usr/bin/env python3
"""Writes a signed-in plex.json for development/tests from .dev/plex/
(client-id + token created by a link-code sign-in), so headless runs can
browse a real Plex server without going through the dialog.

    tools/plex-dev-account.py DATA_DIR      # e.g. .dev/headless/data

The token stays in git-ignored .dev/ folders. See docs/DEVELOPMENT.md.
"""
import json, os, sys, urllib.request

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
dev = os.path.join(root, ".dev", "plex")
cid = open(os.path.join(dev, "client-id")).read().strip()
token = open(os.path.join(dev, "token")).read().strip()
hdr = {"Accept": "application/json", "X-Plex-Client-Identifier": cid, "X-Plex-Token": token,
       "X-Plex-Product": "Deck Video Player"}
def get(url):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=20))
user = get("https://plex.tv/api/v2/user")
servers = []
for r in get("https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=0&includeIPv6=0"):
    if "server" not in r.get("provides", ""):
        continue
    servers.append({"name": r["name"], "machine": r["clientIdentifier"],
                    "token": r.get("accessToken") or token, "owned": bool(r.get("owned")),
                    "connections": [{"uri": c["uri"], "address": c["address"], "port": c["port"],
                                     "protocol": c["protocol"], "local": c["local"], "relay": c["relay"]}
                                    for c in r["connections"]]})
os.makedirs(sys.argv[1], exist_ok=True)
path = os.path.join(sys.argv[1], "plex.json")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"client_id": cid, "token": token, "username": user.get("username"), "servers": servers}, f)
print(f"wrote {path}: {len(servers)} server(s), user {user.get('username')}")
