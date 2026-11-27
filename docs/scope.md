# Scope

What forbidden promises to work, what happens outside that, and what a person does there. Each promise has one sentence of why.
The design: [design.md](design.md); how it came about, in Japanese: [ja/design-memo.md](ja/design-memo.md). What is behind the door
is [Citlalpol](https://github.com/Crux-xurC/Citlalpol)'s, with its own scope.

**Status (2026-11-27).** `bin/forbidden`, `lib/inside.sh` and `lib/relay.py` do what the rows below promise; `test/run.sh` checks them
(48 checks, no network). Rows marked *(planned)* are not done yet.

## How to read it (for people and AI reviewing or verifying)

- Something **inside the scope** that does not work is a bug: report it with steps to reproduce
- Something **outside the scope** that happens as written below is not a bug. Report it only if something other than what is written
  happens, or a program inside reaches the network other than through the door
- A boundary not in these tables: ask whether it is inside or outside before reporting it as a bug; once decided, add a row here
- When the scope changes, change this document

## Two strengths

- **Ordinary** (`forbidden on`, `forbidden run`): **against accidents** — a test, a REPL or an evaluation that reaches out by mistake,
  including through a program outside that would act for it.
- **`--strict`** (`forbidden run --strict`): **for looking at a program you do not trust**. Ordinary means do not get out.

## Inside the scope

| Promise | Why (one sentence) |
|---|---|
| Inside the wall there is **no network but its own loopback** (a new network namespace); without user namespaces forbidden stops and says why, never runs without a wall | A wall with a hole is worse than none: it is trusted. |
| **One door** at most: a port on the wall's loopback leading to a unix socket in your own `$XDG_RUNTIME_DIR`; its socket's directory is hidden inside; doors are changed only from outside (`~/.config/forbidden/` is read-only inside) | The program must not widen the next run's wall, nor talk to the far side but through the port. |
| A door that **catches all** (`--catch-all`, nftables) also takes TCP and DNS of programs that ignore the proxy; other UDP, ICMP and IPv6 (but the loopback) are refused at once; the command cannot change the rules | A program should not get out, or go unseen, because it does not read the proxy variables. |
| **Ordinary mode: `/tmp` and `$XDG_RUNTIME_DIR` are the wall's own**, new and empty: what the shell and its programs make there after `forbidden on` / `run` is seen inside; nothing that programs outside put there is (tmux, X11, Wayland, a browser's single-instance socket, an ssh-agent or an editor server under them). The directory the command starts in and `$TMPDIR` come along when they are under `/tmp`; `..` from them walks the wall's `/tmp`, not the outside one | A program outside that acts on request (types into your terminal, opens a URL in your browser, runs a command) would be a way out, and a list of such programs is never complete. |
| Ordinary mode also hides the known sockets outside those two directories: `/run/dbus/system_bus_socket`, `/run/docker.sock`, `/run/podman`, `/nix/var/nix/daemon-socket`, the name-resolving daemons (`/run/systemd/resolve`, `/run/avahi-daemon`, `/run/nscd`), `~/.gnupg/S.*`, screen's (`/run/screen/S-<user>`, `~/.screen`), the ssh-agent's (`$SSH_AUTH_SOCK`, wherever it is), and every path of `forbidden hide add`; `DISPLAY`, `WAYLAND_DISPLAY`, `TMUX`, `STY`, `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS` are not set inside | The same, for the few that live elsewhere. |
| `--strict`: `$HOME`, `/tmp`, `/run` empty, the system read-only, a separate PID namespace with every capability dropped, a new terminal session, only a few environment variables, the door fixed to Citlalpol; `--dir` is a throw-away copy | Someone else's tool must find neither your files nor a program to act for it. |
| The door's PROXY v2 header names the run, the mode, and the process that opened the connection: its pid, its command line and its executable (`/proc/<pid>/exe`) | The far side records who tried, not only what was tried. |
| `forbidden off` ends whatever was still running inside; the current directory is carried back | Nothing is left behind in a wall nobody looks at. |

## Outside the scope (what happens, and what a person does)

| What | What happens | What a person does |
|---|---|---|
| **The process named in the header** | The command line is what the process says of itself: a program can rewrite its own argv, so `cmd` can be anything. The executable is the file the kernel runs — harder to fake, but an interpreter's (`python3`) for a script. The pid is the first holder of the socket found (a socket can be handed to another process) | Read `cmd` as a hint; `run` and the mode are set outside the wall and can be trusted |
| **Files written under the wall's `/tmp`** (ordinary mode) | They are gone when the wall ends (but under the directory the command started in, or `$TMPDIR`, which are the real ones) | Write what you want to keep in the working directory |
| **Your files** (ordinary mode) | Read and written as usual: the ordinary wall is about the network | `--strict`, or keep the project in git |
| **Shared memory, abstract sockets** (ordinary mode) | `/dev/shm` is shared with the outside; abstract unix sockets belong to the network namespace, so the outside's (X11's `@/tmp/.X11-unix/X0` …) are not reached | — |
| **A program outside that acts by itself** (a daemon polling a file you write) | Out of reach of a wall | Do not write where such a program reads, or `--strict` |
| **Kernel exploits, hostile code in ordinary mode** | Not stopped | `--strict` for someone else's tool; a virtual machine for real malware |
| **Platforms, shells** | Linux only (user namespaces; bubblewrap for `--strict`); `on` / `off` for bash only | *(planned: zsh, fish)* |

## Planned

| What | Where |
|---|---|
| a door to a host TCP port (`--tcp`) | [design.md](design.md#open) |
| zsh and fish | [design.md](design.md#open) |
