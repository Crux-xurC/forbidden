# forbidden 設計メモ v0.3

2026-11-24 · @Crux（v0.2：扉の一覧の決まり、ホストの TCP への扉、中継が PROXY v2 を付ける、`--strict`（他人のプログラムを調べる）。
v0.3：F1〜F4 を実装した。実装で決まったことは「実装」の節）

## 概要

forbidden は**壁だけ**を受け持つ道具です。

- **すること**：`forbidden on` で、その端末の次のコマンドからはネットワークへ一切出られなくする。`forbidden off` で戻る。
  `forbidden run -- <command>` で、一つのコマンド（テスト、REPL）だけを同じ壁の中で動かす。
- **扉**：`--door <name>` で、壁の中に一つだけローカルのポート（例：4600）を開け、壁の外のプログラムにつなぐ。つなぐ先が
  Citlalpol（偽の外）です。forbidden は扉の向こうが何かを知りません。
- **二つの強さ**：
  - **普段**（`on` / `run`）：**事故を防ぐ**。テストや評価が不用意に外へ出ないこと。ネットワークだけの壁で軽い
  - **`--strict`**（`run --strict`）：**安全性の分からない他人のプログラムを調べる**。普通の手段では出られないこと：ネットワークに加え、
    ファイル・socket・プロセス・端末も見せるものを減らす（「--strict」の節）
- **しないこと**：宛先ごとの判断、記録。それは扉の向こう（Citlalpol）の仕事。カーネルの脆弱性を突くような手段を防ぐ保証
  （本当に怪しいものは仮想マシンで）。
- **対象**：Linux（unprivileged user namespace）。
- **状態**：F1〜F5 が動く（F5 は `--strict` でも、2026-11-25、`test/run.sh` の 41 項目）。まだ：ホストの TCP への扉、
  zsh・fish。始まりの話は [idea.md](idea.md)。

### Citlalpol・swallow との分担

| | 受け持つもの |
| --- | --- |
| forbidden | 壁（外への道をなくす）と、扉を一つ開けること |
| Citlalpol | 扉の向こうの偽の外：4600 で受け、`access.json` に書かれた宛先だけを通すか代役へ回し、書かれていないものは全面禁止。すべての試みを記録 |
| swallow | 偽の外の中で、段階 2・3（何を送るか、何が返ってきてほしいか）を受け持つ |

**文書での使い方の約束**：「Citlalpol を使って契約テストをするときは、forbidden を入れた上で実行し、契約テストが不用意に外へ出ない
ことを確かめてください」。

## 仕組み

- `forbidden on` / `run` は user namespace と network namespace を新しく作り（`unshare -rn` 相当。root は要らない）、その中で
  シェルかコマンドを起動します。中にあるのは自分だけの loopback で、外への経路はありません
- 中の loopback は `DOWN` で始まるので上げます（中でテスト用のサーバーを立てて自分に繋ぐもの、扉の 4600 のため）
- 名前解決は、中からは `/etc/resolv.conf` の DNS サーバーに届かないので、すぐ失敗します（試した：`curl` は
  `Could not resolve host`、`ping 1.1.1.1` は「ネットワークに届きません」、2026-11-24、この機械）
- **壁を作る側が親**：forbidden が namespace を作り、その中で対象を起動します。対象が forbidden を起動するのではありません。
  中の対象が何をしても（経路をいじる、扉の中継を止める）、外への道はなくなるだけです（安全側に倒れる）

## forbidden on / off（端末で）

```
forbidden on [--door <name>]   この端末の次のコマンドから、ネットワークへ出られない（扉があればそこだけ）
forbidden off                  元に戻る
forbidden status               今 on か、扉はどれか
```

- **シェルの関数として定義する**：`eval "$(forbidden shell-init bash)"` を `.bashrc` に書く（direnv などと同じ形）。zsh・fish は後で
- シェルは自分自身を namespace に移せない（シェルの組み込みが要る）ので、`on` は**一段内側のシェル**を起動します。プロンプトに
  `[forbidden]` が付きます。`off` はその内側のシェルを終えて外側に戻ります
- **戻るときに引き継ぐもの**：カレントディレクトリは外側のシェルに持ち帰る。内側で定義したシェルの変数や関数は持ち帰らない
  （正直な違い。履歴は同じ `HISTFILE` なので続く）
- **off は逃げ道にならない**：off で内側のシェルが終わると、**壁の中で走り続けていたもの（バックグラウンドのジョブ、サーバー）も
  終わる**（壁は PID namespace でもあり、その最初のプロセスが終わると中のものはすべて終わる。v0.1 の「中に残る」より分かりやすく、
  後に何も残らない）
- **重ねない**：on の中で on は断る
- tezcatl の端末（xterm）でもそのまま使える

## forbidden run（一つのコマンドで）

```
forbidden run [--door <name>] -- <command> [args…]
```

テストの実行や、Xipe Totec が REPL を起動するときに使います。終了コードは `<command>` のもの。

## 扉（door）

壁に開ける口です。

```json
// ~/.config/forbidden/doors.json（この機械の。リポジトリには入れない）
{ "citlalpol": { "port": 4600, "socket": "$XDG_RUNTIME_DIR/citlalpol/door.sock", "proxy_protocol": "v2" } }
```

- 壁の中の `127.0.0.1:<port>` で受け、壁の外の unix socket へ中継する。unix socket はファイルシステムを通るので、namespace の境を
  越えられる
- **ポートは壁の中にだけ開く**。ホスト側の `127.0.0.1:4600` に開くと、その機械のどのプロセスからでも繋げ、扉の向こうに「外へ通して」
  と頼めてしまう（tezcatl の relay に secret と ticket を付けたのと同じ問題）。壁の中にだけ開けば、外からは誰も使えない
- 扉があるとき、壁の中では proxy の環境変数を設定する：`ALL_PROXY=socks5h://127.0.0.1:<port>`、`HTTP_PROXY` / `HTTPS_PROXY=
  http://127.0.0.1:<port>`（と小文字の同名）、`NO_PROXY=localhost,127.0.0.1`。proxy の設定を読むアプリや道具（curl、多くの
  HTTP ライブラリ）は、宛先を自分で名乗って扉へ来る
- **proxy の設定を読まないアプリ**は壁で止まる（外へは出ない）。ただしその試みは扉の向こうに届かないので、記録には残らない。
  それも記録したくなったら、壁の中に名前解決と透過的な受け口を置く（F4）
- 扉の中継が止まれば、扉はなくなる（外へは出られないまま）

### 扉の一覧の決まり：何を指せるか、どこから変えられるか

扉は壁に開ける穴なので、強さは root を要求することではなく、**何を指せるか**と**どこから変えられるか**を絞ることで持たせます。

| 決まり | 理由 |
| --- | --- |
| 扉は `on` / `run` の時点で決まり、実行中に変えても今の壁には効かない | 走っている壁がその場で広がらない |
| 一覧の変更（`forbidden door add` / `rm`）は壁の外でだけ受け付ける。壁の中では `doors.json` を読み取り専用に見せる（`--strict` では見せない） | テストや調べている対象が設定を書き換えて、次の実行の壁を広げることを防ぐ |
| 扉の行き先は、既定では**自分専用のディレクトリ（`$XDG_RUNTIME_DIR`、0700）の unix socket だけ** | 扉が「ホストの何にでも繋がる穴」にならない |
| ホストの TCP（`127.0.0.1:5432` など）を指す扉は、`door add --tcp` と明示したときだけ作れる。作るときに、そのポートを今どのプログラムが持っているかを表示し、確かめてもらう。**`--strict` では使えない** | 下の注意のため |

**注意：ホストの localhost には、外へ出られるプログラムがいる**。この機械では tezcatl の relay（:4100：シェルを起動し、ファイルを書ける）
や Emacs（:4000）。壁の中からそこへ繋がる扉を開けると、その先を経由して外へ出られ、壁の意味がなくなる。他所へ飛ばすローカルの中継が
どこかに仕込まれていた場合も同じ。network namespace の中からはホストの localhost には届かないので、**扉を開けない限り**これらには
届かない。ホストの TCP への扉を「ふつうの操作」にしないのはこのため（tezcatlipoca のポートの持ち主の確認と同じ考え方）。

### 中継は PROXY protocol v2 を付ける

扉の中継は、壁の外へつなぐ最初に HAProxy の PROXY protocol v2 のヘッダーを付けます（`doors.json` の `"proxy_protocol": "v2"`）。

- 宛先は SOCKS5 や CONNECT で名乗られるので、もともと分かる。どの壁（実行）からかも、実行ごとに扉の socket を分ければ分かる。
  **PROXY で増えるのは、壁の中の「どのプロセスから」か**：中継は壁の中にいるので、接続元のポートから `/proc` を引いてプロセス
  （pid とコマンド）を特定できる。それを v2 の TLV（独自の追加項目）に載せる。実行の id もここに載せる
- v1 ではなく v2 にするのは、TLV を持てるから
- 扉の socket は、壁の中では中継にだけ渡し、対象からは見えなくする（`$XDG_RUNTIME_DIR/citlalpol` を壁の中に見せない）。見えると、
  対象が自分でヘッダーを書いて別のプロセスを名乗れてしまう
- 受ける側（Citlalpol）は、このヘッダーを扉の socket から来た接続でだけ信じる（Citlalpol の設計メモ）

## 抜け道：unix socket を通した肩代わり

unix socket が namespace の境を越えられるのは、扉が使う性質です。同じことが対象にもできます。

| 肩代わり役 | 何をさせられるか |
| --- | --- |
| D-Bus（`$XDG_RUNTIME_DIR/bus`） | systemd に頼んで、壁の外でサービスを起動する |
| Emacs のサーバー（`$XDG_RUNTIME_DIR/emacs`） | `emacsclient --eval` で、壁の外の Emacs に任意のコードを実行させる |
| gpg-agent（`$XDG_RUNTIME_DIR/gnupg`） | あなたの鍵で署名・復号させる |
| podman（`$XDG_RUNTIME_DIR/containers`）、dockerd（`/var/run/docker.sock`） | 壁のないコンテナを起動する |
| nix-daemon（`/nix/var/nix/daemon-socket`） | 外から取得させる |

（この機械の `$XDG_RUNTIME_DIR` に実際にあるもの、2026-11-24）

- 普段のモード：mount namespace で、既知の肩代わり役の socket を見えなくする（一覧は設定で持ち、増やせるようにする）。壁の外の
  デーモンが行う通信は範囲外（約束に書く）
- `--strict`：`$XDG_RUNTIME_DIR` そのものを見せない（一覧に頼らない）
- `nix develop` は壁の外で済ませてから中に入る（`nix develop -c forbidden run -- …`）。devShell を作るための取得は壁の外のこと

## --strict：他人のプログラムを調べる

安全性の分からないプログラム（他人が作ったもの、手に入れたばかりのツール）を、Citlalpol という偽の外だけを相手に動かして、どこへ
出ようとするかを調べるためのモードです。

```
forbidden run --strict [--door citlalpol] [--dir <調べるディレクトリ>] -- <command> [args…]
```

ネットワークだけの壁では、悪意のあるかもしれないコードには足りません。

| 道 | 普段のモード | `--strict` |
| --- | --- | --- |
| ネットワーク | 壁（扉だけ） | 同じ。扉は Citlalpol への一つに固定。ホストの TCP への扉は作れない |
| ファイルを書く（`~/.bashrc`、`~/.config/autostart`、git の hooks：壁の外で次に開いたシェルで実行される） | 書ける | システムは読み取り専用、`$HOME` は使い捨ての空の場所、`--dir` だけを渡す（書き込みは使い捨ての写しへ。元は変わらない） |
| ファイルを読む（`~/.ssh`、ブラウザのデータ、トークン） | 読める | 見えない |
| unix socket の肩代わり | 既知のものを隠す | `$XDG_RUNTIME_DIR` を見せない、`/var/run` の socket も見せない |
| 壁の外のプロセス（kill など） | 見える | PID namespace を分ける。権限をすべて落とす |
| 端末への入力の注入（TIOCSTI） | カーネルの設定次第（この機械は `dev.tty.legacy_tiocsti = 0` で塞がっている） | 新しいセッションで起動する（塞ぐ） |
| 対話のシェル | `on` が使える | `on` は使わせない。`run` だけ（`off` の後の外側のシェルに何かを残させない） |
| 扉の一覧 | 壁の中では読み取り専用 | 見せない。実行中に変えられない |

- 作り方は bubblewrap（この機械には 0.13.1 がある）：`--unshare-all`、`--ro-bind` でシステム、`--tmpfs $HOME`、`--new-session`、
  `--cap-drop ALL`、`--die-with-parent`。扉の中継だけを壁の中に置く
- Citlalpol の側も合わせる：宣言のない名前は**名前を引く前に**禁止する（名前そのものでデータが漏れる：`<盗んだデータ>.attacker.example`）。
  調べるときは `pass` の宛先を置かないことを勧める（置けば持ち出しの道になる）。扉から届く入力は信頼できないものとして読む
- **約束できるのは「普通の手段では出られない」まで**。カーネルの脆弱性を突くようなものは防げない。本当に怪しいものは仮想マシンで

## 確かめ方（順序）

1. **forbidden だけ**：`forbidden on` の中で `ping 1.1.1.1` と `curl https://example.com` が失敗し、`forbidden off` の後で成功する。
   `on` の中で起動したバックグラウンドのジョブが、`off` の後も出られない。カレントディレクトリが持ち帰られる
2. **扉を通す**：`forbidden on --door citlalpol` の中で、小さな Citlalpol を localhost（4600）として経由し、ping（`curl` で
   `GET /ping`）が偽の外の pong に届く。扉の向こうに宣言のない宛先は届かない
3. **ping の 4 段**：Citlalpol と swallow の受け入れ（Citlalpol の設計メモ）

1 は ICMP の `ping` そのままで確かめられます（壁は ICMP も止める）。2 からは扉を通るので、proxy を通れる TCP（HTTP）の ping です。

## 注意：user namespace が使えない環境

- `kernel.unprivileged_userns_clone=0`（一部の Debian 系の設定）や、Ubuntu 23.10 以降の AppArmor による制限
  （`kernel.apparmor_restrict_unprivileged_userns=1`）では、root なしに namespace を作れない。そのときは理由と、何を許せばよいかを
  言って止まる（黙って壁なしで走らない）
- この機械（Arch）では使える（確かめた）

## 実装（v0.3）

| ファイル | 役割 |
| --- | --- |
| `bin/forbidden` | コマンド（bash）：`run` / `on` / `off` / `status` / `door` / `shell-init` / `check` |
| `lib/inside.sh` | 普段のモードの壁の準備（壁の中、その user namespace の root として）：loopback を上げる、扉の中継を起動してから socket のディレクトリを tmpfs で隠す、`doors.json` を読み取り専用に、肩代わり役の socket を隠す、最後に**もう一段の user namespace で自分の uid に落として**コマンドを起動（壁のネットワークと mount に対する権限を持たない：loopback を落とせない、隠したものを外せない） |
| `lib/relay.py` | 扉の中継（python3）：壁の中の `127.0.0.1:<port>` → 壁の外の unix socket。socket は**ディレクトリの fd 越し**（`/proc/self/fd/<fd>/<name>`）で繋ぐので、ディレクトリを壁の中で隠しても届く（`--dirfd` は今は使っていない） |
| `test/run.sh`、`test/fake_door.py` | 確かめ方の 1・2 と `--strict`（ネットワークに出ない。`FORBIDDEN_TEST_NET=1` で「壁の外では届く」も） |

- **壁の作り方（普段）**：`unshare --user --map-root-user --net --mount --pid --fork --mount-proc --kill-child` の中で `lib/inside.sh`、
  その最後に `unshare --user --map-user=<uid> --map-group=<gid>`。準備できないものがあれば穴のある壁で走らせず、125 で止まる
- **壁の作り方（`--strict`）**：普段の壁（`lib/inside.sh`：loopback、扉の中継、すべてを受ける扉の nftables、設定を読み取り専用）を作り、その中で
  bubblewrap を起こす（2026-11-25、F5 を `--strict` でも効かせるため）。bubblewrap はネットワークだけ壁のものを共有し、ほかは
  `--unshare-user --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup-try`、`--die-with-parent --new-session --cap-drop ALL --clearenv`、`/usr`・`/etc`・
  `/nix/store` は読み取り専用、`$HOME`・`/tmp`・`/run` は空、`--dir` は使い捨ての写し（終わると写しの場所を言う）。環境変数は
  `PATH`・`HOME`・`USER`・`LANG`・`TERM` と forbidden のものだけ（`GITHUB_TOKEN` などは渡らない）
- **PROXY v2 の TLV**：`0xE0` 実行の id、`0xE1` pid、`0xE2` コマンド（`/proc/<pid>/cmdline`、1024 バイトまで）、`0xE3` モード
  （`normal` / `strict`）、`0xE4` via（すべてを受ける扉から：`redirect` / `dns`）。Citlalpol と合わせる
- **環境変数（壁の中）**：`FORBIDDEN_ACTIVE`、`FORBIDDEN_MODE`、`FORBIDDEN_RUN`、`FORBIDDEN_DOOR`、扉があれば proxy の変数
- **ping**：壁の中の `ping_group_range` を開けておく（壁の中の一つの group）。権限のない ping も ICMP の datagram socket を使えるので、
  「権限がない」ではなく「ネットワークに届きません」と正しい理由で失敗する（crux が試して気づいた、2026-11-24）
- **`on` の中**：`--rcfile` で `~/.bashrc` を読み、`forbidden` の関数を定義し直し、プロンプトに `[forbidden]`、終わるときにカレント
  ディレクトリを書き出す
- **隠す socket（普段）**：`$XDG_RUNTIME_DIR` の `bus`・`emacs`・`gnupg`・`containers`・`podman`・`docker.sock`・`systemd`、
  `/run/dbus/system_bus_socket`、`/run/docker.sock`、`/run/podman`、`/nix/var/nix/daemon-socket`、`~/.gnupg/S.*`、それに
  `~/.config/forbidden/hide`（一行一パス）。ディレクトリは tmpfs、socket は `/dev/null` で覆う
- **すべてを受ける扉（F5、`--catch-all`）**：TUN と tun2socks ではなく nftables の REDIRECT にした（2026-11-25）。tun2socks を挟むと
  扉に来る接続がすべて tun2socks のものになり、記録の pid とコマンドが失われる。REDIRECT なら中継が受ける接続の相手はプログラムの
  socket そのもので、行き先は `SO_ORIGINAL_DST` で読める。壁の中：既定の経路をダミーのインターフェース（`forbidden0`、192.0.2.1）へ、
  nat の output で TCP（loopback 以外）を中継の `<port>+1` へ、DNS（UDP の 53、どのサーバー宛ても。TCP の 53 は前者に含まれる）を
  `<port>+53` へ。filter の output で、それ以外（UDP、ICMP、loopback 以外の IPv6）は即座に拒否。規則は壁の root が置き、コマンドは
  一つ内側の user namespace で動くので消せない。PROXY v2 の宛先アドレスに元の行き先、TLV `0xE4`（via）に `redirect` / `dns`。DNS は
  問い一つにつき接続一つ、長さ 2 バイト＋本文（DNS over TCP の形）。扉は一つだけが受けられる。名前解決を壁の外の常駐に頼む口
  （`/run/systemd/resolve`、`/run/avahi-daemon`、`/run/nscd`）も隠す
- **扉の行き先の確認**：`door add` と実行のたびに、socket が `$XDG_RUNTIME_DIR` の中かを確かめる。`--tcp` はまだ作っていない
  （そう言って止まる）

## マイルストーン

| | 内容 | 終わったと言える条件 |
| --- | --- | --- |
| F0 | この設計 | 未決のうち F1 に要るものが決まる |
| F1 ✔ | `on` / `off` / `status` / `run`、`shell-init bash`、loopback を上げる、user namespace が使えないときに止まる | 確かめ方の 1 が通る |
| F2 ✔（`--tcp` を除く） | 扉（`doors.json`、壁の中の port → unix socket の中継、proxy の環境変数）、扉の一覧の決まり（`door add` / `rm` は壁の外だけ、unix socket が既定、`--tcp` は明示と持ち主の表示）、PROXY v2（pid とコマンド、実行の id） | 確かめ方の 2 が通る（小さな Citlalpol と一緒に）。壁の中から `doors.json` を書き換えられない。扉の向こうの記録に、出ようとしたプロセスのコマンドが載る |
| F3 ✔ | 肩代わり役の socket を隠す | `on` の中から D-Bus・Emacs・gpg-agent・podman・nix-daemon の socket が見えない |
| F4 ✔ | `--strict`（bubblewrap） | 調べる対象が `~/.bashrc` を書き換えようとしても元は変わらない、`~/.ssh` が見えない、`$XDG_RUNTIME_DIR` が見えない、壁の外のプロセスが見えない。扉は Citlalpol だけ |
| F5 ✔ | proxy を読まないアプリの試みも扉へ（名前解決と透過的な受け口） | 直接 socket を開くプログラムの試みも、扉の向こうの記録に残る |

## 未決

- ホストの TCP への扉（`--tcp`）の作り方（壁の外に unix socket → TCP の橋を置く）
- zsh・fish 版
- tezcatl の端末を `on` で始める選択肢
- 扉を二つ以上許すか（今は一つ。`--strict` では Citlalpol の一つに固定）
- `--strict` で `--dir` の書き込みを使い捨ての写しにするか、読み取り専用にするか（調べる対象がビルドする場合）
- ライセンス
