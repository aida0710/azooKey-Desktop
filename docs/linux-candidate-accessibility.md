# Linux候補の読み上げと支援技術からの確定

文書の入力フォーカスを保ったまま、選択した候補の表記・読み・候補位置を通知します。語を左右へ移すと語位置と確定予定の全文、部分確定では残る読みも通知します。相対スコアや長い注釈は候補の名前へ混ぜず、詳細説明へ分けます。同じ文脈・同じ選択内容の再描画では通知を繰り返しません。

通知の文、候補と語の支援技術向けの名前・説明は Core が `candidateDisplay`（`announcement`、`nodes[].accessibleName` など）として作ります。形式は[候補表示の共通形式](candidate-display.md)にあります。各OSは、同じ入力欄で直前と違う文のときだけ通知します。

GTKツリー、GNOMEツリー、通常IBus候補の各表示経路から、標準の `Atk.Object::notification` を `POLITE` で送ります。[この通知はATK 2.50以降の機能](https://gnome.pages.gitlab.gnome.org/gtk/atk/signal.Object.notification.html)で、対象のUbuntu 24.04はATK 2.52を使用します。Orca 46の実環境では、文書以外の候補の名前・checked状態を変えるだけでは候補選択が読み上げられなかったため、この通知を追加しました。

## GNOMEの遅れて実行される操作

GNOME 46の `St.Button` には候補確定用のAT actionを明示的に登録します。通常のクリックと同じ選択処理へ渡し、候補をTab移動の対象にはしません。

[Mutter 46のCally実装](https://github.com/GNOME/mutter/blob/46.0/clutter/clutter/cally/cally-actor.c)は、`do_action` を受けた時点で操作をキューへ置き、後のidle処理でcallbackを呼びます。そこで、context・世代・選択・ページが変わったボタンを新しい対象へ使い回さず、破棄時にcallbackを無効にします。Hideから同じ候補を再表示する場合も、古い操作を復活させません。位置やテーマだけの更新はボタンを維持します。

待機中のactionを `remove_action` で消すと、Callyのキューが参照するaction情報を先に解放してしまいます。登録情報の解放はCallyに任せ、callbackでは元のactorが有効・表示中・操作可能かを確認します。

## 回帰試験と実Orcaの確認

通知の文の組み立ては Core の Swift 試験（`Core/Tests/CoreTests/DesktopCandidatesTests`）で確認します。通知の時機と状態遷移は次で確認できます。どちらも Swift のブリッジ（`AZOOKEY_BRIDGE`）から表示を受け取ります。

```sh
swift test --package-path Core --filter CandidateDisplayTests
export AZOOKEY_BRIDGE="$(swift build --package-path Core --show-bin-path)/azookey-desktop-bridge"
python3 -m unittest Linux.tests.test_candidate_announcements -v
gjs -m Linux/tests/candidate_announcements_gjs.js
gjs -m Linux/tests/candidate_navigation_actions_gjs.js
GDK_BACKEND=x11 GSETTINGS_BACKEND=memory xvfb-run -a \
  python3 -m unittest Linux.tests.test_candidate_announcements -v
```

GTK試験は通知、入力欄のfocus参照、native AT actionを確認します。GJS試験は製品のナビゲーションを読み、Callyの待ち行列を模擬します。これらを実Orcaの読み上げやIBus経由の文書確定の合格に置き換えません。

`Linux/tests/candidate_native_actions_probe.js` は、専用VMのGNOME拡張から `probeNativeActions(CandidateNavigation, Main.layoutManager, report)` を呼ぶ手動検証用です。native AccessibleのSHOWINGを待ち、実際の `do_action` とidle処理の間にページ更新・選択更新・Hide・context変更を挟みます。呼び出しは製品拡張に組み込まず、専用VMでの確認後に除去します。このprobe単体は文書のフォーカスや確定を検査しません。

同表記異読を表示経路だけで再現するには、実デスクトップのOrcaを起動し、次のfixtureを実行します。候補は明示した固定試験データで、変換器の出力ではありません。表示と配置は Core が決めるため、`AZOOKEY_BRIDGE` にブリッジの実行ファイルを指定します（配布物では `/opt/azookey-tree/libexec/azookey-desktop-bridge`。同じディレクトリを `LD_LIBRARY_PATH` に含める）。F6で開き、上下で「日本」の読みを切り替え、左右で語移動、Enterで確定します。通常のIBusを使う実アプリ試験は別に行います。

```sh
AZOOKEY_BRIDGE=/opt/azookey-tree/libexec/azookey-desktop-bridge LD_LIBRARY_PATH=/opt/azookey-tree/libexec \
  GDK_BACKEND=x11 python3 Linux/tests/gtk_orca_fixture.py --output reading-fixture.jsonl
```

実Orca試験は[配布物ごとの検証手順](ux-validation.md)に従い、候補を開く、上下左右、EnterまたはAT activate、一度確定、元欄への追加入力、同表記異読、横スクロール、ツリーOFFを確認します。Orcaの実 `SPEECH OUTPUT`、AT-SPIイベント、文書本文とactive window、配布物・ソースSHAを同じ試行に結び付けます。発話ログの確認と、出力音声を実際に聞いた確認は分けます。開発ソースの差し替え試験は最終配布物の合格ではありません。

専用VMでもprivate D-Bus/Xvfbの試験には固有の0700 `XDG_RUNTIME_DIR` を使い、実GNOMEのAT-SPI runtimeを共有しません。実デスクトップのOrca起動には既存のセッション環境を継承し、X11の認証を無効化しません。
