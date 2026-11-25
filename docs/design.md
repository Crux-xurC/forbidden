# forbidden — design

This is the English design document. The Japanese original, with its history, is [ja/design-memo.md](ja/design-memo.md) (v0.3);
where the two differ, the code is right, then the original. How to use it: [../README.md](../README.md).

## What it is

forbidden does **the wall and nothing else**.

- **What it does.** `forbidden on`: from the next command on, nothing that terminal starts can reach the network. `forbidden off`:
  back as before. `forbidden run -- <command>`: one command (a test run, a REPL) inside the same wall.
- **A door.** `--door <name>` opens one local port inside the wall (for example 4600) that leads to one program outside. That program
  is [Citlalpol](https://github.com/Crux-xurC/Citlalpol), the fake outside. forbidden does not know what is behind the door.
- **Two strengths.**
  - **Ordinary** (`on` / `run`): **against accidents** — a test or an evaluation that reaches out by mistake. A light wall, network only.
  - **`--strict`** (`run --strict`): **for looking at a program you do not trust** (someone else's tool). Ordinary means do not get out:
    besides the network, files, sockets, processes and the terminal are taken away (see `--strict` below).
- **What it does not do.** Decide per destination, or record anything — that is behind the door, in Citlalpol. Stand against kernel
  exploits — for real malware use a virtual machine.
- **Platform.** Linux (unprivileged user namespaces).

### Who does what

| | Takes care of |
| --- | --- |
| forbidden | the wall (no way out) and one door in it |
| Citlalpol | the fake outside behind the door: takes 4600, passes only what the project's `access.json` names, refuses everything else, records every attempt |
| [zoozve](https://github.com/Crux-xurC/zoozve) | a gate in front of a local server, so that Citlalpol's `to` can reach only what a person put there |

**The promise to write in documents**: "When you run contract tests with Citlalpol, run them inside forbidden, and check that they never
go out unintentionally."

## How the wall is made

- `forbidden on` / `run` make a new user namespace and network namespace (like `unshare -rn`; no root needed) and start a shell or the
  command inside. Inside there is only its own loopback, and no route out.
- The loopback starts `DOWN`; forbidden brings it up (a test may serve and connect to itself; the door needs it).
- Name resolution fails at once: the resolver in `/etc/resolv.conf` cannot be reached (checked: `curl` says `Could not resolve host`,
  `ping 1.1.1.1` says "network unreachable").
- **The one who makes the wall is the parent.** forbidden makes the namespace and starts the program inside it, never the other way
  round. Whatever the program does inside (changes routes, kills the door's relay), the way out only disappears: it fails safe.

## `forbidden on` / `off` in a terminal

```
forbidden on [--door <name>]   from the next command on, no network (but the door, if any)
forbidden off                  back
forbidden status               on or not, which door
```

- **A shell function.** `eval "$(forbidden shell-init bash)"` in `.bashrc` (the same shape as direnv). zsh and fish later.
- A shell cannot move itself into a namespace, so `on` starts **a shell one level inside**, with `[forbidden]` in its prompt. `off` ends
  it and returns to the outer shell.
- **What is carried back**: the current directory. Shell variables and functions defined inside are not (an honest difference; the
  history continues, since `HISTFILE` is the same).
- **`off` is not a way out.** When the inner shell ends, **whatever was still running inside the wall (background jobs, servers) ends
  too**: the wall is also a PID namespace, and when its first process ends everything in it ends. Nothing is left behind.
- No nesting: `on` inside `on` is refused.
- Works the same in tezcatl's terminal (xterm).

## `forbidden run`

```
forbidden run [--door <name>] [--strict [--dir <dir>]] -- <command> [args…]
```

For test runs and for a REPL started by Xipe Totec. The exit code is the command's.

## Doors

```json
// ~/.config/forbidden/doors.json (this machine's; never in a repository)
{ "citlalpol": { "port": 4600, "socket": "$XDG_RUNTIME_DIR/citlalpol/door.sock", "proxy_protocol": "v2" } }
```

- The door listens on `127.0.0.1:<port>` **inside the wall** and relays to a unix socket outside. A unix socket lives in the file
  system, so it crosses the namespace boundary.
- **The port is opened only inside the wall.** On the host's `127.0.0.1:4600`, any process of the machine could connect and ask the far
  side to "let me out" (the same problem that made tezcatl's relay take a secret and a ticket). Inside the wall nobody outside can use it.
- With a door, the proxy variables are set inside: `ALL_PROXY=socks5h://127.0.0.1:<port>`, `HTTP_PROXY` / `HTTPS_PROXY=
  http://127.0.0.1:<port>` (and the lower-case names), `NO_PROXY=localhost,127.0.0.1`. Programs that read them (curl, most HTTP
  libraries) come to the door and name their destination themselves.
- Programs that **do not read the proxy variables** are caught by a door that **catches all** (below). Without it they stop at the wall
  and leave no record.
- If the door's relay stops, the door is gone (and the way out stays closed).

### What a door may lead to, and from where it is changed

A door is a hole in the wall, so its strength does not come from asking for root but from narrowing **what it can point at** and
**from where it can be changed**.

| Rule | Why |
| --- | --- |
| Doors are fixed when `on` / `run` starts; a change during a run does not touch the running wall | A running wall never widens on the spot |
| The list is changed (`forbidden door add` / `rm`) only outside the wall. Inside, `~/.config/forbidden/` is read-only (hidden under `--strict`) | A test or an examined program must not widen the next run's wall |
| A door leads by default **only to a unix socket in your own `$XDG_RUNTIME_DIR` (0700)** | A door must not become "a hole to anything on the host" |
| A door to a host TCP port (`127.0.0.1:5432`) only with an explicit `door add --tcp`, which shows which program owns the port now. **Not under `--strict`.** *(not built yet)* | See below |

**The host's localhost has programs that can go out.** On the author's machine: tezcatl's relay (:4100 — starts shells, writes files)
and Emacs (:4000). A door to them would lead out through them and make the wall pointless; so would a relay planted somewhere. From
inside a network namespace the host's localhost cannot be reached **unless a door is opened**, which is why a door to a host TCP port is
not an ordinary operation.

### The relay adds a PROXY protocol v2 header

At the head of each connection to the far side, the door's relay writes a HAProxy PROXY protocol v2 header (`"proxy_protocol": "v2"`).

- The destination is already named (SOCKS5, CONNECT), and which run it is could be told by a socket per run. **What PROXY adds is which
  process inside the wall**: the relay sits inside, finds the process from the source port through `/proc`, and puts its pid and command
  in TLVs (v2, not v1, because of TLVs). The run id goes there too.
- TLVs: `0xE0` run id, `0xE1` pid, `0xE2` command (`/proc/<pid>/cmdline`, up to 1024 bytes), `0xE3` mode (`normal` / `strict`),
  `0xE4` via (from the catch-all: `redirect` / `dns`).
- The door's socket is handed only to the relay and hidden from the program (the directory is covered inside the wall); otherwise the
  program could write a header itself and claim to be another process. The relay reaches it through a directory fd
  (`/proc/self/fd/<fd>/<name>`), so hiding the directory does not cut it off.
- The far side (Citlalpol) trusts the header only on connections that came through the door's socket.

### A door that catches all (`--catch-all`)

Programs that ignore the proxy variables (most database drivers, many CLIs, `curl --noproxy`) are taken too:

- Inside the wall, the default route goes to a dummy interface (`forbidden0`, 192.0.2.1). In nftables' `nat output`, every TCP
  connection (but the loopback) is redirected to the relay's `<port>+1`, and every DNS question (UDP port 53 to any server; TCP port
  53 is in the former) to `<port>+53`. In `filter output`, everything else — other UDP, ICMP, IPv6 but the loopback — is rejected at once.
- The relay reads where the connection was going with `SO_ORIGINAL_DST` and puts it in the PROXY header's destination address, with
  `via` (`0xE4`) `redirect` or `dns`. A DNS question is one connection, a 2-byte length and the message (the DNS-over-TCP shape).
- **Not TUN + tun2socks** (decided 2026-11-25): with tun2socks in between, every connection reaching the door would be tun2socks' own,
  and the records would lose the pid and the command. With REDIRECT the relay's peer is the program's own socket.
- The rules are set by the wall's root; the command runs one user namespace further in, so it cannot remove them.
- Sockets of daemons that resolve names outside the wall (`/run/systemd/resolve`, `/run/avahi-daemon`, `/run/nscd`) are hidden too.
- Only one door can catch all.

## A way around: unix sockets that act for you

Unix sockets cross the namespace boundary — that is what the door uses. A program inside can use the same property:

| Acts for you | What it can be made to do |
| --- | --- |
| D-Bus (`$XDG_RUNTIME_DIR/bus`) | ask systemd to start a service outside the wall |
| an Emacs server (`$XDG_RUNTIME_DIR/emacs`) | `emacsclient --eval`: run any code in the Emacs outside |
| gpg-agent (`$XDG_RUNTIME_DIR/gnupg`) | sign or decrypt with your keys |
| podman (`$XDG_RUNTIME_DIR/containers`), dockerd (`/var/run/docker.sock`) | start a container without a wall |
| nix-daemon (`/nix/var/nix/daemon-socket`) | fetch from outside |

- **Ordinary mode**: a mount namespace hides the known ones (directories covered with tmpfs, sockets with `/dev/null`): in
  `$XDG_RUNTIME_DIR` `bus`, `emacs`, `gnupg`, `containers`, `podman`, `docker.sock`, `systemd`; `/run/dbus/system_bus_socket`,
  `/run/docker.sock`, `/run/podman`, `/nix/var/nix/daemon-socket`, `~/.gnupg/S.*`; plus every path in `~/.config/forbidden/hide`
  (`forbidden hide add <path>`; Citlalpol hides its config and records this way). What a daemon outside does on its own is out of scope.
- **`--strict`**: `$XDG_RUNTIME_DIR` is not shown at all (no list to rely on).
- Run `nix develop` outside, then enter: `nix develop -c forbidden run -- …`. Fetching for a dev shell happens outside the wall.

## `--strict`: looking at a program you do not trust

```
forbidden run --strict [--door citlalpol] [--dir <dir to examine>] -- <command> [args…]
```

A network-only wall is not enough for code that may be hostile.

| Way | Ordinary | `--strict` |
| --- | --- | --- |
| network | the wall (the door only) | the same; the door fixed to Citlalpol; no door to a host TCP port |
| writing files (`~/.bashrc`, `~/.config/autostart`, git hooks — run by your next shell outside) | possible | the system read-only, `$HOME` empty and thrown away, only `--dir` handed over (as a throw-away copy; the original never changes) |
| reading files (`~/.ssh`, browser data, tokens) | possible | not visible |
| sockets that act for you | the known ones hidden | `$XDG_RUNTIME_DIR` and `/var/run` sockets not shown |
| processes outside (kill …) | visible | a separate PID namespace; every capability dropped |
| injecting into the terminal (TIOCSTI) | up to the kernel setting | a new session |
| an interactive shell | `on` | `run` only (nothing can be left for the outer shell after `off`) |
| the door list | read-only | not visible |

- Made with bubblewrap **inside the ordinary wall** (since 2026-11-25, so that the catch-all works here too): the ordinary wall sets up
  the loopback, the relay, the catch-all's nftables and the read-only config; bubblewrap shares only its network and unshares the rest
  (`--unshare-user --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup-try`, `--die-with-parent --new-session --cap-drop ALL
  --clearenv`). `/usr`, `/etc`, `/nix/store` read-only; `$HOME`, `/tmp`, `/run` empty; `--dir` is a throw-away copy (its place is
  printed at the end). Environment: only `PATH`, `HOME`, `USER`, `LANG`, `TERM` and forbidden's own (`GITHUB_TOKEN` and the like do
  not pass).
- Citlalpol matches it: an undeclared name is refused **before it is resolved** (a name alone can carry data out:
  `<stolen data>.attacker.example`); when examining, it is advised not to have any `pass` (it would be the way out); input from the door
  is read as untrusted.
- **The promise stops at "ordinary means do not get out".** Kernel exploits are not stopped. Use a virtual machine for real malware.

## How it is checked, in order

1. **forbidden alone**: inside `forbidden on`, `ping 1.1.1.1` and `curl https://example.com` fail, and succeed after `off`. A background
   job started inside cannot get out after `off`. The current directory is carried back.
2. **Through the door**: inside `forbidden on --door citlalpol`, a small Citlalpol behind 4600 — a `curl` `GET /ping` reaches the fake
   outside's pong; an undeclared destination does not.
3. **Citlalpol's acceptance** (its design document).

`test/run.sh` checks 1, 2 and `--strict` without reaching the network (`FORBIDDEN_TEST_NET=1` also checks that the outside is reachable
outside the wall).

## Where user namespaces are not available

With `kernel.unprivileged_userns_clone=0` (some Debian setups) or Ubuntu 23.10+'s AppArmor restriction
(`kernel.apparmor_restrict_unprivileged_userns=1`), a namespace cannot be made without root. forbidden then stops and says why and what
to allow; it never runs without a wall. `forbidden check` tells in advance.

## Implementation

| File | Role |
| --- | --- |
| `bin/forbidden` | the command (bash): `run` / `on` / `off` / `status` / `door` / `hide` / `shell-init` / `check` |
| `lib/inside.sh` | prepares the ordinary wall (inside, as that user namespace's root): brings the loopback up, starts the door's relay and then hides the socket's directory, makes `doors.json` read-only, hides the sockets above, sets the catch-all's rules; finally **drops to your own uid in one more user namespace** and starts the command (which then has no power over the wall's network or mounts) |
| `lib/relay.py` | the door's relay (python3): `127.0.0.1:<port>` inside → the unix socket outside, PROXY v2 |
| `test/run.sh`, `test/fake_door.py` | the checks above |

- The ordinary wall: `unshare --user --map-root-user --net --mount --pid --fork --mount-proc --kill-child` running `lib/inside.sh`, which
  ends in `unshare --user --map-user=<uid> --map-group=<gid>`. If anything cannot be prepared it stops with 125 rather than run in a wall
  with a hole.
- Inside the wall: `FORBIDDEN_ACTIVE`, `FORBIDDEN_MODE`, `FORBIDDEN_RUN`, `FORBIDDEN_DOOR`, and the proxy variables when there is a door.
- `ping`: the wall's `ping_group_range` is opened, so an unprivileged ping fails for the right reason ("network unreachable") rather than
  "permission denied".
- `on`: `--rcfile` reads `~/.bashrc`, redefines `forbidden`, adds `[forbidden]` to the prompt and writes the current directory out at the
  end.

## Milestones

| | What | Done when |
| --- | --- | --- |
| F1 ✔ | `on` / `off` / `status` / `run`, `shell-init bash`, the loopback, stopping without user namespaces | check 1 passes |
| F2 ✔ (but `--tcp`) | doors, the rules of the door list, PROXY v2 | check 2 passes; `doors.json` cannot be changed from inside; the far side's record names the process |
| F3 ✔ | sockets that act for you, hidden | D-Bus, Emacs, gpg-agent, podman, nix-daemon sockets not visible inside `on` |
| F4 ✔ | `--strict` | the examined program cannot change `~/.bashrc`, cannot see `~/.ssh`, `$XDG_RUNTIME_DIR` or processes outside; the door is Citlalpol only |
| F5 ✔ | programs that ignore the proxy reach the door too (catch-all), also under `--strict` | a program that opens a socket directly is recorded on the far side |

## Open

- a door to a host TCP port (`--tcp`): a unix-socket-to-TCP bridge outside the wall
- zsh and fish
- starting tezcatl's terminal with `on`
- more than one door (now one; under `--strict` fixed to Citlalpol)
- under `--strict`, whether `--dir` is a throw-away copy or read-only (when the examined program builds)
