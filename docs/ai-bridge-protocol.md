# AI 機能のブリッジ操作

AI 機能で何を送るか、送ってよいか、結果を本文へ適用してよいかは Core（`Core/Sources/Core/Desktop/AI`）が決めます。各 OS は入力欄について分かる事実を渡し、Core の答えを表示し、AI への通信と画面・API キーの保管を受け持ちます。この文書は、その受け渡しに使う `azookey-desktop-bridge` の操作をまとめたものです。Ubuntu の IBus エンジンはこの操作を使っています。Windows（TSF）と macOS も同じ操作で揃えます。

ブリッジは 1 行 1 要求の JSON（JSONL）で、要求ごとに 1 行の応答を返します。入力欄ごとの状態は要求の `context` で分かれます。AI の判断に使う値は要求の `ai` オブジェクトに入れます。要求の形式が誤っている場合は、ほかの操作と同じく `{"error": "invalid_request", ...}` を返します。

## Core が決めること・各 OS に残すこと

| Core が決める | 各 OS が受け持つ |
|---|---|
| 送る範囲（選択文と前後それぞれ最大 100 文字。保護された欄では送らない） | 入力欄の識別・周辺テキスト・選択範囲・保護属性を事実として渡す |
| 送信前の確認の内容（対象・送信先の表示・周辺テキストの初期値）と、確認後に送ってよいか | 確認画面の表示、利用者の選択（送信・周辺テキストの切替・取消）の報告 |
| プレビューのうち現在のものだけを受け付ける | AI への通信（API キーを付けて `ai` / `transform` 操作を別のブリッジ処理で実行） |
| 適用先の照合（元の欄・範囲・本文）と、確定した結果を一度だけ渡すこと | フォーカスや Reset の通知の順序の扱い、二つ目の読み取り（Ubuntu では AT-SPI）、本文への確定 |
| プロンプト履歴と固定、ショートカットの表記の検査と照合 | API キーの保管（Ubuntu は Secret Service） |

AI への通信は時間がかかるため、変換用のブリッジとは別のブリッジ処理で行います。変換用のブリッジは要求を順に処理するので、ここで通信すると入力が止まります。

## 事実の形式

### 入力欄（`field`）

```json
{
  "identity": ["/org/freedesktop/IBus/InputContext_12", "gtk3-im:gedit"],
  "surrounding": {"text": "前 原文 後", "cursorUTF16": 4, "anchorUTF16": 2},
  "hasSurroundingUpdate": true,
  "isSensitive": false
}
```

- `identity`: 入力先を表す文字列の配列。中身は OS ごとに決めてよく、Core は一致するかだけを見ます。入力先を名指しできない場合（フォーカスがない、周辺テキストに対応しない欄など）は `null` にします。Ubuntu は IBus の入力 context のパスとクライアント名です。
- `surrounding`: 欄が報告した周辺テキスト。位置は UTF-16 の単位です（ほかのデスクトップ操作と同じ）。サロゲートペアの途中を指す位置は無効として扱います。まだ報告がない場合は `null` です。
- `hasSurroundingUpdate`: `surrounding` がフォーカスを得たあとに届いたものか。フォーカスを得る前の報告は、今の入力先を表しません。
- `isSensitive`: パスワード・PIN・private ヒントの欄。Core はこの欄の本文を AI へ送らず、適用先にもしません。

文字列の比較は Unicode スカラー単位で行います。「か＋濁点」と「が」のように正規化すると同じになる文字も、別の本文として扱います。

### 二つ目の読み取り（`witness`）

一つの入力 context を複数の入力欄が共有する場合（GNOME Shell など）、入力先の識別と本文だけでは欄を区別できません。そこで、適用する前に別の手段で入力欄を読み直し、その結果を `witness` として渡します。Ubuntu は AT-SPI で読みます。

```json
{
  "object": ["fixture-bus-guid", ":1.4", "/org/a11y/atspi/accessible/12"],
  "window": [":1.4", "/org/a11y/atspi/accessible/3"],
  "start": 2, "end": 4,
  "before": "前 ", "selected": "原文", "after": " 後"
}
```

- `object`: 編集できる要素の識別。接続先の識別も含めます（読み取りのバスが再起動したら別の要素とみなすため）。
- `window`: 有効なウィンドウの識別。
- `start` / `end`: 読み取りに使った API 自身の位置。Core は別の読み取りと比べるだけで、`surrounding` の位置とは比べません。
- `before` / `selected` / `after`: 選択文と、その前後。前後は Core が返す `contextCharacters`（100）以内で読みます。

Core は、`selected` が選択文と一致し、`before` が選択の前の文の末尾を、`after` が後ろの文の先頭を含むときに、この読み取りが選択を表すと判断します。入力 context が段落だけを渡す場合でも、`witness` がより長い本文を読んでいてかまいません。

読み取れなかった場合や、読み取りの途中でフォーカスや選択が変わった場合は `null` を渡します。その場合は適用しません（コピーはできます）。

Windows の TSF は入力 context が文書ごとに分かれますが、適用の前に `ITfContext` から選択範囲と前後を読み直し、`object` に文書・context の識別、`window` にウィンドウの識別を入れて渡してください。読み直しを省くと、Core は適用を許可しません。

## キー操作の振り分け

### `ime-shortcuts`

何も入力していないときでも Core が意味を持たせるキーの組み合わせを返します。IBus や TSF はキーごとにその場で「入力方式で使うか、アプリへ渡すか」を答える必要があるため、この一覧と照らして、Core に送るキーを決めます。キーの意味は、キーが届いたときに Core が決めます。

```json
{"operation": "ime-shortcuts"}
```

```json
{"shortcuts": [
  {"key": "s", "modifiers": 2, "command": "suggestion"},
  {"key": "u", "modifiers": 3, "command": "unicode"},
  {"key": "e", "modifiers": 6, "command": "prompt"},
  {"key": "s", "modifiers": 2, "command": "prompt"}
]}
```

- `modifiers` はブリッジのキー形式のビット（Shift 1、Control 2、Option/Alt 4、Command/Super 8）で、完全に一致したときだけ当てはまります。`key` は修飾なしの文字（小文字）、`keyCode` がある項目はキーコードで照合します。
- `command`:
  - `suggestion`: AI 候補を求める（Ctrl+S）。
  - `unicode`: Unicode のコードポイント入力を始める（Ctrl+Shift+U）。
  - `prompt`: 選択文があるときに AI 変換の指示画面を開く（固定した指示のショートカットと、設定の AI 変換ショートカット）。AI が無効のときは含みません。選択文があるときだけ Core に送ってください。
- 一覧は、起動時と、入力欄がフォーカスを得るたびに取り直します。設定や固定した指示は別の画面で変わるためです。Ubuntu では設定の読み込み（`configure`）の後ろに並べるので、Core は新しい設定で答えます。
- 一覧が届く前は、Control（`prompt` は Control・Alt・Super）を含むキーをすべて Core に送ります。推測でアプリへ渡しません。

英数・かなキーの二度押し（`keyCode` 102 / 104）は、ふだんから Core に送るキーなので一覧にはありません。

### `key`

ふだんのキー操作に、選択文があるかどうかを足して送ります。

```json
{"operation": "key", "context": "<入力欄>", "event": {"keyCode": 0, "characters": "e", "charactersIgnoringModifiers": "e", "modifierFlags": 6},
 "doubleTap": false, "privateInput": false, "leftContext": "…", "rightContext": "…", "ai": {"hasSelection": true}}
```

応答はふだんのスナップショットで、AI について次のどちらかが `ai` に入ることがあります。

- 指示画面を開く: `"ai": {"prompt": {"initialPrompt": "敬語に直す"}}`。選択文があり、保護された欄でなく、AI が有効なときに、固定した指示のショートカット（その指示）・AI 変換ショートカット（空の指示）・英数／かなの二度押し（`english` / `japanese`）で開きます。このとき変換中の文字は変わりません。
- 送信前の確認を出す: Ctrl+S などで AI 候補を求めたとき（AI が有効で、保護された欄でない場合）。

```json
"ai": {"review": {
  "id": 7, "target": "にほんご", "destination": "api.example.com:8443", "includeContext": false,
  "bindings": [
    {"key": "s", "modifiers": 2, "command": "send"},
    {"key": "s", "modifiers": 3, "command": "toggleContext"},
    {"keyCode": 53, "modifiers": 0, "command": "cancel"}
  ]
}}
```

- `destination` は送信先のホスト名とポートだけです。表示できない URL では含みません（「送信先を確認できません」と表示します）。
- 確認中のキーは `bindings` と照らします。`send` は送信、`toggleContext` は周辺テキストを含めるかの切替、`cancel` は確認だけを閉じます。それ以外のキー（Return や文字）は確認を閉じ、ふだんの入力として扱います。修飾キーだけの押下では閉じません。
- 合成中の文字が何もないときは、`target` が「つづき」になります。

### `ai-review-send`

確認画面で送信を選んだときに送ります。

```json
{"operation": "ai-review-send", "context": "<入力欄>", "privateInput": false, "ai": {"review": 7, "includeContext": true}}
```

確認したときの合成から変わっていない（別のキー・候補選択・Reset が届いていない）、保護された欄でない、AI が有効、の場合だけ、AI へ送る引数を返します。確認を開いたあとに設定が変わっても、確認画面に出した送信先とモデルで送ります。周辺テキストは `includeContext` が真のときだけ入ります。

```json
{"request": {"target": "にほんご", "leftContext": "前の文", "rightContext": "", "includeContext": true,
             "aiModel": "gpt-4o-mini", "aiEndpoint": "https://api.example.com/v1/chat/completions"},
 "generation": 12, "reading": "にほんご"}
```

送れない場合は `{}` を返します。一度送った確認は使えなくなります。

続けて、別のブリッジ処理に `{"operation": "ai", "apiKey": "…", **request}` を送ります。返った `suggestions` を、`{"operation": "suggestions", "suggestions": [...], "generation": 12, "reading": "にほんご"}` で元の入力欄の context に送ると、Core は合成が変わっていない場合だけ候補として並べます。

## 選択した本文の変換

### 流れ

1. `ai-transform-open` に入力欄の事実を送る。Core が対象・送信先・履歴を返す。
2. `needsWitness` が真なら二つ目の読み取りを行い、`ai-transform-target` に送る。適用できるかどうか（`targetAvailable`）が返る。
3. 指示画面を出す。プレビューの要求は `ai-transform-preview`。返った `request` を別のブリッジ処理の `transform` 操作に API キーを付けて送り、結果を `ai-transform-result` に返す。
4. 指示や周辺テキストの設定を変えたら `ai-transform-invalidate`。
5. 「本文へ適用」を選んだら `ai-transform-confirm`。画面を隠し、元の入力欄へフォーカスが戻るのを待つ。
6. 元の入力欄の通知が来たら `ai-transform-check`。真なら二つ目の読み取りを行い、`ai-transform-take` に送る。返った `replacement` を本文へ確定する。
7. 途中で入力・Reset・保護属性の変化・フォーカス復帰の期限切れなどがあれば `ai-transform-reject`。画面を閉じたら `ai-transform-close`。

どの操作も応答を受け取った時点で、要求を送ったときからフォーカスが変わっていないかを OS 側で確かめてください。変わっていたら適用せず、結果はコピーできる状態で残します。

`ai-transform-open` 以外の操作は `ai.transformation` に識別子を入れます。Core が持っていない識別子（閉じた・置き換えた・ブリッジが再起動した）には `{"transformation": 3, "stale": true}` を返します。各 context で同時に持てる変換は一つです。

### `ai-transform-open`

```json
{"operation": "ai-transform-open", "context": "<入力欄>", "ai": {"field": { …入力欄の事実… }}}
```

```json
{"transformation": 3, "target": "原文", "destination": "api.example.com:8443", "includeContext": false,
 "needsWitness": true, "contextCharacters": 100,
 "history": [{"prompt": "敬語に直す", "pinned": true, "shortcutText": "Ctrl+Alt+e"}]}
```

選択文がない、または保護された欄では `{}`（`transformation` なし）を返し、画面は開きません。入力先を名指しできない欄では `needsWitness` が偽になり、結果はコピーだけできます。履歴は固定したものが先、その後に新しい順です。

### `ai-transform-target`

```json
{"operation": "ai-transform-target", "context": "<入力欄>",
 "ai": {"transformation": 3, "field": { …読み取り後の事実… }, "witness": { …読み取り… }}}
```

→ `{"transformation": 3, "targetAvailable": true}`

読み取りが開いたときの選択を表し、入力欄もまだ同じ選択を報告している場合だけ、適用先として覚えます。

### `ai-transform-preview`

```json
{"operation": "ai-transform-preview", "context": "<入力欄>",
 "ai": {"transformation": 3, "prompt": "敬語に直す", "pinned": true, "shortcutText": "Ctrl+Alt+e",
        "includeContext": false, "field": { …今の事実… }}}
```

- 指示が空、または前のプレビューを生成中: `{"transformation": 3, "previewRefusal": "emptyPrompt" | "loading"}`。何もしません。
- ショートカットの表記・重複、履歴の保存に失敗: `{"transformation": 3, "historyError": "format" | "modifierRequired" | "duplicateShortcut" | "saveFailed"}`。送信しません。
- 開始: `{"transformation": 3, "revision": 5, "request": {…AI へ送る引数（"prompt" を含む）…}}`。前のプレビューは適用できなくなります。
- 保護された欄・AI が無効: `{"transformation": 3, "revision": 5}`（`request` なし）。このプレビューは失敗として終わっています。

指示は前後の空白を除いて履歴に保存します（本文や周辺テキストは保存しません）。ショートカットは固定した指示にだけ付きます。

### `ai-transform-result`

```json
{"operation": "ai-transform-result", "context": "<入力欄>",
 "ai": {"transformation": 3, "revision": 5, "text": "変換した本文", "inputContextChanged": false}}
```

→ `{"transformation": 3, "accepted": true, "text": "変換した本文", "targetAvailable": true}`

- 通信に失敗した場合は `text` を `null` にします。空の結果と同じく、適用もコピーもできない状態になります。
- 現在のプレビューへの応答だけを受け付けます（`accepted`）。古い要求の応答、編集後に届いた応答、順序が逆に届いた応答は `accepted: false` で、表示中の結果は変わりません。
- 要求中に入力欄のフォーカスが変わっていた場合は `inputContextChanged` を真にします。結果はコピーできますが、適用先は使えなくなります（`targetAvailable: false`）。

### `ai-transform-invalidate` / `-confirm` / `-check` / `-take` / `-reject` / `-close`

| 操作 | `ai` に入れるもの | 応答 |
|---|---|---|
| `ai-transform-invalidate` | `transformation` | `{"transformation": 3}`。生成中・表示中のプレビューを無効にする |
| `ai-transform-confirm` | `transformation` | `{"transformation": 3, "confirmed": true}`。適用先と結果があるときだけ真 |
| `ai-transform-check` | `transformation`, `field` | `{"transformation": 3, "matches": true}`。偽なら適用先を捨てる |
| `ai-transform-take` | `transformation`, `field`, `witness` | `{"transformation": 3, "replacement": "変換した本文"}`。一度だけ |
| `ai-transform-reject` | `transformation` | `{"transformation": 3, "targetAvailable": false}`。結果はコピー用に残る |
| `ai-transform-close` | `transformation` | `{"transformation": 3}` |

`ai-transform-check` は、元の入力先へ戻ったときに、二つ目の読み取りをする価値があるかを答えます。フォーカスを得てから周辺テキストの通知がなければ、入力先の識別が同じであれば真です。新しい通知があれば、その選択が元と同じ（向きと本文を含む）である必要があります。矛盾する通知が一度でも来たら、あとで元の選択に戻っても適用しません。

`ai-transform-take` は、入力欄の事実と新しい読み取りが両方とも元の選択を表す場合だけ、確定した結果を返します。返すのは一度だけで、一致しなかった場合も適用先を捨てます。

## ショートカットの表記

### `ai-shortcut`

設定画面などで、ショートカットの表記（`Ctrl+Alt+e`）を Core に読ませる・表示させる操作です。

```json
{"operation": "ai-shortcut", "ai": {"shortcutText": "ctrl+alt+E"}}
```
→ `{"shortcut": {"key": "e", "modifiers": 6}, "shortcutText": "Ctrl+Alt+e"}`

```json
{"operation": "ai-shortcut", "ai": {"shortcut": {"key": "g", "modifiers": 6}}}
```
→ `{"shortcut": {"key": "g", "modifiers": 6}, "shortcutText": "Ctrl+Alt+g"}`

修飾キーの名前は Ctrl・Alt・Shift・Super で、`+` でつなぎ、最後に 1 文字を置きます。空の表記は「ショートカットなし」（`shortcut` なし）です。読めない表記には `{"shortcutError": "format"}`、修飾キーがない表記には `{"shortcutError": "modifierRequired"}` を返します。

## エラーコードと表示

Core は画面の文言ではなくコードを返します。Ubuntu は次の文言を `Linux/azookey/locales/ja.json` から表示します（`Linux/azookey/ai_error_messages.py`）。共通の文言カタログができたら、そちらへ移します。

| コード | 文言のキー |
|---|---|
| `format` | `ai.shortcut.error.format` |
| `modifierRequired` | `ai.shortcut.error.modifier-required` |
| `duplicateShortcut` | `ai.shortcut.error.duplicate` |
| `saveFailed` | `ai.history.error.save` |

## 保存先

プロンプト履歴は設定ファイルと同じディレクトリの `prompts.json`（Ubuntu では `$XDG_CONFIG_HOME/azookey-tree/prompts.json`）に、指示文だけを保存します。ファイルは利用者だけが読める権限（0600）で作り、ディレクトリがなければ 0700 で作ります。形式は Ubuntu の既存の形式と同じです。

```json
[{"prompt": "敬語に直す", "pinned": true, "lastUsed": 1792500000.0, "shortcut": {"key": "e", "modifiers": 6}}]
```

ファイルがない場合は、固定した 4 件（`elaborate`・`rewrite`・`formal`・`english`）を返します。読めないファイルは空の履歴として扱います。固定していない指示は新しい 10 件まで残します。

## 試験

判断の試験は Swift にあります。

- `Core/Tests/CoreTests/DesktopAITests/AITransformationTargetTests.swift`: 別の欄・別のウィンドウ・再起動したバス・移動した選択・変わった本文・正規化で同じになる文字・段落と文書の違い。
- `AISelectedTextTransformationTests.swift`: プレビューの重複送信・再生成・古い応答・逆順の応答・空・失敗・フォーカス変更後の応答・保護された欄、適用の一回限り。
- `AIDesktopRequestFlowTests.swift`: 外部に送らない模擬 API（URLProtocol）で、遅延・空・サーバーエラー・壊れた応答・逆順の応答を実際の通信処理に通す。
- `AIPromptHistoryTests.swift` / `DesktopKeyBindingTests.swift`: 履歴・固定・ショートカットの表記と照合。`IMEShortcuts` が `UserAction` の意味と一致すること。
- `Core/Tests/DesktopBridgeTests/DesktopAIControllerTests.swift`: JSON の操作として、確認後の送信・設定変更後の送信先・合成の変化・保護された欄・ショートカットからの指示画面・変換の各操作。

Ubuntu には、IBus と GTK の通知の順序を扱うつなぎの試験（`Linux/tests/test_selected_text_*.py`、`test_ai_scope.py`）と、実 IBus・実 AT-SPI を使う統合の試験（`Tools/tests/linux-ai-target.sh`、`Tools/tests/linux-ime-shortcuts.sh`）が残ります。どれも実際の Swift ブリッジに判断させ、AI への通信は試験の中の模擬に置き換えます。
