# 読みと候補の設定同期

`ReadingCoordinator(..., settings=values)` は19項目の完全なworker設定を受け取り、revision 0の `configure-settings` を最初の読み操作として登録する。保存・既定値の補完・辞書のコンパイルは行わない。起動直後の `open_context`・`focus_in`・キーは設定操作の後ろに並び、読みprocessの正式ACKを受けてから進む。

候補processの起動や設定ACKは、この読みの順序を待たせない。設定全文・revision・custom tableの登録名/hashが読み側と一致し、現在のworker generation/transport epochの返信であることを確認するまで、候補のprepareを行わない。候補到着は入力文字や元キー返信を変更しない。

設定変更はfocusが無く、読み操作と前の設定操作が完了している場合に `configure_settings(values, revision, callback)` で行う。callbackは**読み側の適用結果**を返す。候補側の適用完了を示すcallbackではない。新しいfocusとキーはその読みACKの後へ登録できる。設定値を変えるときはrevisionを進める。全量契約開始後はlearningだけの変更を拒否する。

読み側の適用結果が不明なら、後続入力を適用せず元返信を一度だけ完了し、明示的な再起動を必要とする。候補側の適用失敗・不一致では、読みを継続し候補を停止する。`retry_candidate_settings()` または次の明示的な設定変更で確認を再開できる。通常の候補worker再生成時には確認済みの設定を再適用するが、入力や学習通知を再送しない。

現契約の未対応設定（live、predictiveTyping、aiEnabled、debug）は有効値を拒否する。保存値を黙って無効化しない。辞書本文・AI接続先・API keyはworker設定へ含めない。

開発用IBus入口（`--reading-worker-development`）では `settings_provider` を使う。readerのhelloにある `defaultSettings` を、保存済み `settings.json` に不足する値の補完に使い、19項目だけをconfigureへ渡す。適用済み `settings` と起動時の既定値は別であり、既定値が欠落・不正なら推測せず入力開始を止める。providerと明示的な `settings` は同時指定できない。

providerの終了前には読みprocessの操作を開始しない。provider内の通知からfocusやキーが再入した場合も、configureの後ろで待つ。例外や終了時には元入力の返信を一度だけ完了する。候補側の起動待ちは従来どおり入力を待たせない。

保存JSONが破損している場合は元ファイルを残し、検証できたCoreの既定値を使って通知する。保存やlast-goodの書き換えはしない。未対応設定が有効なら専用の案内を出して止める。通常の設定画面で項目を変更した後、別の入力欄への移動や明示的な取消による再起動で再読込する。正常な入力中の自動再読込には未対応。

このAPIは開発中の読み/候補分離用であり、通常のIBus入口には未接続。live ON、Tree/pointer、AI、再変換と実GUIの全受入は引き続き必要。
