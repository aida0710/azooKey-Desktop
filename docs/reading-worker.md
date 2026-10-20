# 候補処理から独立した読みプロセス

`AZOOKEY_BRIDGE_ROLE=reading` は開発検証用の明示的な入口です。通常の IBus frontend はこの値を設定せず、既存の bridge を使用します。ライブ変換や候補選択を備えた経路の置き換えは、まだ行っていません。

この入口は `BridgeMain` が converter、学習ディレクトリ、辞書を初期化する前に分岐します。別プロセスの `DesktopReadingWorker` が context ごとに `DesktopReadingSession` を持ち、Core の `UserAction`、`InputState`、`CompositionState` で入力を解釈します。ローマ字変換を Python へ複製しません。

現在の protocol は `key`、`reset`、`snapshot`、`close` です。読みは標準ローマ字・ライブ変換 OFF を前提にしています。文字入力、前後削除、読み内カーソル移動、Escape、読みの Enter / keypad Enter 確定を、候補の返信なしで完了できます。カーソルは既存の IBus protocol と同じ Unicode scalar 単位です。

未接続の候補選択・予測・F6〜F10等は `unsupported_reading_action`、再変換 shortcut は `reconversion_requires_coordinator` を返します。操作が途中で失敗しても、正式な読み、カーソル、状態、世代を変更しません。未知の operation は `invalid_request` です。呼出側はこれらを成功した入力返信として適用してはいけません。

設定同期、明示 snapshot の送受信、候補の不透明な ID と消費範囲、context / focus / 設定世代の採用確認、選択・部分確定・学習通知の接続は次の変更です。ライブ変換 ON の表示動作も、この入口に接続していません。候補プロセスから届いた返信だけで未確定文字を書き換える設計にはしません。

回帰では実際の候補 bridge を起動して `SIGSTOP` の完了を確認し、その間に別の読み bridge で入力・途中編集・Enter・次の入力・Escapeを実行します。候補側の停止状態を再確認してから復帰し、両方の子プロセスを終了します。読み側のデータ先をディレクトリを作れない通常ファイルにして、学習ディレクトリを必要としないことも確認します。

この試験はプロセス分離と読みの保持を確かめるものです。実アプリの key-to-paint 時間や、候補との統合後の IBus / GTK / Qt / Wayland 動作の合格には代えません。
