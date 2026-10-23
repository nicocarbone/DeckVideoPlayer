#!/usr/bin/env python3
"""Minimal stand-in for the OpenSubtitles REST API, for testing the
subtitle download flow without an API key or download quota.

    tools/mock-opensubtitles.py [PORT]        # default 8765

Then run the app with
    --script-opts-append=deckplayer-opensubtitles_url=http://127.0.0.1:8765/api/v1
and set any [opensubtitles] api_key in config.ini (tools/headless-run.sh does
both when OSMOCK=1).

Endpoints: GET /api/v1/subtitles, POST /api/v1/login, POST /api/v1/download,
GET /files/<id>.srt. Special queries: "fail" -> HTTP 503, "quota" -> 406 on
download. Every request is logged to stderr with its auth headers so tests
can check them.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
SRT = "1\n00:00:01,000 --> 00:00:30,000\nMock subtitle {id} ({lang})\n"
state = {"remaining": 5, "quota": False}


def result(file_id, lang, release, downloads, hash_match=False):
    return {
        "id": str(file_id), "type": "subtitle",
        "attributes": {
            "language": lang, "release": release, "download_count": downloads,
            "moviehash_match": hash_match, "hearing_impaired": False,
            "files": [{"file_id": file_id, "file_name": release + ".srt"}],
        },
    }


class Handler(BaseHTTPRequestHandler):
    def log_request(self, code="-", size="-"):
        sys.stderr.write("mock: %s %s -> %s api-key=%s auth=%s ua=%s\n" % (
            self.command, self.path, code, self.headers.get("Api-Key"),
            "yes" if self.headers.get("Authorization") else "no", self.headers.get("User-Agent")))

    def send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/api/v1/subtitles":
            if not self.headers.get("Api-Key"):
                return self.send_json(401, {"message": "no key"})
            if q.get("query") == "fail":
                return self.send_json(503, {"message": "down"})
            state["quota"] = q.get("query") == "quota"
            data = []
            langs = q.get("languages", "en").split(",")
            if "moviehash" in q:
                data.append(result(100, langs[0], "Exact.Hash.Release", 12, True))
            if "query" in q:
                for i, lang in enumerate(langs):
                    data.append(result(200 + i, lang, "%s.%s.Release" % (q["query"].title().replace(" ", "."), lang), 1500 * (i + 1)))
                data.append(result(300, "fr", "Other.Language", 99999))
            return self.send_json(200, {"total_count": len(data), "data": data})
        if url.path.startswith("/files/"):
            file_id, lang = url.path[len("/files/"):-len(".srt")].split("-")
            data = SRT.format(id=file_id, lang=lang).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-subrip")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_json(404, {"message": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/v1/login":
            if body.get("password") != "secret":
                return self.send_json(401, {"message": "bad credentials"})
            return self.send_json(200, {"token": "mocktoken", "user": {"allowed_downloads": 20}})
        if self.path == "/api/v1/download":
            if state["quota"]:
                return self.send_json(406, {"message": "quota", "reset_time": "5 hours and 3 minutes"})
            state["remaining"] -= 1
            file_id = body.get("file_id")
            return self.send_json(200, {
                "link": "http://127.0.0.1:%d/files/%s-x.srt" % (PORT, file_id),
                "remaining": state["remaining"], "reset_time": "23 hours",
            })
        self.send_json(404, {"message": "not found"})


if __name__ == "__main__":
    sys.stderr.write("mock OpenSubtitles on http://127.0.0.1:%d/api/v1\n" % PORT)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
