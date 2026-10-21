# 読み分離エンジンの再変換試験

`Tools/tests/linux-reading-reconversion-native.sh` は実 Core と専用 IBus daemon を使い、再変換の削除確認、元キーへの返信、確定取消を検査します。入力先は合成クライアントです。実 GTK / Qt の画面や Orca の受入試験とは区別します。

通常の Linux 回帰試験 `Tools/test-linux.sh` からも実行します。

既存の Ubuntu 試験環境でビルドした bridge と resource bundle を指定して実行します。ホストへのパッケージ追加は不要です。

```sh
AZOOKEY_BRIDGE=/path/to/azookey-desktop-bridge \
AZOOKEY_RECONVERSION_ARTIFACTS=/path/to/new-evidence-directory \
bash Tools/tests/linux-reading-reconversion-native.sh
```

条件名を引数に渡すと対象を絞れます。証拠ディレクトリには、同名の試行があると上書きせず終了します。各条件は独立した D-Bus、IBus、Xvfb、XDG ディレクトリで実行します。

| 条件 | 検査する振る舞い |
|---|---|
| `known` | 候補 worker を停止しても Engine の照会に応答し、削除確認前には正式な入力や再変換の確定処理へ進みません。 |
| `focus` / `private` / `changed` | 読みの取得中に欄、入力保護属性、本文が変わると、遅い結果を破棄して元キーへ一度だけ返信します。 |
| `private-start` | 保護された欄から辞書へ再変換を要求しません。 |
| `undo` | 確定取消は停止中の候補 worker を待たず、削除確認後に読みを戻します。 |
| `unknown` | 読みが不明な場合の入力は局所的に扱い、Escape で元文書を保ちます。 |
| `confirm-focus` | 削除確認後の欄変更では旧欄に原文を一度だけ戻し、次の欄へ混入させません。 |
| `confirm-reset` | 同じ reader を停止・再開して遅い確認結果を受けても、Reset が原文を重複確定しません。 |
| `qt-confirm-reset` | Qt 6.4 相当のローカル確定と Reset の通信順序で、daemon からの追加確定がありません。 |

`known` の照会は Engine の `RendererStatus` を直接呼びます。daemon が保持する情報の取得とは異なりますが、停止期間を二秒に固定した負荷試験や画面の応答時間測定ではありません。

各条件は `result.json`、入力先の履歴、worker の実行物 SHA256 と通信記録、生の IBus 通信を保存します。`bus-audit.json` は InputContext と Engine の両層で、元の呼出に Boolean の返信が一度だけあり、`ForwardKeyEvent` がないことを照合します。削除を伴う条件では、開始呼出、削除信号、開始返信、削除確認の順序も検査します。記録する文書はこの試験で作る合成文だけです。

Qt 6.8 は別の確定契約を使います。`qt-confirm-reset` の成功は Qt 全版の対応を意味しません。実画面の欄移動、別ウィンドウへの移動、読み上げ、通常入口の検査は別途必要です。
