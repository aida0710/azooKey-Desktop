# 導入・更新・復旧

このページは [aida0710/azooKey-Desktop](https://github.com/aida0710/azooKey-Desktop) の azooKey Tree 向けです。問題報告は[このフォークの Issue](https://github.com/aida0710/azooKey-Desktop/issues/new)へ送ってください。[上流の azooKey](https://github.com/azooKey/azooKey-Desktop) とは候補画面や Ubuntu 対応が異なります。

2026-10-20 時点の公開版は [tree-v0.1.2](https://github.com/aida0710/azooKey-Desktop/releases/tag/tree-v0.1.2) です。新しい試験版は[配布一覧](https://github.com/aida0710/azooKey-Desktop/releases)で確認します。試験版のため、GitHub の `releases/latest` には表示されない場合があります。開発中の機能は公開版に含まれるまで利用できません。

## macOS

Apple Silicon / macOS 14 以降が対象です。通常の Mac は `arm64.zip`、Apple ハードウェア上の macOS VM は `arm64-cpu.zip` を選びます。公開版は ad-hoc 署名・未公証です。

```sh
brew install --cask aida0710/tap/azookey-tree
```

システム設定 → キーボード → 入力ソースの編集 → 「+」→ 日本語 → azooKey を追加します。追加候補に出ない場合は作業を保存してログアウトし、再ログインしてください。メニューバーの入力メニューで azooKey を選び、同じメニューの「設定…」から設定画面を開きます。「使い方・サポート」はこの案内と診断情報への入口です。

公式 azooKey とこのフォークは入力方式 ID が同じなので、同時には導入しません。ATOK は削除しません。

更新は次のコマンドです。更新後に古い版が残る場合は、入力ソースを別のものへ切り替えてから、作業を保存して再ログインします。アプリは自動で再起動やログアウトを行いません。

```sh
brew update
brew upgrade --cask aida0710/tap/azookey-tree
```

候補画面だけを通常リストへ戻すには、設定の「木構造の候補ウィンドウ」をオフにします。入力方式を無効にするにはシステム設定から azooKey の入力ソースを外します。Homebrew で導入した本体は `brew uninstall --cask aida0710/tap/azookey-tree` で削除できます。辞書・学習・設定を削除する操作は含みません。

フォークの独立保存版は、アプリのコンテナ内の `Library/Application Support/azooKey/` に辞書・学習を保存します。共有コンテナを使う署名版は `~/Library/Group Containers/group.dev.ensan.inputmethod.azooKeyMac/Library/Application Support/azooKey/` です。実際の場所は設定 → 詳細設定 → アプリデータ →「Finderで開く」で確認できます。設定はその版の UserDefaults、API キーはキーチェーンに保存します。更新や本体の削除だけでは保存データを消しません。手動でフォルダーを削除する前には、必要なデータを退避してください。

## Ubuntu 24.04

[Ubuntu の導入手順](ubuntu.md)から CPU に合う `amd64.deb` または `arm64.deb` を選びます。`dpkg --print-architecture` で確認し、同じ版の `.sha256` を使って照合します。

1. 入力方式を IBus にします。必要な場合は `im-config -n ibus` を実行します。
2. GNOME の設定 → キーボード → 入力ソースに「日本語 → azooKey Tree」を追加します。
3. GNOME 46 / Wayland でツリーを使う場合は `gnome-extensions enable azookey-tree@aida0710` を実行します。初回は作業を保存してログアウトし、再ログインします。
4. 入力欄で azooKey Tree に切り替えます。設定はアプリ一覧の「azooKey Tree 設定」または `ibus-azookey-tree --setup` から開きます。

拡張が接続していない Wayland では IBus の通常リストを使います。設定の「木構造の候補ウィンドウ」をオフにしても通常リストへ戻せます。「使い方・サポート」の診断情報を更新すると、表示方式と通常リストへ戻る理由を確認できます。入力エンジンを確認できない場合は「未確認」と表示します。

更新は新しい版の同じ CPU 用 deb を `sudo apt install ./ファイル名.deb` で導入します。無効にするには GNOME の入力ソースから外し、拡張も不要なら `gnome-extensions disable azookey-tree@aida0710` を実行します。本体は `sudo apt remove azookey-tree` で削除できます。これらはユーザーの保存データを削除しません。

- 設定とユーザー辞書: `$XDG_CONFIG_HOME/azookey-tree/settings.json`（通常 `~/.config/azookey-tree/settings.json`）。
- AI の指示履歴: 同じ設定ディレクトリーの `prompts.json`。対象の本文は履歴に保存しません。
- 学習・個人化モデル: `$XDG_DATA_HOME/azookey-tree/`（通常 `~/.local/share/azookey-tree/`）。
- API キー: デスクトップの Secret Service キーリング。

学習の削除は設定の「履歴学習データを削除…」で対象を確認して行います。[保持するデータ](learning-settings.md)も確認してください。設定の破損時には原本を保全して復旧し、辞書が入った設定ファイルを手動で消して直そうとしないでください。

## 問題を報告するとき

設定の「使い方・サポート」から診断情報をコピーし、[このフォークの Issue](https://github.com/aida0710/azooKey-Desktop/issues/new) に貼り付けます。診断情報は版・ソースのコミット・OS・CPU・表示方式などに限定し、入力本文、辞書内容、AI の指示履歴、API キー、ユーザー名をコピーしません。

アプリ名、再現する操作、期待した結果、実際の結果を添えてください。本文やスクリーンショットを追加するときは、公開してよい内容に置き換えてください。診断情報の「未確認」は取得できなかった項目であり、正常動作の確認ではありません。
