#!/usr/bin/env python3
"""Jellyfin sign-in for development/tests (like tools/plex-dev-account.py).

    tools/jellyfin-dev-account.py login [URL]   # Quick Connect: prints a code
                                                # to approve in Jellyfin
                                                # (profile -> Quick Connect)
    tools/jellyfin-dev-account.py DATA_DIR      # writes a signed-in
                                                # jellyfin.json there, e.g.
                                                # .dev/headless/data

Without URL, `login` finds the server on the LAN (UDP discovery). The token
stays in the git-ignored .dev/jellyfin/ folder and is never printed. See
docs/DEVELOPMENT.md.
"""
import json, os, socket, sys, time, urllib.request, uuid

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
dev = os.path.join(root, ".dev", "jellyfin")
CLIENT = "Deck Video Player"


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)


def device_id():
    os.makedirs(dev, exist_ok=True)
    path = os.path.join(dev, "device-id")
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(uuid.uuid4().hex)
    return open(path).read().strip()


def auth_header(token=None):
    h = f'MediaBrowser Client="{CLIENT}", Device="Development", DeviceId="{device_id()}", Version="dev"'
    if token:
        h += f', Token="{token}"'
    return h


def call(url, method="GET", body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": auth_header(token), "Accept": "application/json",
        "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        text = r.read()
    return json.loads(text) if text else None


def discover():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(0.5)
    s.sendto(b"who is JellyfinServer?", ("255.255.255.255", 7359))
    end = time.time() + 2
    while time.time() < end:
        try:
            data, _ = s.recvfrom(4096)
            return json.loads(data)["Address"]
        except (socket.timeout, ValueError, KeyError):
            pass
    sys.exit("no Jellyfin server answered on the LAN; pass its URL")


def login(url):
    url = (url or discover()).rstrip("/")
    info = call(url + "/System/Info/Public")
    qc = call(url + "/QuickConnect/Initiate", "POST")
    print(f"Approve code {qc['Code']} in Jellyfin (profile -> Quick Connect), waiting up to 10 min…",
          flush=True)
    end = time.time() + 600
    while time.time() < end:
        if call(url + "/QuickConnect/Connect?secret=" + qc["Secret"]).get("Authenticated"):
            break
        time.sleep(3)
    else:
        sys.exit("the code was not approved in time")
    auth = call(url + "/Users/AuthenticateWithQuickConnect", "POST", {"Secret": qc["Secret"]})
    write_private(os.path.join(dev, "account.json"), {
        "url": url, "id": info["Id"], "name": info.get("ServerName") or "Jellyfin",
        "user_id": auth["User"]["Id"], "username": auth["User"]["Name"], "token": auth["AccessToken"]})
    print(f"signed in as {auth['User']['Name']}; saved in .dev/jellyfin/")


def write_data(data_dir):
    acc = json.load(open(os.path.join(dev, "account.json")))
    os.makedirs(data_dir, exist_ok=True)
    path = os.path.join(data_dir, "jellyfin.json")
    write_private(path, {"device_id": device_id(), "servers": [acc]})
    print(f"wrote {path}: 1 server, user {acc['username']}")


if len(sys.argv) >= 2 and sys.argv[1] == "login":
    login(sys.argv[2] if len(sys.argv) > 2 else None)
elif len(sys.argv) == 2:
    write_data(sys.argv[1])
else:
    sys.exit(__doc__)
