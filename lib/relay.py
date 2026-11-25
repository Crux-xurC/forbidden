#!/usr/bin/env python3
"""lib/relay.py -- forbidden's door: inside the wall, listen on 127.0.0.1:<port>
and relay each connection to a unix socket outside the wall.

The socket is reached through a directory file descriptor
(/proc/self/fd/<fd>/<name>), so the directory can be hidden from the program
inside the wall (normal mode: a tmpfs over it after this relay started;
--strict: it is never bound into the sandbox, only the fd is passed).

With --proxy v2, each connection starts with a PROXY protocol v2 header
(HAProxy's): TCP over IPv4, source 127.0.0.1:<the client's port>, destination
127.0.0.1:<port>, and TLVs of forbidden's own (0xE0-0xE4, see TLV below) saying
which run and which process inside the wall opened the connection.

A door that catches all (--catch-all <port> --dns <port>) also takes what the
wall's nftables sent there: TCP connections that did not use the proxy settings
(the header's destination is where each was going -- SO_ORIGINAL_DST --, the TLV
"via" is "redirect") and DNS questions over UDP (one connection each, "via" is
"dns", the question and the answer framed as DNS over TCP: a 2-byte length).
"""
import argparse
import os
import socket
import struct
import sys
import threading

SIG = b"\r\n\r\n\x00\r\nQUIT\n"
TLV = {"run": 0xE0, "pid": 0xE1, "cmd": 0xE2, "mode": 0xE3, "via": 0xE4}
SO_ORIGINAL_DST = 80
CMD_MAX = 1024


def socket_inode(local_port, tables=("/proc/net/tcp", "/proc/net/tcp6")):
    """the inode of the socket inside the wall whose local end has <local_port>"""
    want = "%04X" % local_port
    for table in tables:
        try:
            with open(table) as f:
                next(f)
                for line in f:
                    parts = line.split()
                    local = parts[1]
                    if local.rsplit(":", 1)[1] == want:
                        return parts[9]
        except OSError:
            pass
    return None


def process_of(inode):
    """(pid, command line) of the process holding socket:[inode], or (None, None)"""
    if not inode or inode == "0":
        return None, None
    target = "socket:[%s]" % inode
    me = str(os.getpid())
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or pid == me:
            continue
        fddir = "/proc/%s/fd" % pid
        try:
            for fd in os.listdir(fddir):
                try:
                    if os.readlink(os.path.join(fddir, fd)) == target:
                        with open("/proc/%s/cmdline" % pid, "rb") as c:
                            cmd = c.read().replace(b"\x00", b" ").strip()
                        return int(pid), cmd[:CMD_MAX].decode("utf-8", "replace")
                except OSError:
                    continue
        except OSError:
            continue
    return None, None


def proxy_v2(src_port, dst_port, tlvs, dst_ip="127.0.0.1"):
    body = socket.inet_aton("127.0.0.1") + socket.inet_aton(dst_ip) + struct.pack("!HH", src_port, dst_port)
    for t, v in tlvs:
        v = v.encode("utf-8") if isinstance(v, str) else v
        body += struct.pack("!BH", t, len(v)) + v
    return SIG + bytes([0x21, 0x11]) + struct.pack("!H", len(body)) + body


def pump(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def tlvs_of(args, pid, cmd, via=None):
    t = [(TLV["run"], args.run or ""), (TLV["mode"], args.mode)]
    if pid is not None:
        t += [(TLV["pid"], str(pid)), (TLV["cmd"], cmd)]
    if via:
        t.append((TLV["via"], via))
    return t


def recv_exact(c, n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d:
            raise EOFError("closed")
        b += d
    return b


def serve(client, peer_port, args, path, redirected=False):
    up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        if redirected:
            # where the program was going before the wall's nftables sent it here
            d = client.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
            dst_port, dst_ip = struct.unpack("!H", d[2:4])[0], socket.inet_ntoa(d[4:8])
        up.connect(path)
        if redirected:
            pid, cmd = process_of(socket_inode(peer_port))
            up.sendall(proxy_v2(peer_port, dst_port, tlvs_of(args, pid, cmd, "redirect"), dst_ip))
        elif args.proxy == "v2":
            pid, cmd = process_of(socket_inode(peer_port))
            up.sendall(proxy_v2(peer_port, args.port, tlvs_of(args, pid, cmd)))
    except OSError as e:
        sys.stderr.write("forbidden: the door's far side does not answer (%s)\n" % e)
        client.close()
        up.close()
        return
    t = threading.Thread(target=pump, args=(up, client), daemon=True)
    t.start()
    pump(client, up)
    t.join()
    client.close()
    up.close()


def dns_one(us, q, addr, args, path):
    """one DNS question over UDP: to the far side framed as DNS over TCP, the answer back"""
    up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        up.settimeout(5)
        up.connect(path)
        pid, cmd = process_of(socket_inode(addr[1], ("/proc/net/udp", "/proc/net/udp6")))
        up.sendall(proxy_v2(addr[1], 53, tlvs_of(args, pid, cmd, "dns")) + struct.pack("!H", len(q)) + q)
        a = recv_exact(up, struct.unpack("!H", recv_exact(up, 2))[0])
        us.sendto(a, addr)
    except (OSError, EOFError, struct.error):
        pass
    finally:
        up.close()


def listen_tcp(port):
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", port))
    ls.listen(64)
    return ls


def accept_loop(ls, args, path, redirected):
    while True:
        c, (_, peer_port) = ls.accept()
        threading.Thread(target=serve, args=(c, peer_port, args, path, redirected), daemon=True).start()


def dns_loop(us, args, path):
    while True:
        q, addr = us.recvfrom(4096)
        threading.Thread(target=dns_one, args=(us, q, addr, args, path), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--socket", help="the unix socket outside (normal mode: its directory is opened here)")
    ap.add_argument("--dirfd", type=int, help="an open directory fd holding the socket (--strict)")
    ap.add_argument("--name", help="the socket's name in --dirfd")
    ap.add_argument("--proxy", default="", choices=["", "v2"])
    ap.add_argument("--run", default="")
    ap.add_argument("--mode", default="normal")
    ap.add_argument("--ready", required=True, help="a file written once listening")
    ap.add_argument("--catch-all", type=int, help="the port the wall's nftables send other TCP connections to")
    ap.add_argument("--dns", type=int, help="the port the wall's nftables send DNS questions (UDP) to")
    args = ap.parse_args()

    if args.dirfd is not None:
        dirfd, name = args.dirfd, args.name
    else:
        dirfd = os.open(os.path.dirname(args.socket), os.O_PATH | os.O_DIRECTORY)
        name = os.path.basename(args.socket)
    path = "/proc/self/fd/%d/%s" % (dirfd, name)

    ls = listen_tcp(args.port)
    if args.catch_all:
        threading.Thread(target=accept_loop, args=(listen_tcp(args.catch_all), args, path, True), daemon=True).start()
    if args.dns:
        us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        us.bind(("127.0.0.1", args.dns))
        threading.Thread(target=dns_loop, args=(us, args, path), daemon=True).start()
    with open(args.ready, "w") as f:
        f.write("ready\n")
    accept_loop(ls, args, path, False)


if __name__ == "__main__":
    main()
