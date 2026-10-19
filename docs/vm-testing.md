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
bash Tools/vm-test.sh ubuntu stop
bash Tools/build-vm-viewer.sh ubuntu

bash Tools/vm-test.sh macos create
bash Tools/vm-test.sh macos start
bash Tools/vm-test.sh macos install build/dist/azookey-tree-0.1.0-arm64.zip
bash Tools/vm-test.sh macos test
bash Tools/vm-test.sh macos stop
bash Tools/build-vm-viewer.sh macos
```

VMはリポジトリの隣の `azookey-vm` に保存します。`AZOOKEY_VM_HOME` で変更できます。4 CPU・8 GiB、Ubuntuは48 GiB、macOSは64 GiBの仮想ディスクを使います。ホストのホーム・クリップボードを共有しません。LimaのOSダウンロードキャッシュは既定の場所を使います。

`build/VMViewer-ubuntu.app` または `build/VMViewer-macos.app` を開くと同じVMディスクをGUI起動できます。**Lima側を停止してから開いてください。** ビューアとLimaの二重起動は検査で拒否します。ビューアの閉じる操作はゲストへ通常終了を要求します。ゲストが応答しない場合に自動で強制終了はしません。

ビューアはLima同様、仮想ディスクを明示的にcached / fsyncモードで開きます。ディスク・EFI・macOSのハードウェア識別子はLimaと共有します。LimaのmacOSゲスト対応は実験的です。初回のGUIログイン、OSセットアップ・ライセンス確認は利用者が行います。生成されたVMパスワードをログやテスト成果物へ収集しないでください。

Ubuntuはテスト専用ユーザーへ自動ログインします。macOS版の `test` コマンドはバンドル署名と版番号の検査までです。GUIで日本語入力が成功したことを示すものではありません。

## GUIの受け入れ項目

各VMで入力ソースにazooKeyを追加して確認します。Ubuntu WaylandはGNOME拡張も有効にします。

1. 「nihongo」「kyouhaiitenkidesu」の入力、変換、Enterと数字での確定。
2. ツリーの枝・読み・選択経路、長い木の縦横スクロール、画面端への配置。
3. 枝と番号のクリック後に元の入力欄へ続けて入力できること。
4. 矢印、Shift＋左右、Escape、Backspace、英数／かな切替、無変換2回。
5. アプリ切替、パスワード、PRIVATE欄、辞書登録、学習リセット、設定の即時反映。
6. macOSはTextEditとブラウザ、UbuntuはGTK・Qt・Chromiumの入力欄とX11を確認。

UbuntuのQt/Chromium用のローカル入力欄は `Tools/tests/qt-editor.py` です。VMのホームなど再起動で消えない場所へコピーし、VM内のPyQt6とQtWebEngineで実行します。外部サイトにはアクセスしません。

テストスクリプトはホストのATOK削除・入力ソース切替・ログアウトを行いません。VMで確認してからホスト導入へ進みます。
