# 候補が入力欄から離れるときの確認

開発・検証担当向けの手順です。まず配布物のcommit、OS、アプリ、表示倍率を記録し、該当するOSの診断を取得してください。画面の確認項目は末尾にあります。

## WaylandではGNOMEが受け取る座標を使う

Ubuntu 24.04のGNOME 46では、Waylandアプリのカーソル座標がエンジンへ届かず、候補が左上に出る場合がありました。拡張はGNOMEのIBus panel serviceから相対座標を受け取り、実際のウィンドウ位置を加えて表示します。ウィンドウを動かしたときも位置を更新します。

これはカーソルに合わせた配置です。文字ごとの境界を取得したことにはなりません。相対座標しかない場合は、本文への語単位の整列を使いません。GNOME 46への依存は `shellCursor.js` に分離しています。[GNOMEの座標処理](https://gitlab.gnome.org/GNOME/gnome-shell/-/blob/gnome-46/js/ui/ibusCandidatePopup.js)と同じ座標系を使います。

候補が出ている間に、同じデスクトップセッションの端末で実行します。

```sh
gdbus call --session --dest org.gnome.Shell \
  --object-path /org/azookey/Tree/Renderer \
  --method org.azookey.Tree.Renderer.DescribeLayout
```

GTKの候補ウィンドウを使うX11環境では、次を使います。

```sh
gdbus call --session --dest org.azookey.Tree \
  --object-path /org/azookey/Tree \
  --method org.azookey.Tree.DescribeLayout
```

戻り値は配置方式、固定の理由コード、カーソル・候補・作業領域の矩形です。候補、読み、周辺文書、入力欄の識別子は含みません。候補を閉じると診断値も消去します。

## macOSでは文字境界が使えない理由を確認する

起動環境に `AZOOKEY_LAYOUT_DIAGNOSTICS=1` を設定した検証ビルドは、Consoleのsubsystem `org.azookey.Tree`、category `candidate-layout` に座標と理由だけを出力します。通常起動では記録しません。

`client-rectangles` はクライアントの文字境界を使った配置です。`client-rectangles-unavailable` は座標欠損、折返し、縦書きなどで使えない状態です。`column-too-narrow` は文字サイズを保てない幅、`outside-workarea` は詳細欄を含めると画面内に収まらない配置を表します。いずれも読みやすいコンパクト配置へ戻します。

## 同じパッケージで画面と確定結果を残す

GTK・Qt・Chromium、macOSのTextEdit・Safari・Chromiumで、単一行、英数字、絵文字、長文、折返しを確認します。画面四辺、ウィンドウ移動、複数画面、100/150/200%表示を分けて記録してください。候補をクリックした後に同じ入力欄へ追加入力し、フォーカスと本文の一致も確認します。

画面外へはみ出す列は本文への整列を解除します。候補数が多いときは、表示領域内のスクロールで選択中の候補に到達できることを確認してください。座標の単体試験は実アプリの合格を代替しません。実機が使えなかった条件は未確認として残します。

問題が残る場合は、診断値と検証用の画面を[このフォークのIssue](https://github.com/aida0710/azooKey-Desktop/issues)へ添えます。日常の文書を撮影せず、検証用の固定文で再現してください。

更新: 2026-10-20。
