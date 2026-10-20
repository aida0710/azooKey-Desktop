# Linux入力の応答時間と復旧

IBusのキー受付から、変換器の起動・JSON通信・終了待ちを分離する。入力、設定変更、学習リセットは1本のworkerへ順番に渡し、表示と確定はGLibのメインループで行う。変換器はIBusサービス全体で共有し、入力欄ごとの破棄で別の変換器を重ねて起動しない。

## 順序と入力欄

`InputCoordinator`は入力欄ID、取消世代、変換器の再起動世代を保持する。フォーカス移動、reset、パスワード欄への切替、engine破棄で取消世代を更新する。古い応答に含まれる確定、未消費キー、AI候補は新しい入力欄へ渡さない。

応答済みの未消費キーは、それ以前の確定の後にアプリへ返す。英数モードの通常文字や矢印など、Coreの状態を変更しない入力は先行キーの処理後に直接返す。これにより、`a → Left → b`の途中に応答が届いても順序を保てる。

待機中の`InputPreview`は、確認済みのpreedit、読み、読みカーソルと未応答キーを使って入力を保全する。かな変換や候補生成は行わない。未完了の変換があるままフォーカスを移すと、最後に確認できた文字または読みと、未処理の文字を保全する。未取得の変換候補は推測しない。

bridgeは`inputState`とUnicode scalar位置の`readingCursor`を返す必要がある。実bridgeのJSONを使う`test_bridge_preview.py`で、変換応答後のEscapeと、読みの途中の編集位置を検査する。AI候補表示中の追加入力は、Coreと同じく元の読みへ追記する。応答前にフォーカスを移してもAI候補を確定しない。

候補取消と全文取消、Enterで先に確定した部分、Left/Right、Home/End、Backspace/Delete、Ctrl+hを区別する。文字境界には、GTKが依存するPangoの[Unicode grapheme boundary](https://docs.gtk.org/Pango/struct.LogAttr.html)を使う。保全用バッファの外を編集する操作や扱えないネイティブ操作は、先行入力を回収してアプリへ返す。

物理キーボードでは、Shift+LeftはShift自体の押下、Shift付きLeft、Shiftの解放として届く。Shift・Control・Alt・Superなどの修飾キー単独を編集として予測せず、キー解放と同様にネイティブイベントの順序を保つ。[XKBの修飾keysyms](https://github.com/xkbcommon/libxkbcommon/blob/master/include/xkbcommon/xkbcommon-keysyms.h)を文字入力と区別する。回帰試験は待機中と250ms/2秒の応答待ちでpress/releaseを送り、途中確定と文字キーの転送が起きないこと、続く修飾付き矢印とEnterが一度だけ確定することを確認する。

## Escape、focus-out、reset

Escapeは通常のCore入力として順序を保って処理する。応答待ち中も候補を隠すが、Spaceの後のEscapeで読みを消さない。修飾付きEscapeを無条件の全文破棄として扱わない。

IBusの`PREEDIT_COMMIT`モードでは、daemonがfocus-outまたはInputContextのreset時に可視preeditを元の入力欄へ確定し、その後engineへ通知する。engineから遅れて同じ文字を確定すると重複や別欄への混入につながるため、この通知では取消と表示の片付けだけを行う。入力を取り消す操作はEscapeとする。これは[IBus Engineの契約](https://ibus.github.io/docs/ibus-1.5/IBusEngine.html#ibus-engine-update-preedit-text-with-mode)と[InputContextの実装](https://github.com/ibus/ibus/blob/1.5.29/bus/inputcontext.c#L1696-L1758)に基づく。

## 待機の上限

- キー受付の回帰試験上限は100 ms。250 ms・2秒の変換待ちと切り離して検査する。
- 3秒間どの要求も進まなければ、確認済みpreeditを1回だけ回収し、未応答の物理キーを順にアプリへ戻す。取消・読み編集が含まれる場合は編集後の文字を保全し、取り消したキーを再挿入しない。
- その後の入力はアプリへ直ちに返す。古い要求の終了とresetの完了後、変換入力を再開する。
- 変換器への通信上限は30秒を維持する。初回モデルロードを3秒で毎回強制終了することはない。応答が続いていれば進捗期限を更新する。
- 変換器が処理したか不明な要求は再送しない。サービス終了時の子プロセス停止も、メインループで終了を待たない。

## 再現と計測

Ubuntu 24.04向けの試験環境で実行する。必要な依存関係は既存のDocker定義に含まれ、これらのスクリプトはホストへパッケージを追加しない。

```sh
python3 -m unittest discover -s Linux/tests -p 'test_*.py'
bash Tools/tests/linux-async.sh
AZOOKEY_BRIDGE=/path/to/azookey-desktop-bridge \
  dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh

AZOOKEY_BRIDGE=/path/to/azookey-desktop-bridge \
  python3 Tools/measure-linux-input.py --samples 10
AZOOKEY_BRIDGE=/path/to/zenzai-bridge AZOOKEY_RESOURCES=/path/to/verified-models \
  python3 Tools/measure-linux-input.py --samples 10 --zenzai
```

遅延試験は固定の模擬入力だけを使う。入力順序、Enter連打、Escape、2つの入力欄、reset、無応答、kill後の次の入力、設定読込失敗、カーソル編集を実IBusで検査する。設定と学習先、D-Bus、Xvfbは試験ごとに隔離する。

ソース試験では[IBusのcomponent検索パス](https://manpages.ubuntu.com/manpages/noble/man1/ibus.1.html)を空の一時フォルダーに限定し、addressファイルとキャッシュも隔離する。これにより、先に導入したパッケージがソースの登録前に自動起動する競合を防ぐ。試験後は実サービスのPIDが起動したソースプロセスと一致することを検査し、実行パスとSHA256を記録する。`AZOOKEY_INSTALLED_TEST=1`による配布物の試験では、導入済みcomponentを使う。

計測スクリプトは短文7文字と長文94文字を各10回、新しいプロセスで入力する。初期化、最初のキー、最初の文、同じ文の再入力についてp50/p95/maxをJSONで出す。ここで初回とはプロセスの初回であり、OSのページキャッシュを消した条件ではない。測定値はbridge往復時間で、画面描画完了までの時間ではない。Zenzai測定は`zenzaiLoaded`を検査し、辞書変換だけで成功としない。

2026-10-20のUbuntu 24.04 amd64 VM・2 vCPUで、AI候補後の編集を含む35キーを検査した。250 ms遅延時の受付はp50 1.285 ms、p95 2.443 ms、最大3.362 ms、2秒遅延時はp50 1.124 ms、p95 3.011 ms、最大3.052 msだった。

Zenzai CPU版（`a07fd43`、release、検証済みモデル、1 CPU・4 GiBコンテナ）のbridge往復時間は次の通り。各文を新規プロセスで10回測り、同じ文をもう一度入力した。ライブ変換を有効、学習を無効にした。

| 入力 | 初回の文 p50 / p95 / max | 同文再入力 p50 / p95 / max |
| --- | --- | --- |
| 7文字、90キー | 91.090 / 298.744 / 389.290 ms | 3.210 / 4.876 / 90.740 ms |
| 94文字、960キー | 110.857 / 790.148 / 1704.969 ms | 8.688 / 14.647 / 75.696 ms |

基点`526f0ae`の通常辞書・debug・1 CPUコンテナでは、長文の再入力960キーのbridge往復時間がp50 50.684 ms、p95 150.634 ms、最大716.929 msだった。モードやビルド、測定範囲が異なるため、受付時間やZenzaiの値との速度比較には使わない。

この試験はGTK・Qt・Chromiumの実ウィジェットやGNOME Waylandでの検証を代替しない。配布パッケージ、コミット、表示方式を固定して、アプリ切替・候補選択・入力中の編集・無応答復旧を引き続き確認する。macOSの実アプリ検証はAppleハードウェア側の別ゲートとして扱う。
