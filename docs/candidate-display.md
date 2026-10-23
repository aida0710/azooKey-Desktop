# 候補表示の共通形式（Core が決めて各OSが描く）

候補ウィンドウに「何を出すか」と「どこに置くか」は Core（`Core/Sources/Core/Desktop/Candidates`）が決めます。各OSに残すのは、入力の仕組みへのつなぎ、文字の測定、描画、OS の座標の換算だけです。macOS は Core を直接使い、Linux（GTK・GNOME）と Windows はブリッジ（`azookey-desktop-bridge` の JSONL）を使います。

| 決めること | 置き場所 | ブリッジでの受け取り方 |
| --- | --- | --- |
| 木と一覧のどちらを出すか、描く列、一覧の行の番号（1〜9）、読み上げ文、詳細文、確定ボタンの文言と可否、前後ページ、残る読み | `CandidateDisplay` | すべての応答の `candidateDisplay` |
| 相対スコアの色の区分 | `CandidateScoreRole` | `nodes[].scorePresentation.role` |
| 節点の枠、行の高さ、列の幅、文書の語への整列、ポップアップの幅、配置と向き | `CandidateLayout`、`CandidateTreeLayout`、`CandidatePopupPlacement` | `candidate-layout` 操作 |
| 文字の大きさ（標準 14、大きい 18、OS の文字倍率が 1 未満なら縮めない） | `CandidateTextMetrics` | `candidate-layout` の `tree.metrics` |

## 語ごとの別候補と枝の続き

`CandidateWordAlternatives` は、選択中の文の各語の読みを `ComposingText` に入れ、`KanaKanjiConverter.requestCandidates(_:options:)` で別候補を取ります。全文のラティスは公開 API から取り出せないため、読みの範囲を区切った要求を使います。全文変換とは別のセッションを作り、要求後に破棄します。辞書と学習設定は全文変換と共通ですが、Zenzai・予測変換・誤り訂正・特殊変換は切ります。

使うのは、指定した読みをすべて消費し、辞書データの読みが完全に一致する候補だけです。テンプレート展開で表記が辞書データと食い違う候補や、カーソル移動などの動作を伴う候補は差し替えに使いません。読みの範囲や区切りを推測で作ることもありません。

別候補を取ったら、元の文の該当する語だけを差し替えた `Candidate` を候補一覧の末尾に追加します。前後の語、入力の消費範囲、辞書データは保持します。置換した語が複数の辞書要素から成る場合も、木では元と同じ読みの範囲を一つの節点として扱います。既存の候補に同じ範囲・同じ道があれば再利用します。全文がかなだけの候補を選んだときも、木と同じく元の変換結果の読みの境界を使い、後ろの語を差し替えられます。

たとえば「今日は／学会／に行こうと／思っています」の「学界」を選ぶと、「今日は学界に行こうと思っています」が選択されます。この文が全文変換の上位候補になくても、追加した候補番号で通常どおり確定でき、学習にも置換後の辞書データを渡せます。文全体の評価はしていないため、追加した候補の評価値は内部で `-infinity`、表示と JSON では評価なしです。相対スコアの計算にも含めません。

語を選ぶときは、前後が選択中の文と同じ候補を優先します。その語だけを差し替える候補がない場合は、その節点を通る最上位の候補を選びます。選択後は新しい道にも別候補を追加します。追加は末尾だけに行い、すでに表示した候補番号を変えません。打鍵・読みの編集で変換をやり直したときは、追加した全文候補を作り直します。

木の各列は、先頭に選択中の語、その下に同じ親から分かれる兄弟、さらに前の列の別の道から続く語を並べます。兄弟は同じ読みの範囲を優先します。2・3番目の道にも、選択時に確定する候補の続きが出ます。続きの兄弟までは展開しません。すでに伸びている枝を優先し、選択中の道の最後の列まで描きます。それより長い続きはプレビューで全文を確認でき、その道を選ぶと表示されます。

| 上限 | 値 | 理由 |
| --- | --- | --- |
| `CandidateWordAlternatives.alternativesPerWord` | 2 | 各語に選択肢を出し、打鍵中の高さを抑える |
| `CandidateWordAlternatives.maximumWords` | 16 | 普通の文を扱いつつ、長い貼り付けで要求が増え続けるのを防ぐ。17語目以降も既存の全文候補の枝は出す |
| `CandidateWordAlternatives.maximumCandidates` | 96 | 最大16語×2候補を3回分追加できる。上限に達したら、その変換中は追加を止め、既存の候補を維持する |
| 語ごとの要求の `N_best` | 3 | 表示する2候補と元の表記に必要な小さな探索幅にする |
| `CandidateTree.maximumSiblingsPerWord` | 2 | 選択中の各語の下に置く兄弟の数 |
| `CandidateTree.maximumContinuationsPerColumn` | 2 | 前の列の別の道から続ける数。各列は合計5節点以下 |

木の設定が無効なら、語ごとの要求は実行しません。同じ読みの要求結果は入力中に再利用し、現在の文の対象語から外れた読みは捨てます。確定・入力取消・辞書の再読込ではキャッシュを捨て、学習設定が変わったときも取り直します。

`columns` の先頭は引き続き選択中の道です。各OSは後続の節点がすべて兄弟だと仮定せず、`nodes[].parent` に線をつなぎます。`CandidateLayout` は増えた行にも別々の枠を割り当て、`contentSize` を広げます。一覧で木を開くときは、操作中の列の兄弟だけを出し、親を隠した別の道の続きを出しません。

### 打鍵時間の計測

`AZOOKEY_TREE_BENCHMARK=1 swift test -c release --package-path Core --filter treeTypingReportsPerKeyLatency` で、29字の読みを1字ずつ入力した時間を測れます。辞書変換・学習なしで、1文分の準備運転の後に7文、計203打を測ります。候補の取得から木の組み立てまでを含み、中央値と最大値を木の設定の有効・無効それぞれで出します。Zenzai の推論と各OSの描画時間は含みません。

## 単位

長さはすべて論理ピクセル（96 dpi 基準）です。AppKit のポイント、Windows の DIP、GTK と GNOME の論理ピクセルはそのまま使えます。次の換算は各OSで行い、Core には換算後の値だけを渡します。

- GTK（X11）: IBus のカーソル矩形は物理ピクセルなので、GTK の window scale で割る（`ibus_coordinates.py`）。
- GNOME（Wayland）: panel service の相対矩形に対象ウィンドウの位置を足す（`shellCursor.js`）。
- Windows: 物理ピクセルを DPI で DIP に直す。

## `candidateDisplay`（すべての応答）

キー入力・選択などの応答には、同じ応答の `nodes`・`columns`・`candidatePage` などから作った `candidateDisplay` が付きます。`nodes` が空、または `columns` が空のときは `mode` が `hidden` です。

```json
{
  "mode": "list",
  "columns": [[1, 0, 3], [2]],
  "baseFontSize": 14,
  "detailNode": 1,
  "expandTree": false,
  "announcement": "変換候補 2 / 56。にほん。読み ニホン。語 1 / 2。確定予定 にほんご",
  "nodes": [
    {"id": 1, "selected": true, "focused": true,
     "accessibleName": "にほん（ニホン）",
     "accessibleDescription": "操作対象。押すと候補を選択\n確定予定: にほんご\n…",
     "detailText": "にほん\nニホン\n確定予定: にほんご\n…\n矢印キーで詳細を確認・PageUp / PageDownで詳細をスクロール"}
  ],
  "list": {
    "title": "確定する文章", "commitText": "にほんご",
    "readingText": "読み にほんご", "positionText": "変換候補 2 / 56",
    "keyboardConfirmsCandidate": true, "confirmLabel": "確定 ↵",
    "confirmAccessibleName": "確定 にほんご", "confirmAccessibleDescription": "押すと候補を確定",
    "confirmIndex": 1, "nextIndex": 9,
    "items": [
      {"index": 0, "number": 1, "text": "日本語", "selected": false,
       "accessibleName": "日本語（にほんご）",
       "accessibleDescription": "押すと候補を選択\n確定予定: 日本語\n確定する読み: にほんご",
       "detailText": "確定予定: 日本語\n確定する読み: にほんご"}
    ]
  }
}
```

| 項目 | 意味 |
| --- | --- |
| `mode` | `tree`: 打鍵中（`composing` など）。候補の枝を含む木だけを出す。`list`: 変換中（`selecting`・`previewing`・`replaceSuggestion`）。全文候補の一覧を出し、木は求められたときだけ出す。`hidden`: 何も出さない |
| `columns` | 描く節点の id を列ごとに並べたもの。各列の先頭は選択中の文の語。`list` では操作中の列だけ兄弟を並べ、ほかの列は選択中の語だけにする |
| `baseFontSize` | 文字倍率をかける前の候補の文字の大きさ。`candidate-layout` の `textWidth` はこの大きさで測ると正確 |
| `nodes` | `columns` に出る節点だけ。木の語には番号を付けない（数字キーの番号は一覧の行にだけ出す） |
| `detailNode` | ポインターが何も指していないときに詳細を出す節点（操作対象の語、無ければ最初の語） |
| `expandTree` | 同じ候補のまま操作対象の語だけが動いた応答で `true`。木を開いて対象を見せる。同じ応答を描き直すときは1回だけ扱う（GTK・GNOME は `contextId` と `generation` で判断している）。変換中の↑↓は、木が出ているあいだは操作対象の語の兄弟を動き、出ていないあいだは一覧の行を1つずつ動く（macOS の候補画面と同じ）。木が出ているかは `key` の要求の `candidateDisplay.treeShown` で伝える（下記）。伝えないOS（Windows）は、この応答から一覧が閉じるまで木を開いたままにし、Core は↑↓をこの応答までは一覧の行、この応答からは兄弟の移動にする。変換を終えると一覧の行の移動に戻る |
| `announcement` | 変換中に選択か操作対象が変わったときに読み上げる文。打鍵中は `null`。同じ入力欄で直前と同じ文なら読み上げない |
| `list` | 全文候補の一覧。候補が無く選択も無いときは `null`。`tree` のときも、一覧を開けるように付く（見出しは「候補のプレビュー」、確定ボタンは「この候補を確定」） |
| `list.confirmIndex` | 確定ボタンで確定する候補。`select` 操作に `submit: true` で渡す。`null` なら確定ボタンを無効にする |
| `list.previousIndex`・`nextIndex` | 前後のページへ移るときに `select`（`submit: false`）で選ぶ候補。`null` ならボタンを無効にする |

「一覧」「閉じる」「前へ」「次へ」「文節を調整」「詳細を表示」「選択中」など、状態で変わらないボタンの文言は今のところ各OSの文言を使います（文言の共通化は別の作業で行います）。

## `key` の要求の `candidateDisplay`（木が出ているか）

GTK と GNOME の候補画面には「木を開く」「木を閉じる」のボタンがあり、利用者が木を出し入れできます。Core は変換中の↑↓を、木が出ていれば兄弟の移動、出ていなければ一覧の行の移動にするので、各OSはキーを押したときに木が出ていたかを `key` の要求に載せます。

```json
{"operation": "key", "context": "<入力欄>", "event": {"keyCode": 125, "modifierFlags": 0},
 "candidateDisplay": {"treeShown": false}}
```

| 項目 | 意味 |
| --- | --- |
| `treeShown` | キーを押したときに候補画面が木を出していたか。`expandTree` で開いたときも、ボタンで開いたときも `true`。ボタンで閉じた後や、木の無い一覧（IBus の候補表）では `false` |

- Core は変換中（`selecting`）の矢印キーでだけこの値を読みます。打鍵中の木（`mode` が `tree`）で `true` を送っても、変換中の動きには影響しません。
- 値が無い要求では、上の `expandTree` の規則で決めます（Windows と、この値を送らない古い画面）。
- 送るのはキーを押した時点の表示です。返事を待っている間に押したキーは、まだ描いていない応答の `expandTree` を含みません。

Linux では、エンジンがすべての `key` の要求にこの値を付けます。GTK の候補画面（X11）は `TreePanel.tree_expanded` をそのまま使います。GNOME 拡張は別のプロセスなので、木を出すかどうかが変わるたびに `org.azookey.Tree` の `SetTreeShown(b 出しているか, s contextId)` でエンジンに知らせます。エンジンはこれを、登録された描画側から届いた、その入力欄の値としてだけ使い、`Hide` を送ったときと描画側がいなくなったときに忘れます。

## `scorePresentation.role`

相対スコアは既定では出しません（設定の `showRelativeScores`、2026-10-23 から既定は `false`）。スコアは変換エンジンの評価値から計算し、Zenzai の並べ替えは反映しないので、選ばれた候補が下の候補より低く見えることがあるためです。出す設定のとき、描く節点の `scorePresentation` に `label`・`role`・`detailDescription` が付きます。`role` は `Shared/CandidatePalettes.json` の役割名（`scoreLow`・`scoreHigh`・`scoreUnknown`）で、バッジの背景色にその役割の色を使います。75 未満が `scoreLow` です。

## `candidate-layout` 操作

各OSは自分のフォントで文字を測り、作業領域とカーソルを渡します。Core は節点の枠とポップアップの幅、`popupHeight` があれば配置まで返します。入力の状態を持たない操作なので、`context` は要りません。

```json
{"operation": "candidate-layout", "layout": {
  "mode": "tree", "textSize": "standard", "textScale": 1, "measuredFontSize": 14,
  "columns": [{"nodes": [{"id": 0, "parent": null}, {"id": 1, "parent": null}, {"id": 3, "parent": null}],
               "textWidth": 42.0}],
  "lineHeight": null, "documentWordWidths": null, "columnAnchorX": null,
  "showScores": true,
  "cursor": {"x": 300, "y": 200, "width": 0, "height": 24},
  "workArea": {"x": 0, "y": 32, "width": 1280, "height": 768},
  "popupHeight": 180, "preferredSide": "below"}}
```

| 入力 | 意味 |
| --- | --- |
| `mode` | `list`: 全文候補の一覧を出しているとき（打鍵中でも一覧を開いたら `list`）。`tree`: 木だけ |
| `textSize`・`textScale` | 候補の文字サイズ設定と OS の文字倍率（GTK は `gtk-xft-dpi / 96`、GNOME は `text-scaling-factor`） |
| `measuredFontSize` | `textWidth` と `lineHeight` を測った文字の大きさ。Core が候補の文字の大きさへ比例で直す |
| `columns` | `candidateDisplay.columns` の順の節点（`id` と、描く木の上での親 `parent`）と、列の先頭の節点の文字の幅 |
| `lineHeight` | 任意。`measuredFontSize` で1行を測った高さ（節点の中に枠線を描くならその分も含める）。語の行は「文字 + 12」を最小に、この比率より低くしない |
| `documentWordWidths` | 任意。文書上の語の幅が分かるとき（GTK の推定語幅、Windows の文字矩形）。全列の幅が揃い、どの列も選択中の語（`textWidth` と左右の余白）に隙間 6 を足した幅があるときだけ整列する。足りない列があれば、語が切れないよう語の長さに合わせた列にする |
| `columnAnchorX` | 任意。整列するときの文頭の x |
| `showScores` | スコアの行を確保するか（`showRelativeScores`） |
| `cursor` | 実際のキャレット。ポップアップはこれを覆わない |
| `workArea` | カーソルのあるモニターの作業領域 |
| `popupHeight` | 任意。返った `popupWidth` で測ったポップアップ全体の高さ。あるときだけ配置を返す |
| `preferredSide` | 任意。前回の向き。まだ入るならその向きを保つ |

応答（`candidateLayout`、配列は先頭だけ示す）:

```json
{"popupWidth": 185, "placementStatus": "placed",
 "placement": {"x": 300, "y": 224, "width": 185, "height": 180, "side": "below"},
 "tree": {
   "aligned": false, "reason": "unavailable-or-narrow", "textAlignment": "center", "rowHeight": 42,
   "metrics": {"fontSize": 14, "scoreFontSize": 12, "wordHeight": 26, "scoreHeight": 16,
               "scoreBadgeMinimumWidth": 22, "scoreBadgeHorizontalInset": 3},
   "nodes": [{"id": 0, "column": 0, "row": 0,
              "frame": {"x": 10, "y": 5, "width": 51, "height": 42},
              "textFrame": {"x": 14, "y": 5, "width": 43, "height": 26},
              "scoreFrame": {"x": 10, "y": 31, "width": 51, "height": 16}}],
   "edges": [{"node": 0, "start": {"x": 4, "y": 26}, "end": {"x": 10, "y": 26}}],
   "rootAnchor": {"x": 4, "y": 26},
   "contentSize": {"width": 70, "height": 149}}}
```

| 出力 | 意味 |
| --- | --- |
| `tree.nodes[].frame` | 押せる範囲（ポインターと支援技術の対象）。スコアの行を含む。行の間は 6 空ける。文書の語に揃えたときは、列の始まりを語に合わせ、語の幅から 6 を空けて隣の語と離す |
| `textFrame` | 語を描く範囲。`textAlignment` が `leading` なら左寄せ、`center` なら中央。はみ出す語は末尾を省略する |
| `scoreFrame` | スコアのバッジを描く行。バッジの幅は文字の幅 + `scoreBadgeHorizontalInset` × 2（`scoreBadgeMinimumWidth` 以上、`scoreFrame` の幅以下）で、中央に置く。色は `scorePresentation.role` |
| `edges` | 親から子へ線を引く。`start` は親の右端の中央、親が描かれていない節点は `rootAnchor` から。線は `node` が選択中の文の語なら太く実線、ほかは細い点線 |
| `contentSize` | 木を描く面の大きさ。ポップアップより大きいときはスクロールする |
| `aligned`・`reason` | 文書の語の下に列を揃えたか。`estimated-inline`（揃えた）、`unavailable-or-narrow`（語の幅が無いか狭い）、`outside-workarea`（画面内に収まらない、または横に置いた） |
| `popupWidth` | ポップアップの幅。木だけなら 185 以上、一覧なら 320 以上かつ文字 26 字分（最大 430）以上、揃えないときは 585 以下、作業領域の幅以下 |
| `placementStatus` | `notRequested`（`popupHeight` が無い）、`placed`、`unavailable`（キャレットが作業領域を覆い、置ける場所が無い。ポップアップを隠す） |
| `placement` | ポップアップの左上と大きさ、向き（`below`・`above`・`right`・`left`）。下、上、右、左の順に入る向きを選ぶ。どれにも入らないときは上下の広い方へ高さを縮め、上下に余地が無ければ左右の広い方へ幅を縮める |

### 呼び出しの手順

1. `candidateDisplay.columns` の各列の先頭の語を `baseFontSize` で測り、`popupHeight` なしで呼ぶ。
2. 返った `tree` の枠で木を描き、`popupWidth` の幅で一覧などを並べてポップアップ全体の高さを測る。
3. 同じ入力に `popupHeight` を足してもう一度呼び、`placement` の位置に出す（木だけでほかに何も無いなら、1回目から `popupHeight` を付けてよい）。
4. 2回目の `popupWidth` が測った幅と違うとき（揃えた列が横に置かれて整列をやめたとき）は、その幅で測り直して3をやり直す。
5. `placement.height` が渡した高さより低いとき（どの向きにも入らず、高さを縮めたとき）は、その高さに収まるように中身を縮める。GNOME は縮めた高さで3をもう一度行い、GTK はポップアップ全体をスクロールにして収める。`popupHeight` は整数で渡す（Core は位置と大きさを整数に切り捨てる）。
6. カーソルや作業領域だけが変わったときは、測った高さを使って3だけを行う。

Linux では、エンジンが変換と同じ順番待ちの列（`AsyncBridge`）でこの操作を送ります。入力中の要求とは別に扱い、返ってきたときに文脈・世代・候補が変わっていれば捨てます。GNOME 拡張は `org.azookey.Tree` の `Layout` メソッドでエンジンに頼みます。

## `candidate-display` 操作

スナップショットの形の JSON を `snapshot` に入れると、その `candidateDisplay` を返します。描画の試験で、作った候補の並びから表示を得るときに使います。直前の応答の選択と操作対象の語を `snapshot.previous`（`{"selection": 0, "focusedNode": 10}`）に入れると `expandTree` も確かめられます。

```json
{"operation": "candidate-display", "snapshot": {
  "inputState": "composing", "selection": 0, "selectedPath": [0], "columns": [[0]],
  "nodes": [{"id": 0, "text": "日本", "reading": "ニホン", "preview": {"candidateIndex": 0, "text": "日本"}}],
  "candidates": [{"index": 0, "text": "日本"}]}}
```

## 以前の GTK・GNOME との違い

GTK と GNOME で別々だった判断を1つにしたため、次の点が変わりました。

- 表示の種類: GTK は `composing` 以外をすべて一覧、GNOME は選択系の3状態以外をすべて木としていた。今は選択系の3状態が一覧、それ以外が木。
- 一覧のときの木: GTK はすべての列で兄弟を並べていた。今は GNOME と同じく、操作中の列だけ兄弟を並べる。
- 配置: GNOME は下か上だけで、入らないときは作業領域の端へ寄せていた。今は GTK と同じく、右と左も使い、キャレットを覆わない。
- 列の幅: GNOME は文字の幅 + 24（最大 280）、行の高さは測った値だった。今は文字の幅 + 9（最大 185、最小は 24 と文字 + 8 の大きい方）、行の高さは文字 + 12。どちらの OS も測った `lineHeight` を渡し、それより高いフォントでは行を高くする。スコアのバッジは GNOME でも節点の中に置く。
- ポップアップの幅: 一覧のときは 320 以上かつ文字 26 字分（最大 430）。標準の文字で 364。木だけのときは 185 以上（GTK は 240 以上、GNOME は 320 以上、最大 560 だった）。
- 木の始点: GTK は (4, 18) に固定していた。今は最初の行の中央。
- 節点の支援技術向けの名前: GNOME は「語・読み・候補番号」を改行で並べていた。今は GTK と同じく名前を「語（読み）」にする。木の語には候補番号を付けない。
