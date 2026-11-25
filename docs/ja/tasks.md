# forbidden のタスク

tezcatl の agenda で管理する表です。下の表を tezcatl で開き、`:w replace #eigenvalue tasks` で印をIDに置き換えてから、
`task_table take` で取り込み（markdown パネルなら表の上で `t`）、task_table で `L` を押すと agenda（`C-c a`）に載ります。
agenda での変更は task_table の book に戻り、この文書へは task_table の `W` で戻します。

tezcatl のファイルの起点（`~/my_app`）から見たこの文書のパス：`no_nix/forbidden/docs/ja/tasks.md`

Table: forbidden_#eigenvalue

| id   | state | pri | task                                                                      | inner_id    |
|------|-------|-----|---------------------------------------------------------------------------|-------------|
| t-01 | DONE  | A   | 設計の叩き台を書く（design-memo.md）                                      | #eigenvalue |
| t-02 | DONE  | A   | 書く言語と扉の中継：bash と python3（自前の中継）                        | #eigenvalue |
| t-03 | DONE  | A   | F1：on / off / status / run、shell-init bash、loopback、userns の確認     | #eigenvalue |
| t-04 | DONE  | A   | 確かめ方 1：ping と curl が on で失敗、off で成功、ジョブは中に残る、cwd  | #eigenvalue |
| t-05 | DONE  | B   | F2：扉、扉の一覧の決まり（壁の外だけ、unix socket 既定、--tcp）、PROXY v2 | #eigenvalue |
| t-06 | TODO  | B   | 確かめ方 2：小さな Citlalpol を 4600 で経由して pong に届く               | #eigenvalue |
| t-07 | DONE  | B   | F3：肩代わり役の socket を隠す（D-Bus、Emacs、gpg、podman、nix-daemon）   | #eigenvalue |
| t-08 | DONE  | B   | F4：--strict（bubblewrap：ro のシステム、空の HOME、--dir、PID ns、端末） | #eigenvalue |
| t-10 | TODO  | C   | F5：proxy を読まないアプリの試みも扉へ                                    | #eigenvalue |
| t-09 | TODO  | C   | ライセンスを決める                                                        | #eigenvalue |
| t-11 | DONE  | A   | 設計 v0.2：扉の一覧の決まり、PROXY v2、--strict（約束を二段に）           | #eigenvalue |
| t-12 | TODO  | B   | --tcp：ホストの TCP への扉（壁の外の橋、持ち主の表示）                    | #eigenvalue |
| t-13 | TODO  | C   | zsh・fish の shell-init                                                   | #eigenvalue |
