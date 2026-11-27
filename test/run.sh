#!/usr/bin/env bash
# test/run.sh -- forbidden's checks (the design memo's "確かめ方" 1 and 2, and --strict).
# Starts a fake door server (test/fake_door.py) in a runtime directory of its own and
# uses a config directory of its own (FORBIDDEN_CONFIG_DIR): ~/.config is not touched.
# Nothing here reaches the network; FORBIDDEN_TEST_NET=1 adds "outside the wall,
# curl reaches example.com" (forbidden off).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$here/bin/forbidden"
runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
work="$(mktemp -d)"
sockdir="$(mktemp -d "$runtime/forbidden-test.XXXXXX")"
export FORBIDDEN_CONFIG_DIR="$work/config"
export XDG_CACHE_HOME="$work/cache"   # on's rc and off's directory
fails=0
ok() { echo "  ok   $1"; }
ng() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

python3 "$here/test/fake_door.py" "$sockdir/door.sock" "$work/door.log" &
door_pid=$!
trap 'kill $door_pid 2>/dev/null; rm -rf "$work" "$sockdir"' EXIT
for _ in $(seq 1 50); do [ -S "$sockdir/door.sock" ] && break; sleep 0.05; done

echo "1. the wall (normal)"
out="$("$F" run -- sh -c 'curl -sS -m3 http://example.com -o /dev/null 2>&1; echo "curl=$?"')"
check "curl inside fails" '[[ "$out" == *"curl=6"* ]]'
"$F" run -- ping -c1 -W1 1.1.1.1 >/dev/null 2>&1
check "ping inside fails" '[ $? -ne 0 ]'
check "the command's exit code comes out" '"$F" run -- sh -c "exit 7"; [ $? -eq 7 ]'
check "inside, my own uid" '[ "$("$F" run -- id -u)" = "$(id -u)" ]'
check "inside, the loopback cannot be brought down" '! "$F" run -- ip link set lo down 2>/dev/null'
out="$("$F" run -- python3 -c '
import socket,threading
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); p=s.getsockname()[1]
threading.Thread(target=lambda: s.accept()[0].sendall(b"lo-ok"),daemon=True).start()
c=socket.create_connection(("127.0.0.1",p)); print(c.recv(10).decode())')"
check "the loopback is up (listen and connect inside)" '[ "$out" = lo-ok ]'
if [ -S "$runtime/bus" ]; then
  check "D-Bus's socket is hidden" '! "$F" run -- python3 -c "import socket; socket.socket(socket.AF_UNIX).connect(\"$runtime/bus\")" 2>/dev/null'
fi
marker="$work/after-off"
"$F" run -- sh -c "(sleep 1; touch '$marker') & echo started" >/dev/null
sleep 2
check "what was left running inside ends with the run" '[ ! -e "$marker" ]'
if [ "${FORBIDDEN_TEST_NET:-}" = 1 ]; then
  check "outside the wall, curl reaches example.com" 'curl -sS -m5 http://example.com -o /dev/null'
fi

echo "2. the door"
check "a door outside the runtime directory is refused" '! "$F" door add bad --port 4600 --socket /tmp/x.sock 2>/dev/null'
"$F" door add test --port 4600 --socket "$sockdir/door.sock" --proxy-protocol v2 >/dev/null
check "door add / list" '"$F" door list | grep -q "^test .*127.0.0.1:4600"'
out="$("$F" run --door test -- curl -sS -m5 http://pong.citlalpol.test/ping)"
check "curl through the door reaches the far side (pong)" '[ "$out" = pong ]'
last="$(tail -1 "$work/door.log")"
check "the far side gets the executable too (what the kernel runs, not what the process says)" '[[ "$(tail -1 "$work/door.log")" == *"\"exe\": \"/"*curl* ]]'
check "the far side got PROXY v2 with the run and the process (curl)" \
  '[[ "$last" == *"\"proxy\": \"v2\""* && "$last" == *"\"run\": \"f-"* && "$last" == *"\"cmd\": \"curl "* && "$last" == *"GET http://pong.citlalpol.test/ping"* ]]'
check "the door's socket directory is hidden inside" '! "$F" run --door test -- test -e "$sockdir/door.sock"'
check "doors.json is read-only inside" '! "$F" run --door test -- sh -c "echo {} > \"$FORBIDDEN_CONFIG_DIR/doors.json\"" 2>/dev/null'
check "doors are not changed from inside" '! FORBIDDEN_ACTIVE=1 "$F" door rm test 2>/dev/null'
mkdir -p "$work/secret-dir"; echo s > "$work/secret-dir/f"
"$F" hide add "$work/secret-dir" >/dev/null
check "hide add: the path is hidden inside" '! "$F" run -- cat "$work/secret-dir/f" 2>/dev/null'
check "what is hidden cannot be changed from inside (the config is read-only)" '! "$F" run -- sh -c "echo > \"$FORBIDDEN_CONFIG_DIR/hide\"" 2>/dev/null'
"$F" hide rm "$work/secret-dir" >/dev/null
check "hide rm: seen again" '[ "$("$F" run -- cat "$work/secret-dir/f")" = s ]'
out="$("$F" run --door test -- curl -sS -m3 --noproxy "*" http://example.com 2>&1)"
check "inside, around the door (no proxy) still fails" '[[ "$out" == *"Could not resolve"* ]]'

echo "2b. a door that catches all (nftables)"
check "--catch-all without PROXY v2 is refused" '! "$F" door add c2 --port 4610 --socket "$sockdir/door.sock" --catch-all 2>/dev/null'
"$F" door add catch --port 4620 --socket "$sockdir/door.sock" --proxy-protocol v2 --catch-all >/dev/null
check "door list says it catches all" '"$F" door list | grep -q "^catch .*(catches all)"'
check "a second door that catches all is refused" '! "$F" door add c3 --port 4630 --socket "$sockdir/door.sock" --proxy-protocol v2 --catch-all 2>/dev/null'
"$F" run --door catch -- python3 -c '
import socket
try: socket.create_connection(("203.0.113.5", 8080), timeout=3).recv(1)
except OSError: pass' 2>/dev/null
last="$(tail -1 "$work/door.log")"
check "a connection that ignores the proxy reaches the door, with where it was going and who" \
  '[[ "$last" == *"\"via\": \"redirect\""* && "$last" == *"\"dst\": \"203.0.113.5:8080\""* && "$last" == *"\"cmd\": \"python3 "* ]]'
"$F" run --door catch -- python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
s.sendto(bytes.fromhex("1234010000010000000000000474657374000001000 1".replace(" ", "")), ("192.0.2.53", 53))
try: s.recv(512)
except OSError: pass' 2>/dev/null
last="$(tail -1 "$work/door.log")"
check "a DNS question (UDP, to any server) reaches the door as dns" '[[ "$last" == *"\"via\": \"dns\""* && "$last" == *"\"cmd\": \"python3 "* ]]'
out="$("$F" run --door catch -- python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try: s.sendto(b"x", ("203.0.113.5", 9)); print("sent")
except OSError as e: print("refused", e.errno)' 2>&1)"
check "other UDP is refused at once" '[[ "$out" == "refused"* ]]'
check "the command cannot remove the rules" '! "$F" run --door catch -- nft flush ruleset 2>/dev/null'
"$F" door rm catch >/dev/null

echo "2b. sockets of programs outside the wall (normal mode: /tmp and the runtime directory are the wall's own)"
listen() { python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(60)' "$1" & }
reach() { "$F" run -- python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1]); print("reached")' "$1" 2>/dev/null; }
tmuxdir="$(mktemp -d /tmp/forbidden-test-tmux.XXXXXX)"
listen "$tmuxdir/default"; p1=$!
listen "$sockdir/wayland-test"; p2=$!
mkdir -p "$work/agent"; listen "$work/agent/agent.sock"; p3=$!
sleep 0.3
check "a socket under /tmp outside (tmux, X11 ...) is not there inside" '[ -S "$tmuxdir/default" ] && [ -z "$(reach "$tmuxdir/default")" ]'
check "a socket in the runtime directory outside (Wayland ...) is not there inside" '[ -z "$(reach "$sockdir/wayland-test")" ]'
check "the ssh-agent's socket, wherever it is, is hidden" '[ -z "$(SSH_AUTH_SOCK="$work/agent/agent.sock" reach "$work/agent/agent.sock")" ] && [ "$(reach "$work/agent/agent.sock")" = reached ]'
kill $p1 $p2 $p3 2>/dev/null; rm -rf "$tmuxdir"
out="$(DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 TMUX=/tmp/tmux-1/default,1,0 STY=1.pts SSH_AUTH_SOCK=/x "$F" run -- sh -c 'echo "${DISPLAY-}${WAYLAND_DISPLAY-}${TMUX-}${STY-}${SSH_AUTH_SOCK-}"')"
check "...and the variables naming them are not set inside" '[ -z "$out" ]'
out="$("$F" run -- sh -c 'python3 -c "import socket,time; s=socket.socket(socket.AF_UNIX); s.bind(\"/tmp/mine\"); s.listen(); time.sleep(3)" & sleep 0.5; python3 -c "import socket; socket.socket(socket.AF_UNIX).connect(\"/tmp/mine\"); print(\"mine\")"; ls -A "$XDG_RUNTIME_DIR" | wc -l' 2>/dev/null)"
check "what the wall makes under /tmp is reached inside (its own tmux would be); its runtime directory starts empty" '[ "$out" = "mine
0" ]'
check "what the wall wrote under /tmp is not left outside" '[ ! -e /tmp/mine ]'
tmuxdir="$(mktemp -d /tmp/forbidden-test-tmux.XXXXXX)"; listen "$tmuxdir/default"; p1=$!; sleep 0.3
mkdir -p "$work/proj"
rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$tmuxdir/default" "$work/proj")"
out="$(cd "$work/proj" && "$F" run -- sh -c 'pwd; mktemp -p "${TMPDIR:-/tmp}" >/dev/null && echo tmp-ok; python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1]); print(\"reached\")" "'"$rel"'"' 2>/dev/null)"
kill $p1 2>/dev/null; rm -rf "$tmuxdir"
check "a directory under /tmp comes along (and \$TMPDIR), but .. from it does not reach the old /tmp" \
  '[[ "$out" == "$work/proj"*tmp-ok* && "$out" != *reached* ]]'

echo "3. on / off (the shell function)"
cwd_after="$(cd "$work" && bash -c '
  eval "$("'"$F"'" shell-init bash)"
  forbidden on >"'"$work"'/on.out" 2>&1 < <(printf "%s\n" "forbidden status" "cd /tmp" "forbidden off")
  pwd')"
check "inside, status says on" 'grep -q "^on (normal)" "$work/on.out"'
check "off carries the directory back" '[ "$cwd_after" = /tmp ]'
check "on inside on is refused" '! FORBIDDEN_ACTIVE=1 "$F" on 2>/dev/null'

echo "4. --strict"
mkdir -p "$work/tool"; echo original > "$work/tool/file"
out="$("$F" run --strict --dir "$work/tool" -- sh -c '
  echo changed > file; ls -A "$HOME" | wc -l; test -e "$HOME/.ssh" && echo ssh-visible
  test -e "'"$runtime"'" && echo runtime-visible; pwd' 2>/dev/null)"
check "--strict: HOME is empty, ~/.ssh and the runtime directory are not there" '[[ "$out" == 0* && "$out" != *visible* ]]'
check "--strict: the original --dir is unchanged" '[ "$(cat "$work/tool/file")" = original ]'
GITHUB_TOKEN=secret "$F" run --strict -- sh -c 'echo "${GITHUB_TOKEN:-none}"' > "$work/env.out" 2>/dev/null
check "--strict: GITHUB_TOKEN set outside is not seen inside" '[ "$(cat "$work/env.out")" = none ]'
check "--strict: other processes are not seen" '[ "$("$F" run --strict -- sh -c "ls /proc | grep -c \"^[0-9]\"")" -lt 5 ]'
check "--strict: curl fails" '! "$F" run --strict -- curl -sS -m3 http://example.com -o /dev/null 2>/dev/null'
check "--strict: a door other than citlalpol is refused" '! "$F" run --strict --door test -- true 2>/dev/null'
"$F" door add citlalpol --port 4600 --socket "$sockdir/door.sock" --proxy-protocol v2 >/dev/null
out="$("$F" run --strict --door citlalpol -- curl -sS -m5 http://pong.citlalpol.test/ping 2>/dev/null)"
check "--strict: through Citlalpol's door (pong)" '[ "$out" = pong ]'
last="$(tail -1 "$work/door.log")"
check "--strict: PROXY v2 says mode strict and the process" '[[ "$last" == *"\"mode\": \"strict\""* && "$last" == *"\"cmd\": \"curl "* ]]'
check "--strict: the door's socket cannot be named inside" '! "$F" run --strict --door citlalpol -- test -e "$sockdir/door.sock" 2>/dev/null'
"$F" door rm citlalpol >/dev/null
"$F" door add citlalpol --port 4600 --socket "$sockdir/door.sock" --proxy-protocol v2 --catch-all >/dev/null
"$F" run --strict --door citlalpol -- python3 -c '
import socket
try: socket.create_connection(("203.0.113.7", 8443), timeout=3).recv(1)
except OSError: pass' 2>/dev/null
last="$(tail -1 "$work/door.log")"
check "--strict with a door that catches all: a connection ignoring the proxy reaches it, mode strict" \
  '[[ "$last" == *"\"via\": \"redirect\""* && "$last" == *"\"dst\": \"203.0.113.7:8443\""* && "$last" == *"\"mode\": \"strict\""* && "$last" == *"\"cmd\": \"python3 "* ]]'
out="$("$F" run --strict --door citlalpol -- curl -sS -m5 http://pong.citlalpol.test/ping 2>/dev/null)"
check "--strict with the catch-all: through the proxy still (pong)" '[ "$out" = pong ]'
check "--strict: the command cannot remove the rules" '! "$F" run --strict --door citlalpol -- nft flush ruleset 2>/dev/null'

echo
if [ "$fails" -eq 0 ]; then echo "all ok"; else echo "$fails failed"; exit 1; fi
