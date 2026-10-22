# 読みプロセスでの再変換と確定取消

これは開発用の読み・候補プロセスを結ぶCore契約です。通常入口と `unsupportedFeatures` の再変換gateは変更しません。削除の実行、元入力欄の識別、実際の削除完了の確認はOS adapterが担当します。

読みプロセスは既存 `ReconversionSession` で直近の全体確定と一度限りの削除tokenを保持します。候補プロセスは辞書による読み解決を担当します。読みプロセスへ辞書本文を渡したり、読み解決のために候補を生成・学習したりしません。

## 要求と応答

読み側の操作はすべてactiveな `reference` が必要です。`reconversionContext` は既存の7項目、`before`、`selected`、`after`、`cursorUTF16`、`anchorUTF16`、`canReplace`、`isSensitive` です。位置はUTF-16、削除計画の `offset` と `count` はUnicode scalar単位です。本文・選択・前後の文脈は正規化せず照合します。

| operation | payload | 応答 |
| --- | --- | --- |
| `key` / `commit-candidate` | 既存項目と任意のreconversionContext | 通常の入力応答。文脈が確認できる単一の全体確定だけundo履歴を記録 |
| `undo-commit` | reconversionContext | acknowledgementと削除計画 |
| `reconvert` | reconversionContext、任意のreading | reading指定時は削除計画。未指定ならcandidateWorkerGenerationも必須で読み解決要求を返す |
| `resolve-reconversion` | reconversionContext、reconversionReadingResult | 元要求と文脈を再照合し、削除計画または読み入力を返す |
| `reconversion-reading` | reconversionContext、event | ローカル読み入力。Enterで計画、Escapeで取消 |
| `confirm-reconversion` | reconversionContext、reconversionToken | input。実削除ACK後の文脈とtokenが一致した場合だけ読みを復元 |
| `cancel-reconversion` | 追加項目なし | 未confirmの計画・読み要求・読み入力を取り消す |

計画・読み解決・読み入力の応答はsnapshotを持ちません。該当する応答にだけ次の項目を付けます。

- `reconversion`: `{token, offset, count, text, reading}`。既存の削除計画です。
- `reconversionError`: `reading_required`、`changed_context`、`private_input` などの既存コードです。
- `reconversionReading`: 読み入力の現在値。空文字も入力中を表し、項目の不在は入力終了を表します。
- `reconversionReadingRequest`: 候補プロセスへ渡す、元要求に結び付いた読み解決要求です。

confirm成功時のsnapshotは読み、カーソル、新しいcompositionRevision、`request: "candidates"` を持ちます。確定・学習通知・候補の自動選択は行いません。confirm失敗時はtop-levelの `reconversionError` と変更前のsnapshotを返します。adapterはエラーを確認してから入力を公開し、失敗を読み復元の成功として扱いません。

## 辞書による読み解決

候補側の `resolve-reconversion-reading` は `reconversionReadingRequest` のみを受け取ります。

```json
{
  "operation": "resolve-reconversion-reading",
  "reconversionReadingRequest": {
    "authority": {
      "context": "field", "readingProcessGeneration": "reader",
      "focusEpoch": 1, "compositionRevision": 2, "settingsRevision": 3,
      "requestID": "request"
    },
    "workerGeneration": "candidate-worker",
    "text": "選択本文",
    "privateInput": false
  }
}
```

応答の `reconversionReadingResult` は `{request: 元の要求object, reading: 解決した読み}` です。読みが不明なら `reading` を省略します。候補側はworker世代・設定revision・private状態を確認し、既存 `ReconversionReading.resolve` とユーザー/システム辞書を使います。辞書の表記もUTF-8の一致を必要とします。辞書や設定の保存、候補sessionの作成、候補計算、学習は行いません。

読み側は要求全体、元の本文・選択・位置を再照合します。別worker、古い設定、古いfocus、別requestID、正規化すると同じでも元bytesが異なる本文から削除計画を作りません。通常入力・reset・focus-out・設定変更・対象worker停止・新しい再変換要求は古い読み解決要求を退役させます。読み不明時は既存 `ReconversionReadingInput` によるローカル入力へ進み、外部AIへ送りません。

## 削除、復元、確定の所有者

adapterは削除直前に元欄・本文・選択・位置を再確認します。削除を送った後は、同期clientが削除を実行できる位置で元キーへ返信し、実際の削除ACK後だけconfirmを送ります。CoreはOSの削除を観測できないため、tokenと削除後文脈の照合だけを行います。タイマー経過を削除ACKの代用にしてはいけません。

削除ACKとconfirm応答の間に焦点が移る場合に備え、adapterは元欄だけに結び付いた原文の復旧用表示を保持できます。対象は計画の `text` そのものに限定し、正式な読み・選択・学習状態とは分けます。旧欄で原文を復旧した後は、遅いconfirm応答やEscによる原文復帰を別欄へ送ったり二重適用したりしません。`reset` / `focus-out` の `submit:false` による制御応答は原文を確定しません。

開発用のreading adapterでは、削除送信後の `deleting` / `confirming` 中、開始キーの返信が完了し、先行する元キーの返信が残っていない場合だけ、キー解放を通常のIBus `False` 返信へ通します。解放は既存の `keymap.translate` でも正式入力を編集しない通知です。GTK同期clientが解放の返信を待つことで `PostProcessKeyEvent` と原文の復旧表示を受け取れなくなる循環を避けます。開始キー・先行する押下・Enterなどが未完了なら従来の順序を保ちます。通常入力、ローカル読み入力、通常Engineの経路は変更しません。

復元するraw入力は直近確定のcheckpointを使います。元候補の本文は新batchのUTF-8一致かつ全読み消費の実候補から探し、旧candidateIDやlearning receiptを再利用しません。候補到着だけでは正式snapshotを変えず、次の明示変換キーで復元候補を選びます。

再変換中の部分候補確定・部分F6〜F10は `whole_selection_required` で拒否し、元の読みと選択を保持します。新しい全体候補を確定した場合だけ、その実IDのcompletionを一度返します。候補を確定せずEscで未確定入力を取り消した場合は、元の本文を一度返します。Escは既存の候補選択・プレビュー・読みの取消段階を保ち、読みの取消時に元本文を戻します。

`reset` / `focus-out` の `submit:false` は、再変換中もcommitとcompletionを返しません。元欄の確定・消去・原文の復旧表示はIBusと入力先クライアント、元欄/tokenを保持するadapterが担当します。制御応答から原文を再確定すると、二重確定や別欄への配送になるためです。読み側は入力・候補・元本文・削除tokenを退役させ、後のEscや古い候補IDから原文を再送しません。未confirmの `cancel-reconversion` もcommitを伴いません。

入力応答が不明な場合、焦点変更後、削除済み本文の復旧はadapter側の検証対象です。Core回帰の成功を実IBus/GTK/Qtの削除・表示・焦点受入へ読み替えません。
