# 候補の配色とOSテーマ

候補の選択は淡い紫の背景と枠で示す。明色と暗色で本文・補助文字の階層を揃え、高コントラスト設定では白黒を基調にする。選択中の経路は太い実線、他の経路は細い破線にし、操作対象には下線を加える。スコアの橙・青は数値の小さな背景にだけ使い、選択状態とは分ける。評価のない候補は灰色の「—」とし、既存の75という色の切り替え値や計算方法は変更しない。どの色を使うかは Core が `scorePresentation.role`（配色の役割名）で決め、各OSはその役割の色を塗るだけにする（[候補表示の共通形式](candidate-display.md)）。

配色の変更は候補の元の識別子や確定範囲を変えない。非フォーカスの候補ウィンドウと文字サイズ設定を維持し、テーマの変更で候補を再生成したり、アプリに文字を確定したりしない。候補UIの再設計では、クリックによる選択と、確定ボタンまたはEnterによる確定を分ける。

## テーマの取得

- GTKは`gtk-theme-name`、`gtk-application-prefer-dark-theme`とスタイル変更を監視する。GNOMEの設定スキーマがある場合は`color-scheme`と`high-contrast`も監視する。他のデスクトップではGTKのテーマ名と背景から判断する。GTKの暗色指定は[GtkSettingsの公式仕様](https://docs.gtk.org/gtk3/property.Settings.gtk-application-prefer-dark-theme.html)に従う。
- GNOME Shellは`org.gnome.desktop.interface`の`color-scheme`と`gtk-theme`、`org.gnome.desktop.a11y.interface`の`high-contrast`を監視する。スキーマは[GNOMEの公式ソース](https://github.com/GNOME/gsettings-desktop-schemas)で定義されている。GNOME 46で利用できる設定を使う。
- macOSはビューの`effectiveAppearance`と`NSWorkspace.accessibilityDisplayShouldIncreaseContrast`を使う。外観が変わったときと、[表示アクセシビリティ設定の変更通知](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification)で再描画する。通知の監視先は`NSWorkspace.shared.notificationCenter`。

## 配色の正本と測定

`Shared/CandidatePalettes.json`に不透明なsRGB値を置く。`python3 Tools/generate-candidate-palettes.py`でPython・GJS・AppKitのデータを生成し、生成済みファイルもコミットする。実行時の外部資産参照を避け、配布パッケージに色定義が欠ける経路を作らない。`--check`で正本との一致を検査できる。

文字の設計目標には[W3Cの通常文字4.5:1](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)を参考にする。ネイティブIMEのWCAG適合を主張するものではない。[色だけで区別しないという考え方](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html)から、枠・線の太さ・破線・下線を併用する。

以下は正本のsRGB値から相対輝度を計算した比率。文字のアンチエイリアス画素から逆算した数値ではない。

| 外観 | 通常文字 / 背景 | 選択文字 / 背景 | スコア文字 / 橙 | スコア文字 / 青 | 未評価文字 / 背景 |
|---|---:|---:|---:|---:|---:|
| 明色 | 15.271 | 11.081 | 6.461 | 6.611 | 6.329 |
| 暗色 | 14.355 | 10.624 | 6.461 | 6.611 | 6.329 |
| 明色・高コントラスト | 21.000 | 21.000 | 9.944 | 10.610 | 9.588 |
| 暗色・高コントラスト | 21.000 | 21.000 | 15.515 | 14.766 | 15.609 |

代替候補の背景、補助文字も含む全8組を回帰試験で計算する。Macの試験は実`NSColor`をsRGBへ変換して計算するため、LinuxでのJSON値の計算とは分けて結果を記録する。

## 検証

Ubuntu 24.04の専用VMで、GTK候補・全文詳細・ATKの既存回帰と、4外観の切替・実描画色・詳細欄の2行目が見えること・候補操作の同一性を検査する。GJSは実GSettingsのmemory backendで4外観の通知と監視解除を確認する。memory backendは稼働中デスクトップの設定を変えないために使う。

```sh
GDK_BACKEND=x11 GSETTINGS_BACKEND=memory AZOOKEY_BRIDGE=/path/to/bridge \
  dbus-run-session -- xvfb-run -a python3 -m unittest \
  Linux.tests.test_candidate_theme Linux.tests.test_tree_panel \
  Linux.tests.test_candidate_accessibility Linux.tests.test_candidate_details -v
GSETTINGS_BACKEND=memory gjs -m Linux/tests/candidate_theme_gjs.js
```

`AZOOKEY_TREE_SNAPSHOT_DIR`を指定するとGTKの4外観とsRGB測定JSONを保存する。AppKitの既存描画試験も4外観を保存する。GTKではスクロール領域内の装飾ノードに背景を塗ると本文を隠すため、CSSはviewportとlabelに限定し、画面上の読みの文字画素も検査する。

GNOME Shellの実画面、macOSの実AppKit試験とIME実アプリ、Orca/VoiceOver、拡大率・ディスプレイ色設定を含む最終確認は別途記録する。GJSの通知試験だけでGNOMEの描画完了とはしない。
