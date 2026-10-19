# フォークの保守

上流は azooKey/azooKey-Desktop の main、独自タグは `tree-vMAJOR.MINOR.PATCH` です。上流のタグに合わせる必要はありません。

## 定期同期

`.github/workflows/sync-upstream.yml` は毎週月曜日06:23（日本時間）と手動起動に対応します。スクリプトは使い捨てのcloneでmergeし、現在の作業ツリーやmainを変更しません。競合時は終了コード3で停止し、pushしません。

```sh
# 調査のみ。pushしない。
bash Tools/sync-upstream.sh
# 同期ブランチとPRを作り、そのブランチのCIを明示起動する。
bash Tools/sync-upstream.sh --publish --dispatch-tests
```

通常のmerge履歴を使い、force-pushや自動マージは行いません。GITHUB_TOKENで作成したPRは通常のpull_requestイベントでCIが起動しないため、workflow_dispatchも呼びます。フォーク側のActionsが有効で、ワークフローにPR作成権限が必要です。scheduleは既定ブランチに取り込まれてから動作します。

## 検証と配布

```sh
bash Tools/test-tree-model.sh
bash Tools/test-macos-app.sh
bash Tools/test-docker.sh
bash Tools/test-docker.sh --zenzai
python3 Tools/fetch-models.py
bash Tools/tree-build.sh 0.1.0
bash Tools/tree-build.sh 0.1.0 cpu # macOS VM向け。別名のarm64-cpu.zip
bash Tools/package-linux-docker.sh 0.1.0
```

macOSビルドはアプリの実ソースをSwiftPMからコンパイルします。Xcodeのプロジェクト構成とは別なので、Xcode固有の問題を解消した場合はXcodeのビルド・テストも実行します。モデルは固定されたサブモジュールのLFSポインタで検証します。git-lfsを新規導入する必要はありません。

配布前に専用macOS VMとUbuntuデスクトップVMで実際の入力を確認します。`build/dist` のzipを確認してから同名のGitHub Releaseへ登録し、実在するアーカイブからcaskを生成します。

VMの作成・パッケージ導入・実行テストは [VMテスト](vm-testing.md) を参照してください。LinuxのパッケージにはSwiftランタイム、CPU版Zenzai、辞書とモデルを同梱し、amd64/arm64を各アーキテクチャのCIで生成します。

```sh
python3 Tools/render-cask.py build/dist/azookey-tree-0.1.0-arm64.zip build/dist/azookey-tree.rb
```

Homebrew定義の正本はこのリポジトリの `packaging/homebrew` です。リリースが存在し、SHA-256を照合できた後に、生成したcaskを aida0710/homebrew-tap の `Casks/azookey-tree.rb` に反映します。未公開のURLや仮のハッシュをtapへ登録しません。

現在のビルドはad-hoc署名・未公証です。Gatekeeperの無効化や隔離属性の一括削除は行いません。Developer ID署名・公証を導入する場合は、署名設定を別途用意します。

### macOS試作配布版の保存先

`tree-build.sh` の配布物は `AzooKeyStandaloneStorage=true` を付け、アプリ自身のsandboxに設定・辞書・学習を保存します。上流の共有App Groupへアクセスする権限を要求しません。Xcodeで通常ビルドした場合は上流の共有保存方式を維持します。共有版の設定・学習は自動移行しません。

Tunerの共有出力も自動では読み込みません。個人化を使う場合は、azooKeyの設定→詳細設定→開発者向け設定→アプリデータ「Finderで開く」から保存先を表示し、`azooKey` フォルダと同じ階層に `p13n_v1` フォルダを作ります。Tunerで作成した次の4ファイルをそこへコピーし、azooKeyを再起動してパーソナライズを有効にしてください。

- `lm_c_abc.marisa`
- `lm_r_xbx.marisa`
- `lm_u_abx.marisa`
- `lm_u_xbc.marisa`

通常のコピー先は `~/Library/Containers/dev.ensan.inputmethod.azooKeyMac/Data/Library/Application Support/p13n_v1/` です。上流の共有フォルダからのコピーは利用者が明示的に行います。アプリ側から自動で読み出したり、macOSの保護を解除したりしません。
