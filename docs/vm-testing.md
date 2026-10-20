# DockerとVMでのテスト

ホストにDocker、Lima 2.2、AppleのSwiftコンパイラが既にあることを前提にします。スクリプトは不足するホストツールを自動インストールしません。macOSゲストとGUIビューアはApple Silicon Mac向けです。

## Dockerの自動テスト

```sh
python3 Tools/fetch-models.py
bash Tools/test-docker.sh --zenzai
```

SwiftのCoreテスト、候補ツリーモデル、実変換器のJSON通信、設定・辞書・学習・AI失敗・プロセス復旧を検証します。さらに隔離D-Bus/Xvfbで実IBusサービスに入力し、確定・プライバシー属性・候補クリックを検証します。ソースはイメージへコピーされ、テストからホストのソースを書き換えません。CPUモデルがロードされたことも検査し、辞書変換へのフォールバックだけで合格させません。

Dockerの仮想画面だけでは、GNOME Shell、Wayland、アプリごとの入力プロトコルの動作は保証できません。その部分は次のデスクトップVMで検証します。

## VMの準備と導入

```sh
bash Tools/vm-test.sh ubuntu create
bash Tools/vm-test.sh ubuntu start
bash Tools/vm-test.sh ubuntu install build/dist/azookey-tree_0.1.0_arm64.deb
bash Tools/vm-test.sh ubuntu test
# 任意: 画面からロック解除する場合、利用者がVM専用パスワードを設定する。
bash Tools/vm-test.sh ubuntu shell sh -c 'sudo passwd "$(id -un)"'
bash Tools/vm-test.sh ubuntu stop
bash Tools/build-vm-viewer.sh ubuntu

bash Tools/vm-test.sh macos create
bash Tools/vm-test.sh macos start
# VMではCPU専用版を使用する。
bash Tools/tree-build.sh 0.1.0 cpu
bash Tools/vm-test.sh macos install build/dist/azookey-tree-0.1.0-arm64-cpu.zip
bash Tools/vm-test.sh macos test
bash Tools/vm-test.sh macos stop
bash Tools/build-vm-viewer.sh macos
```

VMはリポジトリの隣の `azookey-vm` に保存します。`AZOOKEY_VM_HOME` で変更できます。4 CPU・8 GiB、Ubuntuは48 GiB、macOSは64 GiBの仮想ディスクを使います。ホストのホーム・クリップボードを共有しません。LimaのOSダウンロードキャッシュは既定の場所を使います。

`build/VMViewer-ubuntu.app` または `build/VMViewer-macos.app` を開くと同じVMディスクをGUI起動できます。**Lima側を停止してから開いてください。** ビューアとLimaの二重起動は検査で拒否します。ビューアの閉じる操作はゲストへ通常終了を要求します。ゲストが応答しない場合に自動で強制終了はしません。

ビューアはLima同様、仮想ディスクを明示的にcached / fsyncモードで開きます。ディスク・EFI・macOSのハードウェア識別子はLimaと共有します。LimaのmacOSゲスト対応は実験的です。初回のGUIログイン、OSセットアップ・ライセンス確認は利用者が行います。生成されたVMパスワードをログやテスト成果物へ収集しないでください。

Ubuntuはテスト専用ユーザーへ自動ログインしますが、Limaの初期ユーザーには使えるログインパスワードがありません。画面からロック解除したい場合は上記の `passwd` を利用者が実行してください。未設定のままGNOMEが自動ロックした場合も、所有者の許可のもとでゲストへSSH接続し、`loginctl show-user "$(id -un)" -p Display --value` で確認したGUIセッションに `sudo loginctl unlock-session <セッション番号>` を実行すれば、文書を残したまま解除できます。パスワードをログへ出すことや、ロック機能の自動無効化は行いません。

macOS版の `test` コマンドはバンドル署名と版番号の検査までです。GUIで日本語入力が成功したことを示すものではありません。

この作業用の2台については、利用者の明示的な許可を受けて自動ロックを無効にしました。macOS VMは自動ログインのユーザー設定、画面ロック無効、`sleep=0` / `displaysleep=0`を読み戻して確認しています。自動ログインは再起動後の実動作確認が残ります。VM専用の設定で、ホストMacの認証設定は変更していません。これらを他のVMへ自動適用するスクリプトは追加していません。

### macOS VMの変換速度

通常のMac向けビルドは上流のMetal対応を維持します。VM向けの `cpu` ビルドは同じモデルをCPU専用で実行し、別名のzipへ出力します。両者は同じ入力方式IDを使うため、同時には導入しません。CPU版のアプリテストは `AZOOKEY_INFERENCE_BACKEND=cpu bash Tools/test-macos-app.sh` で実行できます。

macOS 26.5.2・4 vCPU・8 GiBの検証VMでは、Metal対応版とCPU専用版を比較し、初回の変換器処理の最大値が約2.2秒から約69ms、新しい文章の各キー処理の中央値が約110msから約29msになりました。ローカルの診断ビルドによる短い測定で、GUI描画・入力待ち時間は含みません。同文の再入力はキャッシュが効くため、新しい文章でも測定してください。ホストの負荷やVM環境で変わり、実機MacでCPU版が速いことを示す結果ではありません。

候補UIは番号だけの変更で木を作り直さず、画面外のボタンを必要になるまで生成しません。208ノードの文章で候補ウィンドウの更新処理は約287msから約31msに短縮しました。これはアプリ内の処理時間で、画面転送やディスプレイへの描画完了までの遅延は含みません。

## GUIの受け入れ項目

各VMで入力ソースにazooKeyを追加して確認します。Ubuntu WaylandはGNOME拡張も有効にします。

1. 「nihongo」「kyouhaiitenkidesu」の入力、変換、Enterと数字での確定。
2. ツリーの枝・選択経路・操作対象の下線、上段の横並びと下段2つまでの代替、長い文の横スクロール、画面端への配置。未学習の文と学習後の同じ文を両方確認する。
3. 枝と番号のクリック後に元の入力欄へ続けて入力できること。
4. 矢印、Shift＋左右、Escape、Backspace、英数／かな切替、無変換2回。
5. アプリ切替、パスワード、PRIVATE欄、辞書登録、学習リセット、設定の即時反映。
6. macOSはTextEditとブラウザ、UbuntuはGTK・Qt・Chromiumの入力欄とX11を確認。

UbuntuのQt/QtWebEngine用のローカル入力欄は `Tools/tests/qt-editor.py` です。`Tools/tests/fixture_events.py`、`Tools/tests/fixture_reset.py` と一緒にVMのホームなど再起動で消えない場所へコピーし、VM内のPyQt6とQtWebEngineで実行します。外部サイトにはアクセスしません。

Safariなど通常のブラウザでは `Tools/tests/ime-editor.html` をVMにコピーして開きます。入力中／確定済みの状態とフォーカス、入力結果をページ内に表示します。通信・保存は行いません。候補の番号クリック後に `a` を入力して確定し、全文に「あ」が続くこと、`Composing: false` と `Focused: true` を確認してください。

テストスクリプトはホストのATOK削除・入力ソース切替・ログアウトを行いません。VMで確認してからホスト導入へ進みます。


### 固定の入力欄の結果を記録する

GTK用の`Tools/tests/gtk-editor.py`とQt/QtWebEngine用の`Tools/tests/qt-editor.py`は、2つの入力欄を持ちます。`fixture_events.py`、`fixture_reset.py` を同じ場所へ置き、`--output /home/azookey/ux-gui/state.json`を付けると、その画面内の確定文字列・カーソル位置・フォーカスをJSONへ記録します。Qt版はQtの版と表示方式、QtWebEngine欄の選択範囲も記録します。外部サイトや他のアプリの本文は読みません。

`--events /home/azookey/ux-gui/trial-events.jsonl` を追加すると、GTKの挿入・削除、Qtのnative input-methodイベント、状態の時系列を記録します。既存のログへ試行を混ぜないため、新しいファイル名を使ってください。AI結果の元欄への適用・別欄への誤適用・Resetの検証は、[ローカルmockを使う手順](linux-ai-gui-validation.md)を参照してください。

候補クリック後の追加入力、欄を切り替えたときの誤確定、重複確定を、画面とJSONの両方で確認してください。ここで得たJSONだけでは、候補の見やすさや読み上げの合格とは判定できません。録画やログに残す入力は固定の検証文に限ります。
