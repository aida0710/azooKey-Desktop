# azooKey Tree Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 木構造の候補表示、Ubuntuデスクトップ版、Docker/macOS VMでのテスト、定期的な上流同期、Homebrew配布を実装する。

**Architecture:** 既存候補を接頭語の木へ投影する純粋なCoreモデルと、AppKitの描画・操作層を分離する。確定は元の候補インデックスを使って既存処理へ委譲する。独自のビルド・同期スクリプトは上流ファイルから分離する。

**Tech Stack:** Swift、AppKit、Xcode、Linux入力方式アダプタ、Docker、Lima、既存のSwiftPM依存、GitHub Actions、Homebrew Cask。

**Spec:** ../specs/2026-10-19-candidate-tree-design.md

## Global Constraints

- 作業は~/projects/codex内。追加ツールのインストールは禁止。SwiftPM依存ソースの取得は事前確認する。
- macOS版のフォークはaida0710/azooKey-Desktop、tapはaida0710/homebrew-tap。
- 実在候補だけを選択し、確率を捏造しない。
- ATOKを削除しない。ログアウトやセキュリティ保護の無効化を自動実行しない。
- tree-v0.1.0形式の独自タグ、cask名azookey-tree。

## Review Focus

- 同じ表記・異なる読みや途中で終わる候補が、別の候補として確定されないこと。
- 日付・予測・空の解析データでも、表示したtextと入力されるtextが一致すること。
- 再描画が変換や選択の通知を再帰的に呼ばないこと。
- 候補更新と左右移動の後に、古いインデックスを入力しないこと。
- 長文、多数候補、画面端、入力アプリの切り替えでフォーカスを奪わないこと。

### Task 1: 候補の木と移動モデル

**Files:** Core/Sources/Core/InputUtils/CandidateTree.swift、Core/Tests/CoreTests/InputUtilsTests/CandidateTreeTests.swift。

**Interfaces:** CandidateTree.Entryはtext、tokens、candidateIndexを持つ。CandidateTreeはnodes、pathsと候補を選ぶAPIを公開し、移動状態はCandidateTreeSelectionとして分離する。UIは元候補のインデックスだけを受け取る。

- [ ] 共通語の共有、読み違い、接頭候補、テンプレートの退避、元インデックス保持のテストを先に追加して失敗を確認する。
- [ ] 純粋な木の構築と移動処理を実装し、テストを通す。
- [ ] 入力候補の順序変更、空集合、範囲外の選択、兄弟・親子への移動を検証する。

### Task 2: AppKit表示と既存処理への接続

**Files:** azooKeyMac/InputController/CandidateWindow/CandidateTreeView.swift、CandidateView.swift、azooKeyMacInputController.swift、Core/Sources/Core/Configs/BoolConfigItem.swift、azooKeyMac/Windows/ConfigWindow.swift、azooKeyMacTests/CandidateSelectionFeedbackTests.swift。

**Interfaces:** CandidateTreeViewの更新は通知なし、ユーザー操作だけが選択通知を呼ぶ。CandidatesViewControllerから元候補インデックスを既存delegateへ渡す。木表示が無効な場合は従来の動作を使う。

- [ ] 再描画で通知が起きず、ユーザー操作で一度だけ通知される回帰テストを先に追加する。
- [ ] ノード、接続線、選択経路、読み、候補番号、スクロール、画面内への配置を実装する。
- [ ] 選択中の修飾なし矢印だけを木操作へ渡し、Enter、Space、数字、Shift+左右は既存処理につなぐ。
- [ ] 設定の切替と既存表示の回帰、候補更新時の選択を検証する。

### Task 3: 上流同期と独自配布

**Files:** Tools/tree-build.sh、Tools/tree-package.sh、Tools/sync-upstream.sh、packaging/homebrew/azookey-tree.rb、.github/workflows/tree-release.yml、.github/workflows/sync-upstream.yml、docs/tree-maintenance.md。

**Interfaces:** buildは作業ディレクトリ内に.appを出力。packageは独自バージョン付きzipとSHA-256を作る。同期は上流mainからPRを作成し、競合時に停止する。tap定義はプロジェクト側を正本とする。

- [ ] 既存ツールだけで依存ソースとモデルを取得し、変更前のCoreテストを確認する。
- [ ] シェル構文、無効バージョンの拒否、成果物とハッシュ、caskのRuby構文を検証する。
- [ ] 上流mainとの差分をPRにまとめる手順と、独自リリースの手順を文書化する。

### Task 4: 実機確認・公開・導入

追加されたTask 5・6を含めて検証後に公開する。入力方式の導入テストは専用macOS VMを先に使う。

**Files:** aida0710/homebrew-tap/Casks/azookey-tree.rb、README.md、およびプロジェクト側の保守文書。

- [ ] Coreのテスト全体とReleaseビルド、対象のXcodeテストを実行する。
- [ ] 候補ウィンドウの実表示、キー操作、クリック、確定を確認し、可能なら実際の入力ソースとして試す。
- [ ] 最終差分をレビューし、検証済みのコミットをフォークへpushする。
- [ ] 検証済み成果物だけをリリースし、実ハッシュのcaskをtapへ登録する。
- [ ] 導入状態と入力テストを確認し、ログアウトなどユーザー操作が残る場合は明確に報告する。

### Task 5: Ubuntuデスクトップ版

**Interfaces:** 既存の変換エンジンと木のモデルを再利用し、OS固有のイベント・preedit・確定・周辺テキスト・設定画面をLinux側へ接続する。

- [ ] 機能対応表を作成し、Apple固有機能の代替方針を記載する。
- [ ] 日本語入力、変換・文節編集、各文字種、学習・辞書、設定・カスタム配列、予測・AIをLinux入力方式に接続する。
- [ ] 木の表示・キー移動・クリック・確定と従来候補への切替を実装する。
- [ ] UbuntuのX11/WaylandでGTK/Qt/Chromium系アプリへの入力を検証する。

### Task 6: 再現可能な隔離テストと定期更新

**Files:** Tools/test-docker.sh、Tools/vm-test.sh、packaging/docker/、packaging/vm/、Tools/tests/test-sync-upstream.sh、.github/workflows/tree-ci.yml。

- [ ] Docker内でCore・Linux側テストを実行する。ホストへパッケージをインストールしない。
- [ ] 専用macOS VM/Ubuntu VMの作成・起動・テスト転送・結果回収をスクリプト化する。
- [ ] 上流同期をローカルGit fixtureで検証する（差分なし・通常更新・競合・再実行・元の作業内容保持）。
- [ ] 週次scheduleと手動起動から同じ同期スクリプトを実行し、PRのCIも明示的に起動する。
