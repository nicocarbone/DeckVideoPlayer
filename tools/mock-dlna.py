#!/usr/bin/env python3
"""Minimal DLNA/UPnP media server for testing the app's DLNA client (D66)
without a NAS: answers SSDP searches, serves a device description and a
ContentDirectory built from a folder, and the videos themselves (with
Range, for seeking).

    tools/mock-dlna.py [--port 8766] [--name "Mock DLNA"] [--slow S] [--hang]
                       [--page N] [--rate KB] FOLDER

Object ids are the folders' and files' paths relative to FOLDER (so they
contain "/" and spaces, which the client must encode), "0" is the root.
--slow S delays every Browse answer by S seconds; --hang never answers
Browse (a server busy indexing); --page N returns at most N entries per
Browse, whatever the client asks (paging); --rate KB serves videos at
about KB kilobytes per second (to stop and resume a download midway).

The description, Browse answers and files are served on this machine's
LAN address (SSDP answers must come from the address in their LOCATION),
so FOLDER is readable from the LAN while it runs: development only.
Requests are logged to stderr.
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote
from xml.sax.saxutils import escape

VIDEO_EXT = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".webm", ".ts", ".m2ts", ".mpg"}
MIME = {".mkv": "video/x-matroska", ".mp4": "video/mp4", ".m4v": "video/mp4", ".avi": "video/x-msvideo",
        ".mov": "video/quicktime", ".webm": "video/webm", ".ts": "video/mp2t", ".m2ts": "video/mp2t",
        ".mpg": "video/mpeg"}
UUID = "4d6f636b-444c-4e41-0000-000000000001"

args = None


def lan_address_for(peer):
    """This machine's address on the route to `peer`."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((peer, 9))
        return s.getsockname()[0]
    finally:
        s.close()


def description(name):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
<device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
<friendlyName>{escape(name)}</friendlyName><manufacturer>Deck Video Player tests</manufacturer>
<modelName>mock-dlna</modelName><UDN>uuid:{UUID}</UDN><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId><SCPDURL>/cm.xml</SCPDURL>
<controlURL>/cm</controlURL><eventSubURL>/cm/ev</eventSubURL></service>
<service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
<serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId><SCPDURL>/cd.xml</SCPDURL>
<controlURL>ctl/ContentDir</controlURL><eventSubURL>/cd/ev</eventSubURL></service>
</serviceList></device></root>"""


def children(rel):
    """Folders and videos directly in `rel` (relative path, "" = root)."""
    full = os.path.join(args.folder, rel)
    out = []
    for name in sorted(os.listdir(full), key=str.lower):
        if name.startswith("."):
            continue
        path = os.path.join(full, name)
        child = os.path.join(rel, name) if rel else name
        if os.path.isdir(path):
            out.append(("container", child, name))
        elif os.path.splitext(name)[1].lower() in VIDEO_EXT:
            out.append(("item", child, name))
    return out


def didl_entry(kind, obj_id, title, parent, host):
    if kind == "container":
        count = len(children(obj_id))
        return (f'<container id="{escape(obj_id, {chr(34): "&quot;"})}" parentID="{escape(parent)}" '
                f'childCount="{count}" restricted="1"><dc:title>{escape(title)}</dc:title>'
                f'<upnp:class>object.container.storageFolder</upnp:class></container>')
    full = os.path.join(args.folder, obj_id)
    ext = os.path.splitext(obj_id)[1].lower()
    url = f"http://{host}:{args.port}/media/{quote(obj_id)}"
    st = os.stat(full)
    date = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(st.st_mtime))
    return (f'<item id="{escape(obj_id, {chr(34): "&quot;"})}" parentID="{escape(parent)}" restricted="1">'
            f'<dc:title>{escape(os.path.splitext(title)[0])}</dc:title><dc:date>{date}</dc:date>'
            f'<upnp:class>object.item.videoItem</upnp:class>'
            f'<res protocolInfo="http-get:*:{MIME.get(ext, "video/mpeg")}:DLNA.ORG_OP=01;DLNA.ORG_CI=0" '
            f'size="{st.st_size}">{escape(url)}</res></item>')


def browse_response(didl, returned, total):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>
<u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><Result>{escape(didl)}</Result>
<NumberReturned>{returned}</NumberReturned><TotalMatches>{total}</TotalMatches><UpdateID>1</UpdateID>
</u:BrowseResponse></s:Body></s:Envelope>"""


def fault(code, text):
    return f"""<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>
<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>{code}</errorCode>
<errorDescription>{escape(text)}</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"""


def field(body, name):
    start = body.find(f"<{name}>")
    end = body.find(f"</{name}>")
    if start < 0 or end < 0:
        return ""
    from xml.sax.saxutils import unescape
    return unescape(body[start + len(name) + 2:end])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write("mock-dlna: " + (fmt % a) + "\n")

    def send(self, code, body, ctype="text/xml; charset=\"utf-8\""):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def host(self):
        return self.connection.getsockname()[0]

    def do_GET(self):
        if self.path == "/desc.xml":
            return self.send(200, description(args.name))
        if self.path.startswith("/media/"):
            return self.media(unquote(self.path[len("/media/"):]), head=False)
        self.send(404, "not found", "text/plain")

    def do_HEAD(self):
        if self.path.startswith("/media/"):
            return self.media(unquote(self.path[len("/media/"):]), head=True)
        self.send(404, "", "text/plain")

    def media(self, rel, head):
        full = os.path.realpath(os.path.join(args.folder, rel))
        if not full.startswith(os.path.realpath(args.folder) + os.sep) or not os.path.isfile(full):
            return self.send(404, "not found", "text/plain")
        size = os.path.getsize(full)
        start, end = 0, size - 1
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            if a:
                start = int(a)
                end = int(b) if b else size - 1
            else:
                start = max(0, size - int(b))
            end = min(end, size - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        ext = os.path.splitext(full)[1].lower()
        self.send_header("Content-Type", MIME.get(ext, "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if head:
            return
        with open(full, "rb") as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(left, 1 << 16))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
                    if args.rate:
                        time.sleep(len(chunk) / (args.rate * 1024.0))
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace")
        if self.path != "/ctl/ContentDir":
            return self.send(404, "not found", "text/plain")
        if args.hang:
            time.sleep(3600)
            return
        if args.slow:
            time.sleep(args.slow)
        obj = field(body, "ObjectID")
        flag = field(body, "BrowseFlag")
        start = int(field(body, "StartingIndex") or 0)
        count = int(field(body, "RequestedCount") or 0) or 1000
        if args.page:
            count = min(count, args.page)
        rel = "" if obj == "0" else obj
        full = os.path.realpath(os.path.join(args.folder, rel))
        root = os.path.realpath(args.folder)
        if not (full == root or full.startswith(root + os.sep)) or not os.path.exists(full):
            return self.send(500, fault(701, "No such object"))
        parent = "-1" if obj == "0" else (os.path.dirname(rel) or "0")
        host = self.host()
        head = ('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
                'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">')
        if flag == "BrowseMetadata":
            kind = "container" if os.path.isdir(full) else "item"
            entry = didl_entry(kind, rel or "0", os.path.basename(rel) or "root", parent, host)
            return self.send(200, browse_response(head + entry + "</DIDL-Lite>", 1, 1))
        kids = children(rel)
        page = kids[start:start + count]
        didl = head + "".join(didl_entry(k, i, t, obj, host) for k, i, t in page) + "</DIDL-Lite>"
        self.send(200, browse_response(didl, len(page), len(kids)))


def ssdp_loop():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("", 1900))
    mreq = struct.pack("4sl", socket.inet_aton("239.255.255.250"), socket.INADDR_ANY)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    while True:
        data, peer = sock.recvfrom(4096)
        text = data.decode("utf-8", "replace")
        if not text.startswith("M-SEARCH") or "MediaServer" not in text and "ssdp:all" not in text:
            continue
        me = lan_address_for(peer[0])
        reply = ("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n"
                 f"LOCATION: http://{me}:{args.port}/desc.xml\r\nSERVER: Linux UPnP/1.0 mock-dlna/1\r\n"
                 "ST: urn:schemas-upnp-org:device:MediaServer:1\r\n"
                 f"USN: uuid:{UUID}::urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n")
        out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        out.bind((me, 0))
        out.sendto(reply.encode(), peer)
        out.close()
        sys.stderr.write(f"mock-dlna: answered M-SEARCH from {peer[0]}\n")


def main():
    global args
    p = argparse.ArgumentParser()
    p.add_argument("folder")
    p.add_argument("--port", type=int, default=8766)
    p.add_argument("--name", default="Mock DLNA")
    p.add_argument("--slow", type=float, default=0)
    p.add_argument("--hang", action="store_true")
    p.add_argument("--page", type=int, default=0)
    p.add_argument("--rate", type=float, default=0)
    args = p.parse_args()
    args.folder = os.path.abspath(args.folder)
    threading.Thread(target=ssdp_loop, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
