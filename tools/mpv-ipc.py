#!/usr/bin/env python3
"""Drive a running mpv / Deck Video Player over its JSON IPC socket.

Used for scripted UI tests (see docs/DEVELOPMENT.md). Each argument is one
step, executed in order:

  key:NAME          press a key, using mpv key names (DOWN, ENTER, BS, x, ...).
                    Keys are what the app binds besides gamepad buttons, see
                    dvp/input.lua for the key -> action table.
  shot:PATH         mpv screenshot including the OSD ("window" mode).
                    Only works while a video is playing.
  gshot:PATH        gamescope screenshot (works on the idle library screen).
                    Needs gamescopectl and a gamescope-N socket in
                    $XDG_RUNTIME_DIR (the newest one is used).
  get:PROPERTY      print an mpv property as JSON
  raw:JSON          send a raw mpv command array, e.g. raw:'["quit"]'
  sleep:SECONDS     wait
  sh:COMMAND        run a shell command on the host

Example:
  tools/mpv-ipc.py /tmp/dvp.sock key:DOWN key:ENTER sleep:2 shot:/tmp/a.png raw:'["quit"]'
"""

import glob
import json
import os
import re
import socket
import subprocess
import sys
import time


def command(sock, cmd):
    """Send one command and return its reply (skipping async events)."""
    sock.sendall((json.dumps({"command": cmd}) + "\n").encode())
    buf = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return None
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if "event" not in msg:
                return msg


def connect(path, attempts=100):
    for _ in range(attempts):
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(path)
            return s
        except OSError:
            time.sleep(0.2)
    sys.exit("could not connect to " + path)


def gamescope_screenshot(path):
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    socks = [p for p in glob.glob(runtime + "/gamescope-*") if re.search(r"gamescope-\d+$", p)]
    if not socks:
        print("gshot: no gamescope socket found", file=sys.stderr)
        return
    newest = max(socks, key=os.path.getmtime)
    env = dict(os.environ, GAMESCOPE_WAYLAND_DISPLAY=os.path.basename(newest))
    subprocess.run(["gamescopectl", "screenshot", path], env=env, stdout=subprocess.DEVNULL)
    time.sleep(0.8)  # gamescope writes the file asynchronously


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sock = connect(sys.argv[1])
    for step in sys.argv[2:]:
        kind, _, value = step.partition(":")
        reply = None
        if kind == "key":
            reply = command(sock, ["keypress", value])
        elif kind == "shot":
            reply = command(sock, ["screenshot-to-file", value, "window"])
        elif kind == "gshot":
            gamescope_screenshot(value)
            continue
        elif kind == "get":
            reply = command(sock, ["get_property", value])
            print(value, "=", json.dumps(reply.get("data") if reply else None))
            continue
        elif kind == "raw":
            reply = command(sock, json.loads(value))
        elif kind == "sleep":
            time.sleep(float(value))
            continue
        elif kind == "sh":
            subprocess.run(value, shell=True)
            continue
        else:
            sys.exit("unknown step: " + step)
        if reply and reply.get("error") != "success":
            print(step, "->", reply, file=sys.stderr)
        time.sleep(0.25)  # let the UI redraw between steps


if __name__ == "__main__":
    main()
