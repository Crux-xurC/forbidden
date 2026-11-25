# forbidden

Design: [docs/design.md](docs/design.md) (the Japanese original with its history: [docs/ja/](docs/ja/))

`forbidden on` in a terminal: from the next command, nothing that terminal starts can reach the network. `forbidden off`: back as
before. `forbidden run -- <command>` does the same for one command (a test run, a REPL). It is a wall and nothing else: no
configuration, no rules, no records — a fresh Linux network namespace with only its own loopback in it.

A wall may have one door. `forbidden on --door <name>` opens one local port inside (for example 4600) that leads to a program
outside — [Citlalpol](https://github.com/Crux-xurC/Citlalpol), the fake outside, which decides per destination what happens and records
every attempt. forbidden knows nothing of what is behind the door.

Use it around anything that must not reach the network by accident: when you run contract tests with Citlalpol, run them inside
`forbidden on` and check that they never go out unintentionally.

Two strengths. By default it guards against accidents: a test or a REPL that reaches out by mistake. `forbidden run --strict`
is for looking at a program you do not trust (someone else's tool): besides the network it hides your files, your session's sockets
(D-Bus, an editor server, gpg-agent), other processes and the terminal, and its only door is Citlalpol. Even then it promises only
that ordinary means do not get out; it does not stand against kernel exploits — use a virtual machine for that. Linux only
(unprivileged user namespaces; bubblewrap for `--strict`).

## Use

```sh
bin/forbidden check                         # can this machine build the wall (and bwrap for --strict)?
bin/forbidden run -- mix test               # one command inside the wall
eval "$(bin/forbidden shell-init bash)"     # in ~/.bashrc: then, in a terminal,
forbidden on                                #   [forbidden] from the next command on
forbidden status
forbidden off                               #   back (the directory is carried back; what was left running inside ends)

forbidden door add citlalpol --port 4600 --socket "$XDG_RUNTIME_DIR/citlalpol/door.sock" --proxy-protocol v2 --catch-all
forbidden run --door citlalpol -- curl http://pong.citlalpol.test/ping     # through the door only
forbidden run --strict --door citlalpol --dir ./the-tool -- ./the-tool/install.sh
```

A door that **catches all** (`--catch-all`, with PROXY v2) also takes what does not use the proxy settings: inside the wall the
default route goes to a dummy interface and nftables send every TCP connection to the door's relay, which tells the far side where it
was going (the header's destination) and who opened it, and every DNS question (UDP or TCP port 53, to any server) to the far side as
well; other UDP, ICMP and IPv6 (but the loopback) are refused at once. The program cannot change the rules. The same under
`--strict`: its sandbox shares the wall's network and nothing else.

Needs: bash, util-linux `unshare` (2.38 or later), iproute2 `ip`; python3 for a door; nftables `nft` for a door that catches all;
bubblewrap for `--strict`. Doors live in
`~/.config/forbidden/doors.json` and are changed only from outside the wall (the whole `~/.config/forbidden/` is read-only inside;
`forbidden hide add <path>` hides more paths inside, e.g. Citlalpol's config and records); a door leads only to a unix socket in your own
`$XDG_RUNTIME_DIR`. `test/run.sh` checks it all without reaching the network.

**Version 0.1.0** (2026-11-25), a development release. **Status:** the wall, `on` / `off` / `status`, doors with PROXY protocol v2, the hidden sockets, `--strict` (2026-11-24) and a door
that catches all, also under `--strict` (2026-11-25) work. Not yet: a door to a host TCP port, zsh / fish. The design: [docs/design.md](docs/design.md).
