# 候補表示の共通形式（Core が決めて各OSが描く）

候補ウィンドウに「何を出すか」と「どこに置くか」は Core（`Core/Sources/Core/Desktop/Candidates`）が決めます。各OSに残すのは、入力の仕組みへのつなぎ、文字の測定、描画、OS の座標の換算だけです。macOS は Core を直接使い、Linux（GTK・GNOME）と Windows はブリッジ（`azookey-desktop-bridge` の JSONL）を使います。

| 決めること | 置き場所 | ブリッジでの受け取り方 |
| --- | --- | --- |
| 木と一覧のどちらを出すか、描く列、節点の番号（1〜9）、読み上げ文、詳細文、確定ボタンの文言と可否、前後ページ、残る読み | `CandidateDisplay` | すべての応答の `candidateDisplay` |
| 相対スコアの色の区分 | `CandidateScoreRole` | `nodes[].scorePresentation.role` |
| 節点の枠、行の高さ、列の幅、文書の語への整列、ポップアップの幅、配置と向き | `CandidateLayout`、`CandidateTreeLayout`、`CandidatePopupPlacement` | `candidate-layout` 操作 |
| 文字の大きさ（標準 18、大きい 24、OS の文字倍率が 1 未満なら縮めない） | `CandidateTextMetrics` | `candidate-layout` の `tree.metrics` |

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
  "showsNumbers": true,
  "baseFontSize": 18,
  "detailNode": 1,
  "expandTree": false,
  "announcement": "変換候補 2 / 56。にほん。読み ニホン。語 1 / 2。確定予定 にほんご",
  "nodes": [
    {"id": 1, "number": 2, "selected": true, "focused": true,
     "accessibleName": "にほん（ニホン）",
     "accessibleDescription": "操作対象。押すと候補を選択\n確定予定: にほんご\n…\n候補番号 2",
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
| `showsNumbers` | 番号の付いた節点が1つでもある。全節点の行の高さに番号の行を含める |
| `baseFontSize` | 文字倍率をかける前の候補の文字の大きさ。`candidate-layout` の `textWidth` はこの大きさで測ると正確 |
| `nodes` | `columns` に出る節点だけ。`number` は、その節点を選んだときに選ばれる候補（`preview.candidateIndex`）が今のページにあるときの 1〜9。`tree` では常に、`list` では数字キーが使える `selecting` のときだけ付く |
| `detailNode` | ポインターが何も指していないときに詳細を出す節点（操作対象の語、無ければ最初の語） |
| `expandTree` | 同じ候補のまま操作対象の語だけが動いた応答で `true`。木を開いて対象を見せる。同じ応答を描き直すときは1回だけ扱う（GTK・GNOME は `contextId` と `generation` で判断している） |
| `announcement` | 変換中に選択か操作対象が変わったときに読み上げる文。打鍵中は `null`。同じ入力欄で直前と同じ文なら読み上げない |
| `list` | 全文候補の一覧。候補が無く選択も無いときは `null`。`tree` のときも、一覧を開けるように付く（見出しは「候補のプレビュー」、確定ボタンは「この候補を確定」） |
| `list.confirmIndex` | 確定ボタンで確定する候補。`select` 操作に `submit: true` で渡す。`null` なら確定ボタンを無効にする |
| `list.previousIndex`・`nextIndex` | 前後のページへ移るときに `select`（`submit: false`）で選ぶ候補。`null` ならボタンを無効にする |

「一覧」「閉じる」「前へ」「次へ」「文節を調整」「詳細を表示」「選択中」など、状態で変わらないボタンの文言は今のところ各OSの文言を使います（文言の共通化は別の作業で行います）。

## `scorePresentation.role`

相対スコアを出す設定のとき、描く節点の `scorePresentation` に `label`・`role`・`detailDescription` が付きます。`role` は `Shared/CandidatePalettes.json` の役割名（`scoreLow`・`scoreHigh`・`scoreUnknown`）で、バッジの背景色にその役割の色を使います。75 未満が `scoreLow` です。

## `candidate-layout` 操作

各OSは自分のフォントで文字を測り、作業領域とカーソルを渡します。Core は節点の枠とポップアップの幅、`popupHeight` があれば配置まで返します。入力の状態を持たない操作なので、`context` は要りません。

```json
{"operation": "candidate-layout", "layout": {
  "mode": "tree", "textSize": "standard", "textScale": 1, "measuredFontSize": 18,
  "columns": [{"nodes": [{"id": 0, "parent": null}, {"id": 1, "parent": null}, {"id": 3, "parent": null}],
               "textWidth": 54.0}],
  "lineHeight": null, "documentWordWidths": null, "columnAnchorX": null,
  "showScores": true, "showNumbers": true,
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
| `lineHeight` | 任意。1行の高さを測った値。共通の高さ（文字 + 14）より高いフォントのときだけ効く |
| `documentWordWidths` | 任意。文書上の語の幅が分かるとき（GTK の推定語幅、Windows の文字矩形）。全列の幅が揃い、どれも読める幅のときだけ整列する |
| `columnAnchorX` | 任意。整列するときの文頭の x |
| `showScores`・`showNumbers` | スコアの行・番号の行を確保するか（`showRelativeScores` と `candidateDisplay.showsNumbers`） |
| `cursor` | 実際のキャレット。ポップアップはこれを覆わない |
| `workArea` | カーソルのあるモニターの作業領域 |
| `popupHeight` | 任意。返った `popupWidth` で測ったポップアップ全体の高さ。あるときだけ配置を返す |
| `preferredSide` | 任意。前回の向き。まだ入るならその向きを保つ |

応答（`candidateLayout`、配列は先頭だけ示す）:

```json
{"popupWidth": 240, "placementStatus": "placed",
 "placement": {"x": 300, "y": 224, "width": 240, "height": 180, "side": "below"},
 "tree": {
   "aligned": false, "reason": "unavailable-or-narrow", "textAlignment": "center", "rowHeight": 66,
   "metrics": {"fontSize": 18, "numberFontSize": 12, "scoreFontSize": 12,
               "wordHeight": 32, "numberHeight": 18, "scoreHeight": 16},
   "nodes": [{"id": 0, "column": 0, "row": 0,
              "frame": {"x": 12, "y": 6, "width": 66, "height": 66},
              "textFrame": {"x": 16, "y": 6, "width": 58, "height": 32},
              "scoreFrame": {"x": 12, "y": 38, "width": 66, "height": 16},
              "numberFrame": {"x": 18, "y": 54, "width": 54, "height": 18}}],
   "edges": [{"node": 0, "start": {"x": 4, "y": 39}, "end": {"x": 12, "y": 39}}],
   "rootAnchor": {"x": 4, "y": 39},
   "contentSize": {"width": 90, "height": 216}}}
```

| 出力 | 意味 |
| --- | --- |
| `tree.nodes[].frame` | 押せる範囲（ポインターと支援技術の対象）。番号とスコアの行を含む |
| `textFrame` | 語を描く範囲。`textAlignment` が `leading` なら左寄せ、`center` なら中央。はみ出す語は末尾を省略する |
| `scoreFrame` | スコアのバッジを描く行。バッジは幅 22 以上、文字の幅 + 6 で中央に置く |
| `numberFrame` | 番号を左寄せで描く行 |
| `edges` | 親から子へ線を引く。`start` は親の右端の中央、親が描かれていない節点は `rootAnchor` から。線は `node` が選択中の文の語なら太く実線、ほかは細い点線 |
| `contentSize` | 木を描く面の大きさ。ポップアップより大きいときはスクロールする |
| `aligned`・`reason` | 文書の語の下に列を揃えたか。`estimated-inline`（揃えた）、`unavailable-or-narrow`（語の幅が無いか狭い）、`outside-workarea`（画面内に収まらない、または横に置いた） |
| `popupWidth` | ポップアップの幅。木だけなら 240 以上、一覧なら 420 以上かつ文字 26 字分（最大 560）以上、揃えないときは 760 以下、作業領域の幅以下 |
| `placementStatus` | `notRequested`（`popupHeight` が無い）、`placed`、`unavailable`（キャレットが作業領域を覆い、置ける場所が無い。ポップアップを隠す） |
| `placement` | ポップアップの左上と大きさ、向き（`below`・`above`・`right`・`left`）。下、上、右、左の順に入る向きを選ぶ。どれにも入らないときは上下の広い方へ高さを縮め、上下に余地が無ければ左右の広い方へ幅を縮める |

### 呼び出しの手順

1. `candidateDisplay.columns` の各列の先頭の語を `baseFontSize` で測り、`popupHeight` なしで呼ぶ。
2. 返った `tree` の枠で木を描き、`popupWidth` の幅で一覧などを並べてポップアップ全体の高さを測る。
3. 同じ入力に `popupHeight` を足してもう一度呼び、`placement` の位置に出す（木だけでほかに何も無いなら、1回目から `popupHeight` を付けてよい）。
4. 2回目の `popupWidth` が測った幅と違うとき（揃えた列が横に置かれて整列をやめたとき）は、その幅で測り直して3をやり直す。
5. カーソルや作業領域だけが変わったときは、測った高さを使って3だけを行う。

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
- 列の幅: GNOME は文字の幅 + 24（最大 280）、行の高さは測った値だった。今は GTK と同じく文字の幅 + 12（最大 240、最小は 44 と文字 + 8 の大きい方）、行の高さは文字 + 14（測った `lineHeight` が高ければそれ）。スコアのバッジは GNOME でも節点の中に置く。
- ポップアップの幅: 一覧のときは、GTK の 420 以上と GNOME の文字 26 字分（最大 560）の両方を満たす幅にした。標準の文字で 468。
- 木の始点: GTK は (4, 18) に固定していた。今は最初の行の中央。
- 節点の支援技術向けの名前: GNOME は「語・読み・候補番号」を改行で並べていた。今は GTK と同じく名前を「語（読み）」、候補番号は説明に入れる。
