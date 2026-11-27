#!/usr/bin/env python3
"""test/fake_door.py <socket> <log> -- stands where Citlalpol would: a unix socket that
reads the PROXY protocol v2 header (if any), writes what it said as one JSON line
to <log>, and answers an HTTP proxy request for /ping with "pong". What a catch-all
door sends (TLV via: redirect / dns) is logged and closed."""
import json, os, socket, struct, sys, threading

SIG = b"\r\n\r\n\x00\r\nQUIT\n"
NAMES = {0xE0: "run", 0xE1: "pid", 0xE2: "cmd", 0xE3: "mode", 0xE4: "via", 0xE5: "exe"}

def recv_exact(c, n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d:
            raise EOFError
        b += d
    return b

def handle(c, log):
    info = {"proxy": None}
    head = c.recv(12, socket.MSG_PEEK)
    if head == SIG:
        h = recv_exact(c, 16)
        ln = struct.unpack("!H", h[14:16])[0]
        body = recv_exact(c, ln)
        src_port, dst_port = struct.unpack("!HH", body[8:12])
        dst_ip = socket.inet_ntoa(body[4:8])
        tlv, i = {}, 12
        while i < len(body):
            t, l = body[i], struct.unpack("!H", body[i + 1:i + 3])[0]
            tlv[NAMES.get(t, hex(t))] = body[i + 3:i + 3 + l].decode()
            i += 3 + l
        info = {"proxy": "v2", "src_port": src_port, "dst": "%s:%d" % (dst_ip, dst_port), "dst_port": dst_port, **tlv}
    if info.get("via") in ("redirect", "dns"):
        # a catch-all door's connection: logged, then closed (a DNS question gets no answer)
        with open(log, "a") as f:
            f.write(json.dumps(info) + "\n")
        c.close()
        return
    req = b""
    while b"\r\n\r\n" not in req:
        d = c.recv(4096)
        if not d:
            break
        req += d
    info["request"] = req.split(b"\r\n", 1)[0].decode("latin-1")
    with open(log, "a") as f:
        f.write(json.dumps(info) + "\n")
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\npong\n")
    c.close()

sock, log = sys.argv[1:3]
if os.path.exists(sock):
    os.unlink(sock)
s = socket.socket(socket.AF_UNIX)
s.bind(sock)
s.listen()
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c, log), daemon=True).start()
