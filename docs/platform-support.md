# 対応範囲と検証状況

対象はApple SiliconのmacOS 14以降、Ubuntu 24.04のarm64/amd64です。UbuntuのWaylandツリーはGNOME 46拡張で表示します。X11はGTKポップアップです。他のWaylandコンポジターではIBusの通常候補リストを利用します。

「実装済み」と「実アプリで確認済み」を区別します。全機能の受け入れ検証と配布は進行中です。

| 機能 | 実装 | 検証状況 |
| --- | --- | --- |
| かな漢字・ライブ変換、文節編集、文字種変換、Unicode入力 | 上流Coreを両OSで共有 | Core自動テスト、Ubuntuの実変換 |
| 木構造の候補・元候補番号・キー移動・クリック確定 | macOS AppKit / Ubuntu GTK・GNOME | モデル7テスト、macOSアプリ10テスト。macOS TextEditで枝・読み・矢印移動・番号クリック／ダブルクリック確定と追加入力を確認。Ubuntu GNOMEで曲線・読み・横スクロール・クリック後の追加入力を確認 |
| 学習・学習リセット・PRIVATE欄で学習抑止 | 共通Core＋IBus属性 | 通常学習の保存、PRIVATE後の保持、起動直後のリセットを回帰テスト |
| ユーザー辞書・カスタム入力表・各入力配列 | 共通Core＋Ubuntu設定画面 | 辞書反映・入力表検証の統合テスト |
| Zenzai | macOS Metal / Ubuntu CPU | Ubuntu arm64で実モデル読み込みと変換を確認 |
| プロファイル・個人化 | 設定画面、Tunerモデル4ファイルの取り込み | インポートの原子性と既存セッションへの有効/無効反映をテスト。利用者の学習済みモデルでの精度は未評価 |
| 予測入力・入力訂正モデル | 上流Core＋モデル取得UI | Coreテスト。上流同様、実験的機能 |
| OpenAI互換API・選択文の変換・履歴・固定・ショートカット | Linux用画面とキーリング連携 | ローカルAPI模擬サーバー、履歴・古い候補の拒否・失敗時の入力保持をテスト。外部API未使用 |
| Foundation Models・macOSシステム辞書 | macOSの上流実装 | Ubuntuは指定により対象外 |
| GTK / Qt / Chromium入力欄 | IBus | Ubuntu GNOME Wayland VMで変換・候補クリック・追加入力を確認 |
| Docker | Ubuntu + Swift + CPU Zenzai + D-Bus + Xvfb | arm64で最新パッケージと自動テストを実行済み。amd64/arm64はCIでも通過（b64a346）。最新コミットのCIは実行待ち |
| macOS VM | Apple Virtualization + LimaのmacOSゲスト | macOS 26.5.2で作成・起動・パッケージ配置・署名検査・TextEditでの実IME入力を確認 |

ホストのATOKは削除・切り替えしていません。macOS版のアプリ単体テストや署名検査は、入力方式としてのGUIテストを代替しません。

実行手順は [VMテスト](vm-testing.md)、Linuxの設定と制約は [Ubuntu](ubuntu.md) を参照してください。
