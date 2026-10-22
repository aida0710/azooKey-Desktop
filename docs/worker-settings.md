# 読み・候補workerの全量設定

開発用の読み・候補JSONLに、同じ明示設定を適用する `configure-settings` を追加しています。通常IBus入口や設定画面の保存方法は変更しません。通常入口への設定同期、入力中の設定変更、実GUIの受入は別の統合段階です。

| role | configure-settingsの必須欄 | 設定の取得 |
| --- | --- | --- |
| reading | operation、readingProcessGeneration、settingsRevision、settings | hello / settings |
| candidate | operation、workerGeneration、settingsRevision、settings | settings |

`settings` は次の19項目をすべて含みます。型・値は `DesktopSettings` と同じです。欠落や未知欄は拒否し、保存値から補完しません。

- tree、candidateTextSize、showRelativeScores、live
- halfSpace、backslash、optionDirect、inputStyle
- learning、punctuation、profile、personalization、inferenceLimit
- predictiveTyping、typoCorrection、debug、aiEnabled、transformShortcut、customTable

辞書本文・AI endpoint/model・周辺本文はこのpayloadに含めません。`transformShortcut` はkey/modifiersのみを持ちます。live、predictiveTyping、aiEnabled、debugがtrueの要求は `unsupported_worker_settings` で拒否します。再変換キーも既存の明示拒否を維持します。未対応機能をOFFへ書き換えて成功扱いにはしません。

## ACKとrevision

設定取得とconfigure成功ACKは、既存の世代・settingsRevisionに次の欄を加えます。

```json
{
  "settingsContract": "full",
  "settings": { "…": "19項目の実適用値" },
  "customInputTableRevisions": {},
  "unsupportedFeatures": ["live", "predictiveTyping", "ai", "reconversion", "debug"]
}
```

初回設定前はsettingsを省略します。readerはhelloでkind=process、それ以外の設定ACKでkind=acknowledgementです。candidateは既存のlearning欄も返します。入力・候補応答やエラーへこの設定本文を重複して追加しません。

readerのhello/settingsには、起動時に一度だけ読んだ19項目を `defaultSettings` として追加します。適用済みの `settings` とは別で、取得だけでは設定を適用しません。Configの既存getterと保存済みcustom tableだけを読み、辞書本文やAI接続先を取得しません。Configの型不一致は既存getterと同じ既定値に戻ります。liveなど未対応の有効値もそのまま返し、configure時には上記の明示拒否を維持します。

保存表の読込み失敗・UTF8/形式/2MiB上限違反や、取得した設定の値域/サイズ不正ではdefaultSettingsを省略し、`defaultSettingsError: "invalid_worker_defaults"` を返します。両欄を同時には返しません。世代・契約のhelloは成立しますが、呼出側はbootstrapを中止して不正を知らせます。適用済みsettingsとdefaultsを合わせた応答が4MiBを超える場合もdefaultsだけを省略して同じエラーを返し、適用値を保持します。configure ACK、入力、制御、エラーにはこの2欄を追加しません。起動後の保存設定変更は再取得せず、新しいreaderでcaptureし直す契約です。

初回はrevision 0から適用できます。同revision・同payloadの再送は副作用なしで再ACKします。比較はJSONのkey順を固定したUTF8 bytesで行い、Unicodeの正規化による異なる本文を同一扱いしません。同revisionの異なる値、古いrevisionは `stale_worker_settings`、不正値は `invalid_worker_settings` です。

変更を受け付けるのは、readerが非focusで全contextに未確定入力がなく、candidateは全contextをclose済みの場合です。条件が満たされなければ `worker_settings_busy` で前の適用値を保持します。両process間のatomic commitは提供しません。一方だけ成功した場合、coordinatorは一致するACKを得るまで候補prepare/adoptを止めます。ACK不明を成功と推定したり、古い候補・選択・学習receiptを新revisionへ持ち越したりしません。

全量契約を開始したroleでは、learning-revision / configure-learningを `full_settings_required` で拒否します。以降は学習だけの変更も同じ全量設定契約を使います。

## 設定と入力表の保存先

適用値はMainActorの同期処理中だけConfigへTaskLocal scopeで渡し、終了・例外・入れ子からの復帰で前の値に戻ります。通常Configの保存値を書き換えず、別workerや独立taskの設定を上書きしません。

customTableは公開InputStyleManagerの検証・parserを使い、process内の登録名を `azooKeyMac.customRomajiTable.` + 受信UTF8 bytesのSHA256とします。両workerは同じ登録名/hashをACKし、CompositionSnapshotにも実際に使った表のhashを記録します。既存の表へ別内容を上書きしません。公開parserがURLのみを受け付けるため解析用の一時ファイルだけ作り、終了時に削除します。設定JSON、UserDefaults、保存済みcustom_input_table.tsvへの書込みはありません。

全量設定のJSONは2MiB以下、process内の異なるカスタム表登録は既存transportと同じ64種類までです。公開registryに削除APIがないため上限を設けています。上限到達は明示拒否し、再生成したworkerへ確認済み設定を同期します。

辞書の保存・移行・exportは既存の辞書transactionを維持します。辞書を持つconverterは候補側だけです。[辞書同期](reading-dictionary-sync.md)を使う場合はconfigure-settingsの追加欄dictionaryRevisionを両roleで照合し、保存済みの同じ版を適用します。19項目のsettings本体は変えず、readerへ辞書本文を送りません。

初回の辞書版だけは、同一の全量設定・revisionを維持した専用 `bind-initial-dictionary` で結び付けられます。入力・候補の条件とACKは[初回binding](reading-dictionary-sync.md#起動時の初回binding)を参照してください。2回目以降の辞書変更や一般設定変更に、この例外は適用しません。
