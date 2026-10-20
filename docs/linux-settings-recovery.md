# Linux設定ファイルの復旧

`settings.json`が不正なJSON、型の違う値、未知の項目や列挙値を含む場合、または読み取れない場合も、IBusは現在の正常な設定で入力を続ける。同じファイル状態について案内を繰り返さず、修正を読み込むまで補足表示を保持する。ファイルの変更後は次の入力で再検証し、再起動せず反映する。

設定画面は変換器が保持する正常値で開き、原因と対象パスを表示する。「正常な設定で復旧」と「入力・表示を既定に戻して復旧」を選べる。復旧前に元のファイルを`settings.recovered-日時-識別子.json`へ移し、書き込みに失敗したら元の場所へ戻す。通常の「保存」とAI確認画面からの部分更新は、破損した原本を上書きしない。

復旧確認はGTKのresponse signalで受け取り、同期AT操作の中で別のmain loopを開始しない。同時に開く確認は1つで、連打や別の復旧ボタンでは最初の選択を維持する。Escape・取消・確認の破棄・親画面の終了は保存を行わず、承認された現在の確認だけが一度復旧を実行する。保存に失敗した場合は、原本と復旧操作を残して再度確認できる。

「入力・表示を既定に戻す」の対象は候補表示、入力配列、句読点、スペース、推論回数などに限る。ユーザー辞書、カスタム入力表、学習方法、個人化の設定、プロファイル、AIの接続先と送信範囲は維持する。学習データと個人化モデルのファイルを削除する操作や、キーリングへの書き込みは行わない。

## 保存の共通処理

`settings_schema.py`が型と値を検証し、`settings_store.py`が読み込みと原子的保存を扱う。文字列のprofile上限はCoreと同じ書記素単位で数える。設定ファイルを変更していない間は解析結果を再利用する。Core側でカスタム入力表などの適用に失敗した場合も、同じ内容をキーごとに再送しない。

正常に適用できた値は、同じフォルダーの`settings.last-good.json`へ権限0600で控える。IBus側では変換処理と同じワーカーで保存し、メインループを止めない。控えの保存失敗で入力や設定本体の保存を失敗扱いにはしない。復旧の際は、控えが古くても現在の辞書やAI・学習の選択で上書きし、それらを巻き戻さない。

`SettingsStore.save(values, expected_stamp=...)`は画面を開いた後のファイル変更を検出する。`update_settings(changes, defaults=...)`は最新のファイルへ変更項目だけを重ねるので、AIの周辺文送信の切り替えで別画面が更新した辞書を上書きしない。戻り値は`SettingsSave`で、保存後の値を`values`、原本の保全先を`backup_path`で返す。

`save_with_backend(values, apply_staged=..., expected_stamp=..., recover=False)`は、書き手のロック内で設定の検証と競合検出を済ませてから、権限0600の一時JSONをバックエンドへ渡す。バックエンドはCoreへの適用と最終JSONの原子的な置換を担当する。Storeは保存し直さず、成功した値の控えだけを作る。明示的な復旧では`recover=True`として原本を保全し、バックエンドが失敗して新しいファイルがない場合は元のinodeと更新時刻を維持して戻す。

JSONの深すぎる入れ子も破損として扱い、同じファイルを繰り返し読んでも正常値で継続する。設定の型を検証する前に再帰コピーを行わず、キャッシュとファイル識別情報は結果が揃ってから更新する。JSONの公開失敗に続いてCoreの復元も失敗した場合は、その旨を表示する。画面を開いたまま保存を再試行すると、元の値への復元を確認してから新しい設定を適用する。

## 検証

2026-10-20、Ubuntu 24.04 amd64の専用VMと実Swift bridgeで確認した。

- 基点`526f0ae`の設定画面は、合成ファイル`{`で起動時に`JSONDecodeError`となることを再現した。
- 保存処理の23件で、破損・型や値の不一致・未知項目・重複キー・深い入れ子・競合・原本保全・保存失敗時の原本復帰・古い画面からの差分保存・バックエンドへの一度だけの保存を検査した。
- ワーカーの追加2件で、控えの保存が遅れてもメインループの処理と要求の順序が保たれ、控えの失敗では変換器を再起動しないことを検査した。
- GTKの6件で、不正JSON、型、未知値、未知項目、実際に権限000にしたファイルでも復旧操作が表示されることを検査した。復旧取消、既定値適用、辞書とAI送信設定の保持、キーリングへの書き込みがないこと、保存失敗、他画面との競合も含む。追加の故障注入では、実Coreへ新設定を適用した後にJSON公開と復元応答を失敗させ、原本不変・警告・復元からの再試行を確認した。待機中に修復した後の古いconfigure失敗は、応答を模擬して不要な通知と例外がないことを確認した。
- 実IBusの同じ入力欄で上記5種類の異常を順に発生させ、各状態の案内が1回、キーのアプリ側への誤転送が0回、元ファイルが不変であることを検査した。修復後にスペース設定の変更と日本語変換が再起動なしで反映された。

```sh
python3 -m unittest discover -s Linux/tests -p test_settings_store.py -v
AZOOKEY_BRIDGE=/path/to/bridge xvfb-run -a python3 Linux/tests/test_settings_window.py -v
AZOOKEY_BRIDGE=/path/to/bridge AZOOKEY_IBUS_TEST=Linux/tests/ibus_settings_integration.py \
  dbus-run-session -- xvfb-run -a bash Tools/tests/linux-desktop.sh
```

権限000の実ファイル試験は一般ユーザーのVMで実行する。rootのコンテナでは読み取り禁止を再現できないため、その1条件は省く。GTK画面とIBus経路を検証した範囲であり、Orcaによる読み上げ、arm64、配布パッケージの各デスクトップ環境での確認は別に行う。

復旧確認の回帰は`test_settings_window.py`で実dialogと実Swift bridgeを使う。`Tools/tests/linux-dictionary-dialogs.sh`は独立Xvfb/session/AT busで、実ATによる正常設定/既定値の復旧開始、実Escape取消、その後の明示承認と原本・辞書・学習設定の保持を検査する。AT listenerが実Controlキーを受け取ったことを先に確認し、応答や成功をfixtureから注入しない。既存の辞書chooser2条件も同じ共有AT harnessで維持する。これは人によるOrca音声評価や配布パッケージの再受入を代替しない。

GTK公式の[`Dialog.run`](https://docs.gtk.org/gtk3/method.Dialog.run.html)は再帰main loopで待機し、[`response`](https://docs.gtk.org/gtk3/signal.Dialog.response.html)はボタン操作やdelete eventを通知する。この公開API境界を使ってAT dispatchへの再入を避ける。
