# 学習済みの全文候補

学習後の候補をエンジンが一語として返した場合、漢字文・固有名詞・英数字を含む文は一枠のまま表示します。別の候補の語をつなぎ直したり、追加の変換要求で見かけの語境界を作ったりしません。詳細表示には、その枠を選んだときの全文・消費する読み・残る読みを出し、確定には元の候補番号を使います。

## 語境界を復元しない理由

固定している変換エンジン `04ce2ec3afe2bd6f92fcae1dc15a2357d332c27a` の [`Candidate.data`](https://github.com/azooKey/AzooKeyKanaKanjiConverter/blob/04ce2ec3afe2bd6f92fcae1dc15a2357d332c27a/Sources/KanaKanjiConverterModule/ConverterAPI/Candidate.swift) は、今回の候補を構成する辞書項目の列です。[学習処理](https://github.com/azooKey/AzooKeyKanaKanjiConverter/blob/04ce2ec3afe2bd6f92fcae1dc15a2357d332c27a/Sources/KanaKanjiConverterModule/DictionaryManagement/LearningMemory.swift) は、確定した全文の表記と読みを連結した一つの `DicdataElement` も保存します。この項目から候補が作られた場合、学習前の語境界は返却 API にありません。

元の境界が必要になれば、学習レコードと候補 API の双方に境界情報を保存する上流側の機能が必要です。この変更では学習ファイルの形式を変えず、取得できない Zenzai の補正履歴も表示しません。

例外は全文かな・カナ候補です。同じ返却候補群に複数語の解析があり、かなの文字構成と消費入力数が一致する場合だけ、その読み境界を表示に使います。消費入力数が不明・不一致なら分割しません。語を連結した文字列は元の候補と厳密に一致させます。NFC/NFD のように見た目が同じでも文字構成が違う候補や読みは、別の表示ノードとして保持します。

## 回帰 fixture

`Linux/tests/fixtures/learned_candidates.json` は合成の固定入力です。各例を独立した設定・学習先で実行し、未学習、直前に確定した後、新しい bridge プロセスで再起動した後の三段階を比較します。候補全文・表示語の連結・読み・消費範囲・全文プレビュー・候補番号を確認し、表示ノードを経由して元の全文が一度だけ確定されることを検査します。

2026-10-20、Ubuntu 24.04 amd64 / Swift 6.2.4、通常の変換モデルで確認した語数は次のとおりです。

| 確定全文 | 未学習 | 学習後 | 再起動後 |
|---|---:|---:|---:|
| 私は日本語を勉強しています | 4 | 4 | 4 |
| 橋を渡る | 3 | 1 | 1 |
| 橋 | 1 | 1 | 1 |
| 箸 | 1 | 1 | 1 |
| 東京駅 | 1 | 1 | 1 |
| azooKey Treeで日本語を入力する（読み: ちょうぶんじしょ） | 1 | 1 | 1 |
| かなABC123（読み: こんごう） | 1 | 1 | 1 |

21 回すべてで候補と確定文字列が一致しました。以前の VM で「私は日本語を勉強しています」が四枠から一枠になった記録は、今回の通常モデルでは再現していません。「橋を渡る」で一枠化を再現しています。Zenzai 有効時の語数は固定せず、同じ文字保持の検査を実行します。

## 再実行と処理時間

ビルド済み bridge を指定して次を実行します。ホストへの依存追加を避ける場合は、既存の Ubuntu 用 Docker 環境内で実行してください。

```bash
export AZOOKEY_BRIDGE="$PWD/Core/.build/debug/azookey-desktop-bridge"
export AZOOKEY_LEARNED_CANDIDATE_REPORT="$PWD/build/learned-candidates.json"
mkdir -p build
python3 -m unittest Linux.tests.test_learned_candidates -v
bash Tools/benchmark-candidate-tree.sh build/learned-candidates.json 1000
```

時間計測は実際に得られた 21 組の候補を入力に、最適化した `CandidateTree` の構築と列選択だけを繰り返します。各組 10 回の準備実行後、1,000 回の中央値と 95 パーセンタイルを JSON に出します。変換器をリンクしないため再解析は 0 回であり、この変更による再解析時間は 0 です。キー入力・辞書検索・プロセス起動を含む bridge の `conversionSeconds` は別の測定値として残し、表示モデルだけの時間と混同しません。

R540 の専用 Docker（2 CPU / 6 GiB）で、基点 `2a2e181` と修正後を同じ候補集合で比較しました。67〜295 候補を持つ 21 組で、最も大きい中央値は 2.118 ms → 1.222 ms、最も大きい 95 パーセンタイルは 2.308 ms → 1.313 ms でした。測定した範囲では表示モデルの時間増加はありません。共有サーバー上の測定であり、全機種や GUI 全体の応答時間を保証する値ではありません。

実アプリのクリック、候補の非フォーカス、VoiceOver/Orca の読み上げ、Zenzai 有効パッケージの VM 確認は別の受入項目です。ここに記した Core と bridge の検査だけで、それらが完了したとは扱いません。
