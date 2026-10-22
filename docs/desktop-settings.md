# デスクトップ版の設定（Core の定義とブリッジの操作）

設定の項目・検証・保存・復旧は Swift の Core（`Core/Sources/Core/Desktop/Settings/`）が決める。各 OS の設定画面は、Core が返す定義を見て画面を組み立て、文言はキー名で自分の文言カタログから引く。OS 側に残すのは画面部品、API キーの保存（Linux はキーリング、Windows は資格情報）、診断ページだけである。

## 設定ファイルの置き場所

| OS | 場所 |
|---|---|
| Linux | `$XDG_CONFIG_HOME/azookey-tree/settings.json`（未設定なら `~/.config`） |
| Windows | `%APPDATA%\azooKey Tree\settings.json` |
| macOS | アプリは App Group の設定を使う。ブリッジは Linux と同じ XDG の場所 |

同じフォルダーに、正常に適用できた値の控え `settings.last-good.json` と、書き込みの排他用の `.settings.lock` を置く。復旧すると、元のファイルは `settings.recovered-<日時>-<8桁>.json` という名前で残る。

## ブリッジの操作

要求も応答も 1 行 1 JSON。値は応答の `settings` に、それ以外は `settingsResult` に入る。失敗したときは `settingsResult.error` が `{"code", "message", "arguments"}` になる。`message` は文言キーで、`arguments` の値はすべて文字列。

| 操作 | 要求 | 結果 |
|---|---|---|
| 定義 | `{"operation":"settings-schema"}` | `settingsResult.schema`（下記） |
| 読み込み | `{"operation":"settings-load"}` | `settings` と `settingsResult.file`（`path`・`stamp`・`exists`・壊れていれば `problem`） |
| 保存 | `{"operation":"settings-save","settings":{...},"settingsFile":{"expectedStamp":"..."}}` | 保存後の `settings`、新しい `file.stamp`、`saved.lastGoodSaved` |
| 復旧 | `{"operation":"settings-recover","settingsFile":{"expectedStamp":"...","useDefaults":true}}` | 保存と同じ。`saved.recoveredPath` に元ファイルの退避先 |
| 一部の更新 | `{"operation":"settings-update","settings":{"includeContext":true}}` | 保存と同じ。変換器へは反映しない |
| 再読み込み | `{"operation":"settings-reload"}` | 読み込みと同じ。変わった版だけを変換器へ反映する |
| 辞書の保存 | `{"operation":"dictionary-save","items":[...],"settingsFile":{"expectedStamp":"..."}}` | `dictionarySaved` と、保存と同じ `settings`・`settingsResult` |

- `settings` は一部の項目だけでもよい。書かれていない項目は、変換器が今使っている値になる。
- `expectedStamp` は画面を開いたときの `stamp` を渡す。そのあとで別の画面が保存していたら `changed` を返し、上書きしない。ファイルが無い状態で開いたときの値は `"absent"`。省くと、この確認をしない。
- 保存では、検証・競合の確認・変換器への適用・ファイルの置き換え・控えの書き込みを 1 回の要求で行う。ファイルを置き換えられなかったときは、変換器を元の値に戻す。戻すのにも失敗したときは `backendRecoveryFailed` を返し、次の保存の最初に元の値へ戻す。
- 壊れたファイルは、`settingsFile.recover` を付けた保存か `settings-recover` でしか置き換えない。
- 復旧は控えの値を使う。ただし、辞書・カスタム入力表・学習・個人化・プロフィール・AI 設定は今の値を保つ。`useDefaults` を付けると、入力と表示の項目も既定に戻す。
- `settings`（変換器が今使っている値）と `configure`（ファイルを通さずに適用する）は、これまでどおり使える。

### 問題の種類

| code | 文言キー | 意味 |
|---|---|---|
| invalidValue | settings.invalid_value（field） | 型や値の誤り。field は `userDictionary.items[0].id` のような位置 |
| unknownKey | settings.unknown_key（field） | 知らない項目 |
| invalidJSON | settings.invalid_json（line, column） | JSON の構文の誤り。行と列は文字単位 |
| invalidStructure | settings.invalid_structure | 入れ子が深すぎる |
| readFailed | settings.read_failed | 読めない、または UTF-8 でない |
| engineRejected | settings.engine_rejected | 変換器が適用できなかった |
| changed | settings.changed | 開いた後に別の画面が保存した |
| recoveryRequired | settings.recovery_required | 壊れたファイルを通常の保存で上書きしようとした |
| busy | settings.busy | 別の画面が保存中。待たずに断る |
| writeFailed | settings.write_failed | ファイルを書けなかった |
| backendRecoveryFailed | settings.backend_recovery_failed | 置き換えにも、変換器を元に戻すのにも失敗した |

## 定義（settings-schema）

`items` は設定ファイルの項目ごとの定義、`pages` はタブの並びである。

```json
{"key":"punctuation","control":"choice","labelKey":"settings.punctuation",
 "choices":[{"value":1,"labelKey":"settings.punctuation.kutenAndToten"}],
 "default":1,"resetsToInputDefault":true,"keptOnRecovery":false,"available":true}
```

- `control` は次のどれかで、画面はこれを見て部品を選ぶ。
  - `toggle`
  - `choice`
  - `integer`（`minimum`・`maximum` が付く）
  - `text`（`maximumCharacters` が付くことがある）
  - `multilineText`
  - `shortcut`
  - `dictionary`（専用の画面で編集して保存する）
- `descriptionKey` は項目の下に出す説明、`accessKey` はキーボードのアクセスキーである。
- その OS で使えない項目は `"available":false` になり、`unavailableReasonKey` に理由の文言キーが入る。Windows では、MARISA 形式のモデルを読めないため次の 4 つが使えない。
  - 入力訂正（typoCorrection）
  - 個人化モデル（personalization）
  - ボタン downloadTypoWeights
  - ボタン importPersonalization
- `pages[].elements` の要素は次の 5 種類である。
  - `{"kind":"setting","key":...}`
  - `{"kind":"note","textKey":...}`
  - `{"kind":"action","action":{"id","labelKey","available","unavailableReasonKey"}}`
  - `{"kind":"secret","secret":{"id":"apiKey","labelKey","placeholderKey","descriptionKey","accessKey"}}`
  - `{"kind":"support"}`
- action の id は `downloadTypoWeights`・`resetLearning`・`importPersonalization` の 3 つ。secret の API キーは OS の資格情報に保存し、設定ファイルには入れない。

## 試験

- Core: `swift test --package-path Core --filter DesktopSettings`
- 実ブリッジ: `DesktopSettingsBridgeTests`・`DesktopDictionaryBridgeTests`（Linux）
- Linux の画面と IBus: `test_settings_window.py`・`test_settings_accessibility.py`・`test_settings_reload.py`・`test_settings_schema_messages.py`・`ibus_settings_integration.py`
