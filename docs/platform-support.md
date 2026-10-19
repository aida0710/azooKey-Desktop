# 対応範囲と検証状況

Ubuntu版は開発中です。DockerでCoreのテストが通ることと、デスクトップで入力方式として使えることは別の検証です。未検証の欄を対応済みとは扱いません。

| 機能 | macOS | Ubuntu |
| --- | --- | --- |
| かな漢字変換、ライブ変換、文節編集、各文字種変換 | 上流実装 | 共通Core接続を実装中 |
| 木構造の候補表示・キー移動・クリック確定 | 実装、UI単体テスト済み、IME実動作は未検証 | 実装中 |
| 従来リスト表示、候補番号 | 上流実装と切替 | 実装中 |
| 学習、学習消去、ユーザー辞書 | 上流実装 | 共通Core接続・設定UIを実装中 |
| ローマ字・AZIK・かな配列・カスタム入力表 | 上流実装 | 共通Core接続・設定UIを実装中 |
| Zenzai AI変換・個人化・プロファイル | 上流実装 | CPU版ライブラリの接続が必要 |
| 予測、入力訂正、OpenAI互換API、いい感じ変換 | 上流実装 | 接続・設定UIを実装中 |
| Foundation Models、macOSシステム辞書連携 | 上流実装 | ユーザー指定により対象外 |
| GTK・Qt・Chromiumアプリ、X11・Wayland | 対象外 | 未検証 |
| Docker上の自動テスト | 対象外 | 実行環境を構築中 |
| OS内の入力方式テスト | 専用macOS VMを作成中 | 専用Ubuntu VMを準備中 |

## テスト環境

ホストに新しいパッケージを入れず、導入済みのDocker/Limaを利用します。

```sh
bash Tools/test-docker.sh
bash Tools/vm-test.sh macos create
bash Tools/vm-test.sh macos start
bash Tools/vm-test.sh ubuntu create
bash Tools/vm-test.sh ubuntu start
```

VMのディスクと設定は既定でリポジトリの隣の `azookey-vm` に置きます。`AZOOKEY_VM_HOME` で変更可能です。ホストのホームディレクトリは共有しません。Lima自身のOSダウンロードキャッシュは、macOSでは `~/Library/Caches/lima` に固定されています。

Lima 2.2のmacOSゲスト対応は実験的で、初回GUIログインが必要です。OSセットアップ・ライセンス画面は利用者が確認してください。パスワードをログやテスト成果物へ収集しません。

DockerではSwift・DBus・仮想画面を使って自動テストします。デスクトップVMではGUIセッションに入力方式を登録し、入力、候補移動、クリック、確定、Escape、文節変更、アプリ切替を確認します。ホストのATOK削除や入力ソース切替をテストスクリプトから行いません。
