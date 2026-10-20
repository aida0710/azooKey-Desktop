# Linux候補ウィンドウの座標単位

GTK fallbackの候補位置は、IBusの座標をGTKの論理ピクセルへ変換してから計算します。画面内に収まることと、実キャレットを覆わないことを同じ単位で確認します。

## X11の境界

IBusのGTKクライアントは、ルート座標へ変換したキャレットのx/y/幅/高さをwindow scale倍して送ります。したがって、このX11通知は物理ピクセルです。[IBus 1.5.29のGTKクライアント](https://github.com/ibus/ibus/blob/1.5.29/client/gtk2/ibusimcontext.c#L1474-L1573)

GDKのmonitor座標は論理ピクセルです。GTK 3のX11実装は、画面全体の`window_scale`でmonitorの原点・寸法とworkareaを除算します。monitorを選ぶ前にキャレットの全体座標も同じ倍率で変換します。[Gdk.Monitor.get_geometry](https://docs.gtk.org/gdk3/method.Monitor.get_geometry.html)、[GTK 3.24.41のX11 screen実装](https://github.com/GNOME/gtk/blob/3.24.41/gdk/x11/gdkscreen-x11.c)

`TreePanel`は現在のGTK window scaleを使い、実キャレット、文頭のx座標、推定語幅を変換します。端数のあるキャレット矩形は外側へ丸め、幅0の挿入位置も配置処理で1論理ピクセルを除外します。表示倍率を2と決め打ちしません。

`Engine`、`PreeditAnchor`、GNOMEへ送るsnapshotと位置は元の値を保持します。推定できなかった語境界は引き続きコンパクト表示になります。GTKで安全に配置できたことを、本文の文字境界が正確に取得できた証拠にはしません。

## 別rendererと診断

GNOME拡張は`ShellCursor`でpanel serviceの通知を優先し、Waylandの相対矩形は対象windowに基づいて解決します。GTK fallbackの変換をこの経路へ適用しません。WaylandでGTK候補を使わない既存の分岐も維持します。

GTKの`DescribeLayout`は、`cursor` / `workArea` / `popup`を`coordinateSpace: gtk-logical`として返します。受信した元の矩形は`ibusCursor`、適用した倍率は`ibusCoordinateScale`です。物理スクリーンショットとの比較時は、GTKの矩形を倍率倍してからIBusの物理矩形と比較します。

表示構成変更後は、見えている候補を現在の倍率・workareaで再配置します。変換待ちで隠した候補は、画面の変更だけでは復帰させません。

## 検査範囲

`Tools/test-linux.sh`は通常倍率の候補回帰に加え、`GDK_SCALE=2`、物理1920×1080のXvfbで`Linux.tests.test_candidate_scaling`を実行します。実GTKの割当サイズ、キャレット非重複、標準/大きい文字、語幅の単位、候補選択と明示確定1回、focus保持を確認します。

負の原点と別monitorの選択はモデルによる回帰、非X11を除算しないことはadapterの回帰です。これらは実複数画面やWaylandのGUI受入ではありません。修正後の配布物を導入した実VM、150%を提供する環境、異なるアプリと画面構成の検査は別に記録します。
