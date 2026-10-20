# Linux の未処理キーを元のイベントで返す

通常の入力順序は `InputCoordinator` に集約する。未確定入力も待機中の要求もなく、アプリが元のキーを処理できる場合、`do_process_key_event` は直ちに `False` を返す。対象は未処理の移動キーやショートカット、英数モードの通常文字など。Ctrl+S、Ctrl+Shift+U、設定済みの選択文AIショートカット、変換中の Control 操作、IME が表記を選ぶ円記号とバックスラッシュはこの近道へ入れない。

先行する確定や言語切替が待機中なら、元の `ProcessKeyEvent` 呼出しを保持する。先行要求の描画・確定を済ませてから、未処理キーの元の応答を返す。`NativeKeyReply` は応答を一度だけ完了し、キーの press/release を同じ順序で扱う。変換ワーカーの待機は引き続き IBus のメインループの外にある。

Reset は未確定入力を消すが、Core の入力言語は維持する。リセット前の言語を保持し、応答時に Core の言語と照合する。応答前でも、通常文字と修飾なしの言語キーはどちらの言語でも Core が消費するため、直ちに受け付けて Core へ送る。移動キー等の元の呼出しは保留し、リセット失敗時は古い言語を破棄する。既に処理済みと応答した文字を後から native 配送へ切り替えない。元キーを返す前に回収用の未確定表示を消し、GTK が同じ文字を未確定表示とキーの両方から挿入することを防ぐ。

## 公開 API と入力クライアント

`IBus.Service.service_method_call` は公開された仮想関数で、元の `Gio.DBusMethodInvocation` を受け取れる。`Gio.DBusMethodInvocation` 自体が非同期の完了に使うオブジェクトである。保留した未処理キーは親の IBus dispatcher に戻し、通常の extension filter と応答処理を保つ。独自の D-Bus 接続・非公開関数・同期 wait は使わない。[IBus 1.5.29 の dispatcher](https://github.com/ibus/ibus/blob/1.5.29/src/ibusengine.c#L1198)、[Gio の非同期応答](https://docs.gtk.org/gio/class.DBusMethodInvocation.html)。

Qt 6.4.2 の `ForwardKeyEvent` はキーを再構築する一方、未処理の元の応答では保存済みの window、key、modifiers、text を使う。Wayland の Ctrl+Home 停止では実際に ForwardKeyEvent を経由し、Qt のキー再構築中で停止する stack を確認した。この修正は元の応答経路を使う。[Qt 6.4.2 の入力クライアント](https://github.com/qt/qtbase/blob/v6.4.2/src/plugins/platforminputcontexts/ibus/qibusplatforminputcontext.cpp#L409)。

IBus 1.5.29 の GTK4 module は既定で同期モード、GTK3 は非同期モードである。元の応答を保留すると、共有 IBus が応答していても GTK4 アプリの呼出し元は先行変換を待つ。正しい文字配送と UI の待ち時間を別々に記録する。試験だけで同期設定を変えて合格にしない。[IBus GTK module の既定](https://github.com/ibus/ibus/blob/1.5.29/client/gtk2/ibusimcontext.c#L106)。

## フォーカス移動・失敗時の扱い

- 待機中の英数字と読みは既存の入力予測へ残す。フォーカス移動では IBus の COMMIT モードが古い欄へ一度だけ回収し、保留した元キーは処理済みとして完了する。遅い応答を次の欄へ返さない。
- 予測できないホストのショートカットを待つ間も、その後の表現可能な文字入力を回収用の表示へ残す。フォーカスが失われたときは、そのショートカットを別欄で再生せず、表示されていた文字だけを古い欄へ回収する。
- 変換器の失敗・進捗停止では、既に受け付けた未応答入力の既存回収と元キーの応答を一度だけ行う。元キーの応答を保持していない従来の回復経路は引き続き ForwardKeyEvent を使う。
- 再変換待ちの `ReconversionCoordinator.queued` は別の入力保留経路である。この変更では元呼出しの保持へ移行していない。再変換失敗・取消時の Ctrl+Home 等は別の未確認条件として残す。

## 検査

`Tools/tests/linux-async.sh` は既存の入力回帰に加えて、実 IBus daemon 上で `ibus_native_keys.py` を 250ms / 2秒遅延で実行する。元の `False` 応答と ForwardKeyEvent を別々に観測し、次を検査する。

- Muhenkan → Shift+A → Left → Shift+B の順序と本文 BA。
- Enter → Control press → Home press/release → Control release の順序。確定後に Home を返し、ForwardKeyEvent は出さない。
- 待機中の focus-out / Reset / 変換器無応答と停止で、元欄の一度だけ回収・別欄への挿入なし・応答の一度だけ完了。
- 独立した GetEngine 呼出しの応答時間。これは保留キー自身の応答時間と区別する。

`ibus_native_toolkits.py` は別プロセスの GTK4 / Qt の実入力欄へ XTest キーを送る。日本語モードの未確定表示とロード済み IBus module を陽性対照とし、元文書・カーソル・native 挿入イベント・UI timer を保存する。IBus GTK4 module、PyQt6、Xvfb、libXtst を備えた専用環境で実行する。

英数モードの `Shift+A → Left → Shift+B` では本文 `BA`・カーソル1を確認する。別の試行では既存本文 `pq` の途中へ日本語モードで `a → Enter → Ctrl+Home` を送り、本文 `paq`・カーソル0・各文字の一度だけの挿入を確認する。空欄だけの試験で確定と Home の順序を推定しない。

```sh
export AZOOKEY_BRIDGE="$PWD/Linux/tests/fixtures/delayed_bridge.py"
export AZOOKEY_IBUS_TEST=Linux/tests/ibus_native_toolkits.py
export AZOOKEY_TEST_DELAY=0.25
export AZOOKEY_NATIVE_ARTIFACTS=/tmp/azookey-native-evidence
export XDG_RUNTIME_DIR="$(mktemp -d /tmp/azookey-native-runtime.XXXXXX)"
chmod 700 "$XDG_RUNTIME_DIR"
dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
```

Xvfb と合成変換器の成功は、配布物の Zenzai・Wayland・Orca・実アプリ受入を代替しない。配布物の完全な SHA を固定し、GTK4 の大文字/矢印、Qt の Ctrl+Home、入力中と確定待ち、Orca ON/OFF を別に確認する。
