# 候補処理から独立した読みプロセス

`AZOOKEY_BRIDGE_ROLE=reading` は開発検証用の明示的な入口です。通常の IBus frontend はこの値を設定せず、既存の bridge を使用します。標準ローマ字・ライブ変換 OFF の読みを扱い、製品の入力経路は切り替えません。

`BridgeMain` は converter、学習ディレクトリ、辞書を初期化する前にこの入口へ分岐します。`DesktopReadingWorker` が欄ごとに `DesktopReadingSession` を持ち、Core の `UserAction`、`InputState`、`CompositionState` で入力を解釈します。ローマ字変換を frontend へ複製しません。

## JSONL と入力の所有者

専用 JSONL は1行に1要求・1応答です。通常の `BridgeRequest` や旧試作 protocol は受け付けません。全応答に `kind`、`readingProcessGeneration`、`settingsRevision` を含みます。`kind=input` の応答だけが `snapshot` を持ちます。snapshot のカーソルは既存の IBus protocol と同じ Unicode scalar 単位です。

読みプロセスは起動時に UUID の `readingProcessGeneration` を生成し、正式入力の `compositionRevision` と欄の `focusEpoch` を管理します。coordinator がこれらの数値を作ったり、候補返信から更新したりしてはいけません。`hello` で process 世代を取得し、`open` / `focus-in` の reference、および `focus-out` の nextReference に読み側が払い出した参照を保存します。

context 参照は `{context, readingProcessGeneration, focusEpoch}` です。context ID は coordinator が実入力欄に対応させます。`focus-in` は新しい epoch を返し、`focus-out` も古い epoch を退役させます。同名の context を close / open しても epoch を再利用しません。

| operation | 必要な要求 field | 応答 kind / 内容 |
| --- | --- | --- |
| `hello` | なし | `process` / 世代・設定 revision・上限 |
| `open` | readingProcessGeneration、context | `acknowledgement` / 新しい非activeの参照 |
| `focus-in` | reference、surroundings | `acknowledgement` / 新しいactiveの参照 |
| `focus-out` | reference、submit | `input` / 元欄のsnapshot・旧reference・退役後のnextReference |
| `key` | reference、event、任意のdoubleTap | `input` / 正式入力操作後のsnapshot |
| `reset` | reference、submit | `input` / 確定または取消snapshot |
| `snapshot` | reference | `input` / 現在状態。確定通知の再送なし |
| `close` | reference | `acknowledgement` / 非activeの欄を削除 |
| `prepare-candidates` | reference、candidateWorkerGeneration | `candidates` / candidateRequest |
| `adopt-candidates` | reference、batch、retainedReference | `acknowledgement` / candidateReference |
| `select` | reference、selection | `input` / 明示選択後のsnapshot |
| `candidate-worker-stopped` | reference、candidateWorkerGeneration | `acknowledgement` / 対象workerの未確定要求を退役 |
| `learning-revision` | readingProcessGeneration、settingsRevision | `acknowledgement` / 単調増加した学習revision |

`surroundings` は `{leftContext, rightContext, privateInput}` の全3項目が必須です。左右文脈は受信上限を検査した後、既存 bridge と同じ左右各100文字へ限定します。`selection` は `{batch: DesktopCandidateBatchReference, candidateID}` です。数値 index による選択 wire はありません。`event` は既存 `KeyEventCore` の keyCode、characters、charactersIgnoringModifiers、modifierFlags を使用します。

## 焦点移動と拒否

active の欄は1つです。別欄へ移る前に、coordinator は元欄を指定して `focus-out` を完了させ、`submit=true` ならその入力応答を元欄へ一度だけ反映します。入力応答の reference は常に元要求と同じ参照で、completion.authority も元の焦点を示します。coordinator はこの参照で元要求・元欄を照合して snapshot を一度適用した後、別fieldの nextReference を以後の操作用に保存します。nextReference は退役後の非active欄の参照であり、そのepochへ commit を適用する指示ではありません。`submit=false` は取消であり、文字を確定しません。その後に次の欄へ `focus-in` します。active のまま close して入力を破棄することはできません。

焦点・周辺文脈・private 状態の事実は OS adapter が供給します。読みプロセスは別欄への移動を本文の一致から推測しません。周辺文脈や private が変化した場合も lifecycle を通し、古い参照を退役させてから新しい条件を渡します。

process 世代、context、focus epoch を編集前に照合します。不正要求は作業用コピー上で失敗させ、正式入力・カーソル・候補状態を保持します。拒否は `kind=error` と固定の `error` コードだけを返し、snapshot、preedit、commit を含めません。古い要求のエラーで、現在の入力欄を消してはいけません。

未知の要求項目、負の revision、非対応 operation、数値選択も拒否します。未知 operation は `unsupported_reading_operation`、未接続キーは `unsupported_reading_action`、再変換 shortcut は `reconversion_requires_coordinator` です。これらを入力操作の成功として適用してはいけません。

## 通常の変換キー

Space・下矢印は必要な読み区切りを正式入力へ加え、候補がなければ入力応答に `request: "candidates"` を返します。その間は読みを表示し続け、候補到着後の明示キーで選択します。この開発段階では、到着だけで変換表示へ進めません。候補待ちのEnterは読みを確定し、Escapeは変換要求を取り消して読みを残します。さらにEscapeを押すと読みを取り消します。

Shift＋左右は実際に選んだ候補の消費範囲を基準に文節を変更し、変更後の正式入力を要求に使用します。候補待ちでSpaceを押しても編集した範囲は保持します。選択中のSpace・Shift＋Space・上下矢印は現在の一覧内を移動し、Enterは選択した候補IDを確定します。全読みを消費する候補を優先してpreviewし、なければ実在する先頭候補を使います。複数候補の単語を組み合わせません。

F6〜F10の文字種変換も読み側で完了します。選択中または文節編集後の候補待ちは、その範囲だけを変換して残りの読みを保持します。F9/F10は共有Coreの正式なキー境界を使い、「ん」「っ」「き｜ょ」の境界を独自に推測しません。変換文字を架空の候補として候補プロセスへ学習通知することはありません。ひらがな・カタカナ・全半角の変換処理は既存Linux/Mac adapterと共通です。

選択中の1〜9は、現在選択しているページ内の実候補IDを確定します。末尾ページにない番号は表示と選択を保ちます。候補待ちやpreview中は番号を表示せず、数字は通常の文字入力として扱います。遅れて届くpointer/AT操作が数値indexを使うことは引き続き禁止し、batch参照とcandidateIDを必要とします。

明示選択後の Enter は、その候補と検証済みの残る読みを使用します。候補プロセスが停止しても、表示済みの選択対象を変えません。学習通知は元の入力応答にだけ含め、通常の snapshot や次のキーへ再送しません。Enterや右矢印による部分確定後は文脈も更新して残りの候補を要求し、到着待ちでもEnterで残る読みを確定できます。選択取消・編集では古い選択を外し、選択中の英数切替では表示中の文字を確定します。選択した接頭辞と生の読みを一括確定する場合、その組合せを架空の候補として学習させません。

## 候補の保持、採用、確定

1. coordinator が候補 worker の世代を取得し、その世代を `prepare-candidates` に渡します。読み側は正式入力と現在の文脈から要求を作り、対象 worker の世代を保存します。
2. coordinator が candidateRequest を候補 worker へ渡します。返された batch を candidate worker の `retain` へ送り、成功した ACK を待ちます。
3. **実際の retain ACK を受けた後だけ**、その reference と batch を `adopt-candidates` に渡します。読み側は両参照の一致、対象worker、要求、入力・焦点・設定世代、文脈、消費範囲を検証します。読み側だけでは remote ACK の発生を証明できないため、実ACKを待つ責任は coordinator にあります。
4. 採用応答は候補参照だけです。未確定文字・カーソル・入力状態は変わりません。pointer / AT / 遅れて届く操作は、表示した batch 参照と candidateID を `select` に渡します。
5. 明示選択後の Enter は、その候補と検証済みの残る正式入力を使います。確定 snapshot にだけ candidateCompletions が入り、snapshot 取得や次のキーでは再送しません。coordinator はこれを元の candidate worker の `complete` へ渡します。

部分確定後は残る正式入力と、確定済みprefixを加えた左文脈で新しい候補を要求します。取消・編集で候補が不要になった場合、coordinator は保持している旧参照を candidate worker の release へ渡します。候補本文の組合せや Zenzai の修正履歴を再構築しません。選択したprefixと生の読みsuffixを reset等で一括確定する場合、その組合せを架空の候補として学習させません。

`candidate-worker-stopped` は現在の対象世代だけを退役させます。古い worker の遅れた停止通知で新しい worker を無効化しません。未採用候補と新しい選択の入口は失われますが、選択済みの確定対象は保持し、候補 worker の応答なしで確定できます。学習 ACK が不明のまま worker が終了したときは、入力確定と学習未確認を区別し、別世代へ自動再送しません。

## 学習 revision と上限

`learning-revision` は candidate worker の設定 ACK を得た後に呼びます。読み側全体に単調増加revisionを適用し、計算中の旧要求を退役させます。選択済み候補は保持し、完了通知の authority は計算時、別fieldの settingsRevision は確定時を表します。private入力の確定通知も元のprivate条件を維持します。一般設定・辞書・入力表の同期はこの操作に含めません。

transport の上限は `DesktopWorkerProtocolLimits` にまとめています。JSON 4 MiB、opaque ASCII ID 1〜512 bytes、左右文脈各16 KiB、1process最大64contextです。正式入力には `CompositionSnapshotLimits` も適用します。入力前後で上限を検査し、限度超過で元入力を消しません。長すぎる JSONL は改行まで破棄して1エラーを返し、次の行を読みます。

応答不明時に key / reset / select を自動再送する契約はありません。coordinator は元要求と応答の対応を保持し、process 終了時は未完了の入力と候補処理を区別して回復する必要があります。

## 検証範囲と未接続部分

Swift と実 JSONL で、旧世代・旧焦点・close/open ABA、別欄、private、部分確定、候補停止、不正要求後の継続を検査します。消費範囲の負例には明示した合成候補を使います。`AZOOKEY_CANDIDATE_BRIDGE` を指定した追加試験は別の実 candidate process を使い、実候補の retain ACK → 採用 → 選択 → 確定 → complete を往復します。候補 process を SIGSTOP した間も、読み側の編集・確定が完了することを検査します。

frontend coordinator、通常製品入口への切替、一般設定同期、予測・AI・再変換、ライブ変換 ON は未接続です。実アプリの key-to-paint、IBus / GTK / Qt / Wayland の応答性や、P1 #17 全体の受入を、この protocol 単体の成功で満たしたとは扱いません。
