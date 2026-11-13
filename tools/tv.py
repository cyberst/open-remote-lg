#!/usr/bin/env python3
"""Tiny stdlib-only SSAP client for poking the test TV from the shell.

usage: python3 -I tools/tv.py <ssap-uri-without-scheme> [json-payload]
       python3 -I tools/tv.py button HOME          # pointer-socket button
env:   TVTEST_DIR (default: <repo>/.tvtest) containing tv.json, client-key.txt, registration.json
RULES: never set volume above 3. Never power off the TV.
"""
import socket, os, base64, json, struct, sys

def _dir():
    return os.environ.get("TVTEST_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".tvtest")

class WS:
    def __init__(s, url):
        assert url.startswith("ws://"); hp, _, path = url[5:].partition("/")
        host, _, port = hp.partition(":"); s.k = socket.create_connection((host, int(port or 80)), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        s.k.send(f"GET /{path} HTTP/1.1\r\nHost: {hp}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
        r = b""
        while b"\r\n\r\n" not in r: r += s.k.recv(1)
        assert b" 101 " in r.split(b"\r\n")[0], r
    def send_text(s, d):
        d = d.encode(); m = os.urandom(4); n = len(d); h = bytes([0x81])
        h += bytes([0x80 | n]) if n < 126 else (bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
        s.k.sendall(h + m + bytes(b ^ m[i % 4] for i, b in enumerate(d)))
    def _rx(s, n):
        b = b""
        while len(b) < n:
            c = s.k.recv(n - len(b))
            if not c: raise EOFError
            b += c
        return b
    def recv(s):
        h = s._rx(2); n = h[1] & 127
        if n == 126: n = struct.unpack(">H", s._rx(2))[0]
        elif n == 127: n = struct.unpack(">Q", s._rx(8))[0]
        return json.loads(s._rx(n))

def connect():
    d = _dir(); cfg = json.load(open(os.path.join(d, "tv.json")))
    p = json.load(open(os.path.join(d, "registration.json"))); p["client-key"] = open(os.path.join(d, "client-key.txt")).read().strip()
    w = WS(f"ws://{cfg['host']}:3000/"); w.send_text(json.dumps({"type": "register", "id": "r", "payload": p}))
    while w.recv().get("type") != "registered": pass
    return w

def request(w, uri, payload=None):
    if uri == "audio/setVolume" and payload and payload.get("volume", 0) > 3: sys.exit("refusing: volume must stay <= 3")
    if "turnOff" in uri or "powerOff" in uri: sys.exit("refusing: never power off the test TV")
    body = {"type": "request", "id": "x", "uri": "ssap://" + uri}
    if payload is not None: body["payload"] = payload
    w.send_text(json.dumps(body))
    while True:
        m = w.recv()
        if m.get("id") == "x": return m

if __name__ == "__main__":
    w = connect()
    if sys.argv[1] == "button":
        if sys.argv[2] in ("POWER",) or (sys.argv[2] == "VOLUMEUP" and request(w, "audio/getVolume")["payload"].get("volume", 0) >= 3):
            sys.exit("refusing: power/volume>3")
        sock = request(w, "com.webos.service.networkinput/getPointerInputSocket")["payload"]["socketPath"]
        p = WS(sock); p.send_text(f"type:button\nname:{sys.argv[2]}\n\n"); print("sent", sys.argv[2])
    else:
        print(json.dumps(request(w, sys.argv[1], json.loads(sys.argv[2]) if len(sys.argv) > 2 else None), indent=1)[:4000])
