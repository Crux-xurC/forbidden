#!/usr/bin/env bash
# lib/inside.sh -- the wall's setup (normal mode). Run by bin/forbidden inside new
# user / network / mount / PID namespaces, as root of that user namespace:
#   1. bring the loopback up (it starts DOWN)
#   2. the door, if any: start lib/relay.py, then hide the socket's directory. A door that
#      catches all also takes what does not use the proxy settings: a default route to a
#      dummy interface, and nftables sending every TCP connection to the relay's <port>+1
#      (it reads where it was going: SO_ORIGINAL_DST) and every DNS question to <port>+53;
#      anything else (UDP, ICMP, IPv6 but the loopback) is refused at once
#   3. forbidden's config (doors, what is hidden) read-only; the known sockets that could act for the program
#      outside the wall (D-Bus, an editor server, gpg-agent, podman, docker,
#      nix-daemon, screen, ssh-agent) hidden; in normal mode /tmp and $XDG_RUNTIME_DIR are new and
#      empty: what the shell and its programs make there is theirs, nothing from outside (tmux, X11,
#      Wayland, a browser's single-instance socket ...) is there. --strict leaves this to bubblewrap
#   4. the command, in one more user namespace as the caller's own uid and with
#      no capabilities over the wall: it cannot bring the loopback down, add
#      routes, or unmount what is hidden
# This script is PID 1 of the wall: when it ends, everything left inside ends.
# Anything that cannot be set up stops the run (exit 125) -- never a wall with a hole.
set -u
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
uid=$1 gid=$2 port=$3 sock=$4 proxy=$5 catch=$6 config=$7 hide=$8 runtime=$9 stage=${10}
shift 10
[ "${1:-}" = "--" ] && shift

die() { echo "forbidden: $*" >&2; exit 125; }

ip link set lo up 2>/dev/null || die "cannot bring the loopback up"
# ping without privileges (ICMP datagram sockets) for every group, so that ping inside fails for the
# true reason -- the network is not there -- not for a missing permission
echo "0 0" > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true   # the one group mapped here (the caller's)

catch_args=()
if [ -n "$port" ] && [ -n "$catch" ]; then
  tport=$((port + 1)) dport=$((port + 53))
  # 192.0.2.1 (TEST-NET-1): a source address that is nobody's
  { ip link add forbidden0 type dummy && ip link set forbidden0 up && ip addr add 192.0.2.1/32 dev forbidden0 &&
    ip route add default dev forbidden0; } 2>/dev/null || die "cannot make the wall's catch-all route"
  nft -f - <<NFT 2>/dev/null || die "cannot set the wall's catch-all rules (nftables)"
table inet forbidden {
  chain nat_out {
    type nat hook output priority -100;
    meta nfproto ipv4 udp dport 53 redirect to :$dport
    meta nfproto ipv4 ip daddr != 127.0.0.0/8 meta l4proto tcp redirect to :$tport
    meta nfproto ipv4 tcp dport 53 redirect to :$tport
  }
  chain filter_out {
    type filter hook output priority 0;
    oifname "lo" accept
    ct status dnat accept
    meta l4proto tcp reject with tcp reset
    reject with icmpx type admin-prohibited
  }
}
NFT
  catch_args=(--catch-all "$tport" --dns "$dport")
fi

if [ -n "$port" ]; then
  ready="$(mktemp -u /tmp/forbidden-ready.XXXXXX)"
  python3 "$lib/relay.py" --port "$port" --socket "$sock" --proxy "$proxy" --run "${FORBIDDEN_RUN:-}" \
    --mode "${FORBIDDEN_MODE:-normal}" --ready "$ready" "${catch_args[@]}" &
  for _ in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.05; done
  [ -s "$ready" ] || die "the door's relay did not start"
  rm -f "$ready"
  mount -t tmpfs -o size=4k,mode=000 forbidden "$(dirname "$sock")" 2>/dev/null \
    || die "cannot hide the door's socket ($(dirname "$sock"))"
fi

# normal mode: what is under /tmp and the runtime directory outside is not shown; the wall has its own
# (the door's relay holds its socket's directory open already). Only the places the command works in
# come along when they are under /tmp: its directory and $TMPDIR (nix develop's is /tmp/nix-shell.*).
# The new /tmp is built aside ($stage, made by bin/forbidden) and moved over /tmp; then the directory is
# taken again, so that `..` from it walks the new tree, not the old /tmp. --strict: bubblewrap gives its
# own /tmp and /run, and its --dir copy is under the outside /tmp, so nothing here. Before what is hidden
# below, so that it is hidden in the new tree too
exec 3< "$hide"   # the list to hide is under the outside /tmp: open before /tmp is the wall's
if [ "${FORBIDDEN_MODE:-normal}" = normal ]; then
  here="$(pwd -P)"
  mount -t tmpfs -o mode=1777 forbidden-tmp "$stage" 2>/dev/null || die "cannot give the wall its own /tmp"
  for p in "$here" "${TMPDIR:-}"; do
    p="$(readlink -f "$p" 2>/dev/null)" || continue
    case "$p" in /tmp/?*) [ -d "$p" ] && echo "$p" ;; esac
  done | sort -u | while IFS= read -r p; do
    mkdir -p "$stage/${p#/tmp/}" && mount --bind "$p" "$stage/${p#/tmp/}" 2>/dev/null || die "cannot bring $p into the wall's /tmp"
  done || exit 125
  mount --move "$stage" /tmp 2>/dev/null || die "cannot give the wall its own /tmp"
  cd / && cd "$here" 2>/dev/null || cd /
  if [ -n "$runtime" ] && [ -d "$runtime" ]; then
    mount -t tmpfs -o mode=700 forbidden-run "$runtime" 2>/dev/null || die "cannot give the wall its own $runtime"
  fi
fi

# the whole config directory: a program inside must not change the doors, or what is hidden next time
if [ -d "$config" ]; then
  { mount --bind "$config" "$config" && mount -o remount,bind,ro "$config"; } 2>/dev/null \
    || die "cannot make $config read-only"
fi

# the known sockets (bin/forbidden's list, one path a line)
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ -d "$p" ] && [ ! -L "$p" ]; then
    mount -t tmpfs -o size=4k,mode=000 forbidden "$p" 2>/dev/null || die "cannot hide $p"
  elif [ -S "$p" ]; then
    mount --bind /dev/null "$p" 2>/dev/null || die "cannot hide $p"
  fi
done <&3
exec 3<&-

unshare --user --map-user="$uid" --map-group="$gid" -- "$@"
