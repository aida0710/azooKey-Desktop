# 入力保護属性の実アプリ検証

既存の2欄fixtureとは別の画面で、通常欄からパスワード欄や読み取り専用欄へ移った後に、未完了のAI変換や再変換が本文を変更しないことを確認する。合成テキストだけを使う。パスワード欄の中身も、この試験画面の観測ファイルには記録される。

## 起動

専用VMに以下のファイルを同じディレクトリへ置く。既存fixtureの配置・内容は変えない。

- `Tools/tests/fixture_events.py`
- `Tools/tests/protected_fixture_state.py`
- 使用する `Tools/tests/gtk-protected-editor.py` または `qt-protected-editor.py`

```sh
python3 gtk-protected-editor.py --output gtk-state.json --events gtk-events.jsonl
python3 qt-protected-editor.py --output qt-state.json --events qt-events.jsonl
```

GTK版はGTK4のPythonバインディング、Qt版はPyQt6 Widgetsを使う。QtWebEngineは不要。GTK3と異なり、GTK4には公開された `Gtk.InputHints.PRIVATE` がある。既存GTK3のAI適用試験と同じ条件とは扱わない。[GTK4の入力ヒント](https://docs.gtk.org/gtk4/flags.InputHints.html)

Chromium版は `Tools/tests/protected-editor.html` と `protected-editor-observer.js` を同じ場所へ置き、ローカルファイルとして開く。外部ページや送信先を持たない。観測は読み取り用の `window.imeFixture.snapshot()` / `observations()` で取得する。

ブラウザの履歴は直近2000件に制限する。各イベントの `sequence` と `observationStatus()` の `droppedCount` / 最初・最後の番号を一緒に保存する。`droppedCount` が0でない試行は完全な履歴として扱わず、新しいページから取り直す。snapshotにも同じ履歴情報を含める。残った履歴に挿入がないだけで、試行全体の挿入0とは判定しない。

## 欄の意味と確認する値

| 欄 | GTK4 | Qt | Chromium |
|---|---|---|---|
| 通常 | FREE_FORM、編集可 | 標準のQLineEdit | `type=text` |
| パスワード | PASSWORD、非表示 | Password echo mode | `type=password` |
| 数字パスワード | PIN、非表示 | Password + ImhDigitsOnly | password + inputmode=numeric |
| private | PRIVATE hint | ImhSensitiveData | 対応する欄なし |
| 読み取り専用 | editable=false | readOnly=true | readonly |

用途やヒントは入力制限の実装ではない。アプリが公開した属性をJSONへ記録し、IBusの実 `SetContentType`、フォーカス、候補画面、送信要求も別に観測する。Qt/Chromiumの数字欄を、GTKのPINと同じ通知が届いた証拠には使わない。`autocomplete=off` はPRIVATEの代用ではない。[GTKの用途](https://docs.gtk.org/gtk3/enum.InputPurpose.html)、[Qtの入力ヒント](https://doc.qt.io/qt-6/qt.html#InputMethodHint-enum)

各欄の名前は重複しない。Tab / Shift+Tabで実フォーカスを移し、観測の `focused` とアクセシビリティ名を照合する。読み取り専用欄は固定の合成文を初期表示し、選択できるが入力で変更されない。位置はGTKがUnicode scalar、Qt/ChromiumがUTF-16単位で記録する。

## 動作確認

1. 通常欄に実キーで合成文を入力し、その選択範囲のAI要求をloopback模擬サーバーへ送る。同じ欄へ正常適用できる陽性を先に確認する。
2. 別試行で結果待ちの間にTabで各保護欄へ移る。実フォーカスと実属性を確認してから結果を解放する。本文・未確定文字・挿入イベント・要求数を記録する。
3. 保護欄そのものでも、合成文の入力や選択、AI/再変換/確定取消のショートカットを試す。通常欄・別欄・読み取り専用の原文が変わらないか確認する。
4. 通常欄へ戻り、入力と変換が回復することを確認する。画面を開けない、要求が届かない等の条件は、誤挿入の拒否成功と区別する。

GTKのbuffer挿入/削除、Qtの実inputMethodEventと適用後の状態、Chromiumのbeforeinput/input/compositionを保存する。ウィジェット単体試験で属性や読み取り専用を確認しても、実IME・Orca・配布物検証の合格にはしない。原設定と模擬キーの復元は既存のAI試験手順に従う。
