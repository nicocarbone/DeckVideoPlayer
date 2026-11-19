#!/usr/bin/env python3
"""A small web server for testing online video lists (D84) without
YouTube: video files with Range (seeking, resumed downloads), web pages
that embed them (yt-dlp's generic extractor plays those, so the app's
yt-dlp path can be tested offline), and anything else in the folder
(DASH manifests made with ffmpeg: video and audio apart, as YouTube's).

    tools/mock-online.py [--port 8767] [--rate KB] FOLDER

    http://127.0.0.1:8767/files/<path>   the file FOLDER/<path>
    http://127.0.0.1:8767/watch?file=<path>[&file=<path>…][&title=…]
                                          a page with <video src> pointing at
                                          /files/<path>, titled after the file
                                          (the address has no file extension,
                                          as a video site's page); with
                                          several files, several videos (yt-dlp
                                          reads it as a playlist);
                                          &sub=<lang>:<path> (repeatable) adds
                                          a subtitle track to the first one
    http://127.0.0.1:8767/status/<code>  an empty answer with that HTTP status

--rate KB serves files at about KB kilobytes per second (to stop and resume
a download midway). Only on 127.0.0.1; development only. Requests are
logged to stderr.
"""
import argparse
import html
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote

MIME = {".mkv": "video/x-matroska", ".mp4": "video/mp4", ".m4v": "video/mp4", ".webm": "video/webm",
        ".ts": "video/mp2t", ".mpd": "application/dash+xml", ".m3u8": "application/vnd.apple.mpegurl",
        ".m4s": "video/iso.segment", ".vtt": "text/vtt", ".html": "text/html"}

args = None


def safe_path(rel):
    """FOLDER/rel, or None if it leaves FOLDER."""
    root = os.path.realpath(args.folder)
    path = os.path.realpath(os.path.join(root, rel))
    if path != root and not path.startswith(root + os.sep):
        return None
    return path


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write("mock-online: " + (fmt % a) + "\n")

    def send_empty(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self.handle_get(head=True)

    def do_GET(self):
        self.handle_get(head=False)

    def handle_get(self, head):
        path = unquote(self.path.split("?", 1)[0])
        query = parse_qs(self.path.split("?", 1)[1]) if "?" in self.path else {}
        if path.startswith("/status/"):
            code = int(path[len("/status/"):] or 500)
            return self.send_empty(code)
        if path == "/watch":
            rels = query.get("file", [""])
            for rel in rels:
                file = safe_path(rel)
                if not file or not os.path.isfile(file):
                    return self.send_empty(404)
            title = query.get("title", [os.path.splitext(os.path.basename(rels[0]))[0]])[0]
            tracks = ""
            for sub in query.get("sub", []):
                lang, _, rel = sub.partition(":")
                tracks += (f'<track kind="subtitles" srclang="{html.escape(lang)}" '
                           f'src="{html.escape("/files/" + quote(rel))}">')
            videos = "".join(f'<video controls src="{html.escape("/files/" + quote(rel))}">{tracks if i == 0 else ""}'
                             "</video>" for i, rel in enumerate(rels))
            body = (f"<!DOCTYPE html><html><head><title>{html.escape(title)}</title>"
                    f'<meta property="og:title" content="{html.escape(title)}"></head>'
                    f"<body>{videos}</body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return
        if not path.startswith("/files/"):
            return self.send_empty(404)
        file = safe_path(path[len("/files/"):])
        if not file or not os.path.isfile(file):
            return self.send_empty(404)
        size = os.path.getsize(file)
        start, end = 0, size - 1
        rng = self.headers.get("Range", "")
        partial = False
        if rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            try:
                if a:
                    start = int(a)
                    end = int(b) if b else size - 1
                else:
                    start = max(0, size - int(b))
                partial = True
            except ValueError:
                return self.send_empty(400)
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            end = min(end, size - 1)
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", MIME.get(os.path.splitext(file)[1].lower(), "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if head:
            return
        with open(file, "rb") as f:
            f.seek(start)
            left = end - start + 1
            chunk = 64 * 1024
            while left > 0:
                data = f.read(min(chunk, left))
                if not data:
                    break
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(data)
                if args.rate > 0:
                    time.sleep(len(data) / (args.rate * 1024))


def main():
    global args
    p = argparse.ArgumentParser()
    p.add_argument("folder")
    p.add_argument("--port", type=int, default=8767)
    p.add_argument("--rate", type=float, default=0)
    args = p.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    sys.stderr.write(f"mock-online: serving {args.folder} on http://127.0.0.1:{args.port}/\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
