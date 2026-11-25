# 始まりの話（2026-11-24, crux と Claude）

設計は [design-memo.md](design-memo.md) にあります。経緯の全体は Citlalpol の `docs/ja/idea.md` にあります。ここは forbidden に
かかわるところだけです。

1. 「偽の外」こそが Citlalpol の本体という方が適切かもしれない。forbidden という「外部へ向かうものを強制的に Citlalpol へ」を考える：
   `forbidden on` でその端末の次のコマンドからは外へ行くにはローカルホストの Citlalpol を経由し、`forbidden off` で切れる、という
   シンプルなシェルを定義する。
2. 権限の位置も考えなくて良くならないか：Citlalpol を例えば 4600 に充てて、4600 から通信すると考えればいい。
   → Claude：要るのは「壁を作る側が親で、対象から見える外は 4600 だけ」の一つ。PID namespace などは記録の正しさを守るためで、
   悪意のあるコードを範囲外にしている今は要らない。4600 はホスト側でなく namespace の中にだけ見せる（外の誰もが使える口にしない）。
3. forbidden を別のリポジトリにした（https://github.com/Crux-xurC/forbidden）。順序：
   (1) forbidden で通信を止められるか・off にできるか
   (2) Citlalpol を小規模に localhost として経由して ping を送れるか
   (3) その後に ping の 4 段のテスト
   文書としては「Citlalpol を使って契約テストをする際は、forbidden を入れた上で実行して、契約テストが不用意に外に行かないことを
   確かめてください」とすればよい。Citlalpol は access.json に記載のないものを全面禁止で作ればよくなるから簡単になる。
4. forbidden は通信できる localhost のアドレスを持つ仕組みと、それを弄れる仕組み（この権限は強めに設定した方が良い？）も用意しておく
   べきか。localhost（Citlalpol）への通信に HAProxy の PROXY protocol を乗せれば、Citlalpol から全部が 127.0.0.1 から来たように
   見える問題は解決できる。
   → Claude：強さは root ではなく「何を指せるか（unix socket が既定、ホストの TCP は明示と持ち主の表示）」「どこから変えられるか
   （壁の外だけ）」で持たせる。PROXY は v2 の TLV で、壁の中のどのプロセスからかを載せる。
5. 応用として、他者の作ったものを調べるときに Citlalpol を使う：安全性の分からないプログラムを検証したいときに、Citlalpol という
   ローカルホストに限定して不透明なホストへのアクセスを禁じる。この意味で doors の変更は硬いほうが良い。他所へ飛ばすローカルホストの
   プログラムがどこかに仕込まれていたときに、そこへのアクセスができてしまうパターンもありうる（その時点で危険な状態だから要らないと
   言えば要らないが）。
   → Claude：守る相手が悪意のあるかもしれないコードになるので、ネットワークの壁だけでは足りない（D-Bus・Emacs サーバー・gpg-agent への
   肩代わり、`~/.bashrc` を書いて壁の外で実行させる、`~/.ssh` を読む、名前解決での漏洩、TIOCSTI）。
   → crux：forbidden に `--strict` を入れて、約束を二段にする（普段は事故、`--strict` は普通の手段では出られない）。design-memo v0.2。
