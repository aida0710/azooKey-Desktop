# Ubuntuで使う

Ubuntu 24.04 / IBusが対象です。2026-10-20 時点の公開版 [tree-v0.1.2](https://github.com/aida0710/azooKey-Desktop/releases/tag/tree-v0.1.2)から、CPUに合う `azookey-tree_0.1.2_arm64.deb` または `azookey-tree_0.1.2_amd64.deb` と対応する `.sha256` をダウンロードしてください。同じディレクトリで `sha256sum -c ファイル名.deb.sha256` により照合できます。新しい試験版は[配布一覧](https://github.com/aida0710/azooKey-Desktop/releases)を確認します。

ソースから作成する場合は次のコマンドを使います。arm64とamd64はそれぞれのCPU上で同じDockerビルドを実行します。依存パッケージはDocker内へ入ります。

```sh
python3 Tools/fetch-models.py
bash Tools/test-docker.sh --zenzai
bash Tools/package-linux-docker.sh 0.1.2
```

取得または生成したdebを、対象Ubuntu内で `sudo apt install ./azookey-tree_0.1.2_arm64.deb` により導入します（amd64ではファイル名もamd64に変更）。異なるCPU用のパッケージは使えません。同じ版番号の開発ビルドを入れ直す場合は `sudo apt install --reinstall ./ファイル名.deb` とします。開発ソースに公開版の番号を付けたものは、公開済みパッケージと同一とは限りません。

[更新・無効化・アンインストール・復旧](setup-and-recovery.md)も参照してください。

1. 入力方式をIBusに設定します（`im-config -n ibus`）。
2. GNOMEの「設定 → キーボード → 入力ソース」に「日本語 → azooKey Tree」を追加します。
3. GNOME 46 / Waylandで木構造を使う場合、`gnome-extensions enable azookey-tree@aida0710` を実行します。初回はUbuntuからログアウトして再ログインします。
4. 入力ソースをazooKey Treeへ切り替えます。設定画面はアプリ一覧の「azooKey Tree Settings」、または `ibus-azookey-tree --setup` で開きます。

ツリーは元候補の単語列だけで構成します。枝で選択し、数字ボタンまたはEnterで確定します。Shift＋左右は文節長の変更、Spaceは通常の候補送りです。英数／無変換キー2回は編集中の元のローマ字を確定します。キーボードの物理配列はOS側の設定を使用します。

X11はGTKツリーを使います。GNOME拡張がないWayland環境ではIBusの通常リストへ戻ります。「木構造の候補ウィンドウ」をオフにしても通常リストを使えます。パスワード・PIN欄ではIME処理をしません。PRIVATE属性の通常欄では日本語を入力できますが、学習と外部AI要求を抑止します。

## 設定と保存先

- 設定UIのJSON: `$XDG_CONFIG_HOME/azookey-tree/settings.json`（既定 `~/.config`）。APIキーは含めません。
- 学習と個人化: `$XDG_DATA_HOME/azookey-tree`（既定 `~/.local/share`）。テスト用に `AZOOKEY_DATA_DIR` で上書きできます。
- APIキー: デスクトップのSecret Serviceキーリング。GNOME Keyringなど、ロック解除済みのSecret Serviceが必要です。
- AI変換の履歴: 指示文のみ保存します。選択した本文は履歴へ保存しません。

AIを有効にすると、明示的なAI操作時に入力・選択文を設定したAPIへ送信します。「周辺テキストを含める」がオンの場合は前後の文も送信します。Zenzaiによる通常のかな漢字変換はローカルです。

## Tunerの個人化モデル

[Tuner](https://github.com/azooKey/Tuner)で生成した `lm_c_abc.marisa`、`lm_r_xbx.marisa`、`lm_u_abx.marisa`、`lm_u_xbc.marisa` が入ったフォルダーを、設定の「Tunerの個人化モデルを読み込む…」で選びます。個人化の強度を選び「保存」すると既存セッションにも反映します。

モデルは4ファイルをひとまとまりでコピーし、`personalization/current` を新しい組へ切り替えます。旧組は保持します。元フォルダーは変更しません。Tuner本体はmacOSのアクセシビリティAPIを使う別アプリのため、Ubuntuへ常駐する画面収集サービスは含まれません。
