# 模擬 AI を使って元の入力欄への適用を検証する

この手順は、専用 Ubuntu VM で配布物を検証する担当者向けです。GTK、Qt、独立した Chromium の二欄 fixture を使い、元欄への適用が一度だけであること、別欄や Reset 後には書き込まないことを確認します。外部 AI は使いません。

設定の退避と mock の起動を済ませてから、条件表に沿って試行します。終了時は設定を復元してください。これは試験手順であり、各アプリの合格記録ではありません。実行結果は、製品 source の commit、deb の SHA256、fixture の commit と同じ試行に保存します。

## 配布物を照合してから設定を退避する

新しい配布物の導入後、起動中の engine / bridge が `/opt/azookey-tree` のファイルと一致することを確認します。開発 source の差し替えや provider の置換を併用しません。既存の `Linux/tests/ibus_ai_target.py` は実 IBus・AT-SPI の回帰ですが、provider を置換するため、この配布物 GUI 試験とは分けます。

VM の既存デスクトップ環境を継承した user systemd の task unit から起動します。`DISPLAY` だけを SSH へ渡したり、X11 認証を解除したりしません。以下のパスは専用 VM 内の例です。

```bash
umask 077
ai_trial_directory=/home/azookey/ux-acceptance/ai-new-package-gtk-original
mkdir -m 700 "$ai_trial_directory"
fixture_tools=/home/azookey/ux-acceptance/ai-tools
python3 "$fixture_tools/ai_fixture_preferences.py" backup \
  --directory "$ai_trial_directory/preferences-original" \
  --source /home/azookey/.config/azookey-tree
```

退避する既存ファイルは `settings.json`、`settings.last-good.json`、`prompts.json` の三つです。元の bytes、存在・不在、mode、SHA256 を記録します。保存した JSON は VM 内だけに置き、共有成果物には内容をコピーしません。manifest の hash と照合結果だけを共有します。後の `apply` は、有効な設定値も同じ退避先へ 0600 で保存します。

API キーは次の専用 helper で用意します。既存の `org.azookey.Tree` / `openai-compatible` 項目が一つでもあれば停止し、その値を読みません。新規項目は偽キーだけを session collection へ保存し、試行ごとの UUID 属性で識別します。既存キーの書き換えや退避はしません。メタデータ検索に `LOAD_SECRETS` と `UNLOCK` を使わない点は、[libsecret の検索契約](https://gnome.pages.gitlab.gnome.org/libsecret/method.Service.search_sync.html)に従います。

```bash
python3 "$fixture_tools/ai_fixture_key.py" create \
  --state-file "$ai_trial_directory/key-state.json"
```

既存キーがあった場合は GUI 試験を開始せず、VM 担当者へ状況を渡します。キーの中身は報告しません。ここからの Secret Service 実接続は、新しい配布物を確認する段階で実施します。

## 要求の到着を確認してから応答を解放する

`Tools/tests/ai_mock_server.py` は `127.0.0.1` の動的ポートだけに bind します。外部への転送機能はありません。既存 bridge 回帰と同じ OpenAI 互換 JSON を返し、model が `fixture-model`、messages に合成対象 `TARGET_TEXT` がある要求だけを記録します。認証ヘッダーは記録しません。

```bash
systemd-run --user --collect --unit azookey-ux-ai-mock \
  --property="StandardOutput=append:$ai_trial_directory/mock-process.log" \
  --property="StandardError=append:$ai_trial_directory/mock-process.log" \
  /usr/bin/python3 "$fixture_tools/ai_mock_server.py" serve \
  --directory "$ai_trial_directory/server"
```

`server/server.json` の作成と `/state` の応答を確認したら、配布物内の `SettingsStore` を使って AI の設定を変えます。変更するのは有効化、loopback endpoint、`fixture-model`、周辺送信 OFF、ショートカット `Control+S` だけです。候補の表示設定や学習設定は変えません。

```bash
python3 "$fixture_tools/ai_mock_server.py" state \
  --state-file "$ai_trial_directory/server/server.json"
python3 "$fixture_tools/ai_fixture_settings.py" apply \
  --directory "$ai_trial_directory/preferences-original" \
  --server-state "$ai_trial_directory/server/server.json"
```

送信後、`requests.jsonl` の `received` と対象 ID の `state: waiting` を確認します。その状態で焦点や Reset の条件を作り、次のコマンドで **その ID だけ**を解放します。固定 sleep を、焦点移動や設定反映の完了判定に使いません。

```bash
python3 "$fixture_tools/ai_mock_server.py" release \
  --state-file "$ai_trial_directory/server/server.json" \
  --request-id 1 --outcome success
```

成功時の変換結果は `変換した本文` です。`--outcome empty` は空結果、`failure` は HTTP 503 を返します。45 秒以内に解放しなかった要求は 504 となり、その試行を成功扱いしません。再送時は新しい要求 ID を記録します。

## 二つの欄を同じ文字と選択範囲にする

GTK と Qt の fixture は `fixture_events.py`、`fixture_reset.py` と同じディレクトリへコピーし、`--output state.json --events events.jsonl` を付けます。既存の events ファイルには追記できません。Chromium は `ime-editor.html` を専用 profile で開き、loopback CDP から `window.imeFixture.snapshot()` / `observations()` を読み取ります。試行前後の履歴が同じ `ready` イベントから始まり、試行前の履歴全体が末尾の履歴にも残ることを照合します。2,000 件の上限に達した履歴から挿入数の完全性を推定しません。QtWebEngine は独立 Chromium の代わりに数えません。

実キーボードで英数モードへ切り替え、両欄へ `PRIVATE_BEFORE TARGET_TEXT PRIVATE_AFTER` を入力します。元欄の `TARGET_TEXT` だけを選択し、本文・選択範囲・実焦点を保存します。二欄の内容と選択範囲を等しくすることで、文字列の一致だけに頼った誤適用を見つけます。CDP や AT-SPI の編集 API で本文を作りません。

`Control+S` で AI ダイアログを開き、送信先が `127.0.0.1:<port>`、対象が `TARGET_TEXT`、周辺送信が OFF であることを記録します。指示は `fixture rewrite` とし、「AI へ送信してプレビュー」を一度操作します。要求には `TARGET_TEXT` があり、`PRIVATE_BEFORE` / `PRIVATE_AFTER` がないことを確認します。周辺 ON の確認は別試行で行い、両方の周辺文字列が要求に入ることを確認します。

以下の各条件を GTK・Qt・Chromium で別々に記録します。元欄は field 1、別欄は field 2 です。

| 条件 | 応答を解放する前後の操作 | 本文と挿入回数の期待値 |
| --- | --- | --- |
| 元欄へ適用 | `waiting` を確認して解放。プレビューを確認し「本文へ適用」を一度操作する | field 1 が `PRIVATE_BEFORE 変換した本文 PRIVATE_AFTER`。結果の挿入は 1 回、field 2 は元の全文を保持 |
| 同じ文字を持つ別欄 | 結果表示後、field 2 の同じ対象を実キーで選択。ダイアログへ戻って適用を試す | 両欄の本文は元のまま。結果の挿入は 0 回。適用拒否の説明とコピーの可否も保存 |
| 遅い応答中に別欄へ移動 | `waiting` の間に field 2 を選択してから解放する | field 2 へ結果を挿入しない。結果が破棄されたか、適用不可のプレビューになったかを実際の状態で記録 |
| Reset 後の遅い応答 | `waiting` の間に保存した元 context へ Reset を送り、その通知を確認してから解放する | 両欄への結果の挿入は 0 回。古い結果から適用を再開しない |
| 結果表示後の Reset | 結果表示後、適用前に元 context を Reset する | 結果の挿入は 0 回。元欄へ戻っても適用が復活しない。保存済みプレビューとコピーの状態を記録 |

Reset は通常入力とは別の障害注入です。元欄を選択した時点で `ai_context_identity.py --context-file <new-file>` を実行し、bus GUID と元 context を記録します。IBus は [context を作成した接続だけからの操作を許可](https://github.com/ibus/ibus/blob/1.5.29/bus/inputcontext.c#L1288)するため、別プロセスからその path へ Reset を送る方法は使いません。

GTK・Qt は `--reset-controls` を明示したときだけ、非 focus の試験ボタンを表示します。AI ダイアログを前面に保ったまま、そのボタンを AT action で一度操作します。GTK の `Reset input context 1` は欄 1 の [`Gtk.TextView.reset_im_context`](https://docs.gtk.org/gtk3/method.TextView.reset_im_context.html)、Qt の `Reset retained input context` はアプリの [`QInputMethod.reset`](https://doc.qt.io/qt-6/qinputmethod.html#reset)を呼びます。Qt には欄を指定する引数がないため、直前に実 focus を持った欄を記録し、別欄の context と見なさないでください。本文や選択を作る API は呼びません。

`reset-requested` と `reset-returned` はアプリ内 API の記録であり、配達の成功ではありません。ボタン操作前後に AI ウィンドウが active のままであること、元欄の本文と選択が変わらないこと、同じ試行内で製品 engine へ実際に `Reset` が届くことを別々に確認します。IBus の [Reset 転送は context に engine がある場合だけ](https://github.com/ibus/ibus/blob/1.5.29/bus/inputcontext.c#L1109)なので、非 active の context から配達されなければ、その条件を未検証として残します。Chromium に同じ公開 API の試験操作は用意していません。GTK/Qt の結果を転記しません。

合成テキストの試行中だけ、同じ user session で次の監視を使います。`FocusInId` の context path と engine object path を結び付け、同じ engine への `Reset` を確認します。アプリから自然に届いた Reset と、試験ボタンによる明示 Reset を、時刻と送信元で区別します。

```bash
ibus_address=$(ibus address)
systemd-run --user --collect --unit azookey-ux-ai-context-monitor \
  --property="StandardOutput=append:$ai_trial_directory/ibus-context.log" \
  dbus-monitor --address "$ibus_address" \
  "interface='org.freedesktop.IBus.Engine',member='FocusInId'" \
  "interface='org.freedesktop.IBus.Engine',member='FocusOutId'" \
  "interface='org.freedesktop.IBus.Engine',member='Reset'" \
  "interface='org.freedesktop.IBus.InputContext',member='CommitText'"
```

GTK は `insert-text`、Qt は `input-method` の `commit`、Chromium は `input` イベントから結果の挿入を数えます。`state` の重複記録や `beforeinput` をもう一回の確定として数えません。本文・焦点・選択範囲も照合し、試行の末尾で元欄へ追加入力します。拒否条件では、改めて元欄へ戻っても古い結果が遅れて入らないことを確認します。

## 元の設定へ戻して照合する

全 AI ダイアログと設定画面を閉じ、未応答要求を解放または期限切れまで観測してから復旧します。本文・焦点・イベントの最終観測を保存し、復旧中は他のキー操作を止めます。`restore` は専用 VM の入力方式を一時的に US 英数へ切り替え、配布物の engine / bridge だけを停止します。停止は [pidfd](https://docs.python.org/3/library/os.html#os.pidfd_open) で同じプロセスを参照し、終了通知を待ちます。開いた設定画面や別 source の engine があれば拒否します。

実行元はsession busの`org.azookey.Tree`から確認します。[D-Busの接続PID取得](https://dbus.freedesktop.org/doc/dbus-specification.html#bus-messages-get-connection-unix-process-id)を使い、取得前後で所有者が変わっていないことと、配布物のentrypointであることを照合します。IBusの専用busはこのPID取得APIに対応していません。稼働中のazooKeyを特定できなければ停止せず、US英数へ切替済みでazooKeyも終了済みの場合だけ、所有者なしでも復旧を再開できます。

次に、退避した設定を配布物の Core に適用し、三つの JSON を元の bytes と存在状態へ戻します。復元前には、現在の `XDG_CONFIG_HOME` に対応する保存先と manifest の保存先も照合します。異なる場合は、IME の停止や Core への送信を始めません。元ファイルが部分 JSON でも完全な JSON に置き換えたままにはしません。

```bash
systemctl --user stop azookey-ux-ai-context-monitor
python3 "$fixture_tools/ai_fixture_settings.py" restore \
  --directory "$ai_trial_directory/preferences-original"
python3 "$fixture_tools/ai_fixture_key.py" remove \
  --state-file "$ai_trial_directory/key-state.json"
systemctl --user stop azookey-ux-ai-mock
python3 "$fixture_tools/ai_fixture_preferences.py" verify \
  --directory "$ai_trial_directory/preferences-original"
```

`ai_fixture_key.py` が削除するのは、その UUID・label・object path に一致する task 作成項目だけです。session collection がログアウトで消えていれば、項目なしを記録して終えます。他の項目を削除しません。元の設定へ戻った engine で通常入力を確認し、JSON の再照合結果も保存します。

`restore` は新しい配布物 engine を起動し、文書を持たない専用 IBus context で英数 `A`、かな `あ` の二つの応答を順に待ちます。初回の設定読取 callback が後から追加する `configure` も、二つ目の応答より先に完了します。起動時に更新される `settings.last-good.json` は、その完了後に元の bytes・不在へ戻します。`settings.json` は再書込せず、余分な設定再読込を起こしません。もう一度入力順序の通過、Core の有効値、三つのファイルを照合してから `startupAcknowledged: true` と `matches: true` を返します。

失敗時は `preferences-original/restoration.jsonl` の最後の段階を確認し、保全先を残してください。`files-restored-engine-stopped` は復旧完了ではありません。応答期限切れや再起動失敗を合格にせず、原因を解消して同じ保全先から復旧を再実行します。成功後の新しい入力 context 作成や設定変更により、製品が通常どおり最終正常設定を書き直すことは別の操作です。復旧確認とその後の操作を同じ時刻の証拠として扱いません。

共有する証拠は、配布物と fixture の識別、合成要求の JSONL、キーボード操作、アプリ内の挿入イベント、本文・焦点の観測、必要な画面、復元時の hash 照合です。既存設定 JSON やキーリングの内容は共有しません。未実施・観測できなかった条件はそのまま残し、[UX 検証台帳](ux-validation.md)の担当者へ渡します。

用語: **mock** はこのローカル模擬サーバー、**context** は IBus の入力欄を表す識別子、**Reset** はその入力状態をリセットする IBus 操作です。AT-SPI の入力欄 identity は context と別に照合されます。
