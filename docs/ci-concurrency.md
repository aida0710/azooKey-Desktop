# CI の重複実行

`swift.yml` と `tree-ci.yml` は、同じ workflow・イベント・完全な ref の
新しい実行が届いたとき、先行する実行を `concurrency` で取り消す。
push と PR は別のグループに置き、遅れて届いた push が PR のマージ結果の検査を
取り消さないようにする。

| イベント | グループ内で置き換える範囲 | 既存の検査ジョブ |
| --- | --- | --- |
| branch の push | 同じ branch の push | 下記の条件を満たす場合だけ PR に任せる |
| pull_request | 同じ PR 番号の実行 | すべて実行 |
| tag の push | 同じ tag の push | すべて実行 |
| workflow_dispatch | 同じ ref の手動実行 | すべて実行 |

PR 番号を含む `github.ref` を使うため、別の fork の同名 branch から作られた
PR は互いを取り消さない。branch と tag も完全な ref で分かれる。
グループはリポジトリ内で有効で、別の workflow とも名前で分かれる。
GitHub のグループ比較は大文字小文字を区別しないため、大小文字だけが異なる
branch 名の検査を互いに独立して扱うことはできない。

## push の重複判定

最初の `select-checks` ジョブは読み取り専用で PR を調べる。
`Tools/ci/should-run-checks.cjs` が次をすべて確認できた場合だけ、push の
後続ジョブを省略する。

- PR が開いている。
- PR の head が push と同じリポジトリ・branch・コミットである。
- PR の詳細を再取得しても条件が変わらず、`mergeable` が `true` である。

API の失敗、権限不足、競合、未計算の `mergeable`、別のコミットは検査を実行する。
競合した PR では `pull_request` の workflow が起動しないため、
PR の存在だけを理由に push を省略しない。PR と手動実行はこの照会を行わない。
元のビルド・テスト・lint の手順、runner、matrix、起動条件は維持する。

PR 作成前に始まった push は、そのまま完了する場合がある。この変更前に作られた
実行も遡って取り消さない。GitHub は同じグループ内のイベント順序を保証しないため、
古い実行の手動再実行で必ず最新コミットが優先されるとは扱わない。

## 確認

```sh
node --test Tools/tests/ci-should-run-checks.test.cjs
```

9 回帰で、通常の push、同じ head の PR、fork、変更された head、競合、
API の失敗、tag、手動実行を確認する。workflow の式は actionlint で検査できる。
既存の Xcode 選択スクリプトには SC2012 が 2 件あり、この変更では維持している。

## 参照

- [GitHub Actions の concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
- [github.ref の定義](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#github-context)
- [競合した PR の起動条件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request)
- [PR の取得と mergeable](https://docs.github.com/en/rest/pulls/pulls#get-a-pull-request)
