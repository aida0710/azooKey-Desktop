# Windows版（試作）

Windows 10/11（x64）向けの日本語入力です。Text Services Framework（TSF）のテキストサービスとして動きます。変換はmacOS・Ubuntu版と同じCoreを使います。試作の段階で、配布物はまだありません。

## 構成

| 部品 | 役割 |
| --- | --- |
| `azookey-tsf.dll` | TSFのテキストサービス。入力欄を持つアプリごとに読み込まれ、キーを受け取って未確定文字・確定・候補一覧を扱います |
| `azookey-windows-host.exe` | 利用者ごとに1つ動く常駐プロセス。各アプリのテキストサービスから名前付きパイプで要求を受け、変換エンジンを1つだけ動かします |
| `bridge\azookey-desktop-bridge.exe` | Ubuntu版と同じ変換エンジン（Core）。Swiftの実行時ライブラリと辞書を同じフォルダに置きます |

アプリごとに変換エンジンを起動すると、辞書と学習データをアプリの数だけ読み込むため、常駐プロセスに集めています。パイプは利用者本人とSYSTEM、同じ利用者のストアアプリ（AppContainer）だけが開けます。学習データは`%LOCALAPPDATA%\azooKey Tree`に置きます。

## キー操作

| キー | 動作 |
| --- | --- |
| 半角/全角、Alt+`、IMEオン/オフキー | 日本語入力の切り替え |
| 無変換 / 変換 | 日本語入力を終える / 始める（Macの英数・かなと同じ）。入力中の変換キーはSpaceと同じ変換です |
| Space、↑↓ | 変換・候補の移動 |
| 1〜9 | 候補の番号で確定 |
| PageUp / PageDown | 候補のページ送り |
| Shift+←→ | 文節の伸縮 |
| F6〜F10 | ひらがな・カタカナ・全角英数・半角英数への変換 |
| Enter / Esc | 確定 / 取り消し |

入力中の文字は、打っている間は点線、変換中の文節は太い下線、ほかの文節は細い下線で表示します。色はアプリの配色に任せます。候補一覧はマウスでも選べ、選んでもアプリからフォーカスを奪いません。パスワード・PINの入力欄（InputScope）では変換を通さず、そのまま入力します。

## ビルドと導入

Visual Studio Build Tools 2022（C++のx64ツール、Windows SDK、CMake）と、Swift 6.2（`Windows\scripts\install-swift.ps1`）を使います。

```powershell
. Windows\scripts\enter-dev-shell.ps1
Windows\scripts\build-package.ps1 -Output build\windows-package
# 管理者のPowerShellで
build\windows-package\install.ps1
```

`install.ps1`は`C:\Program Files\azooKey Tree`へ置き、テキストサービスを登録し、サインイン時に常駐プロセスを起動するよう設定し、日本語のキーボード一覧に追加します。Win+Spaceで切り替えられます。削除は`uninstall.ps1`です。学習データは`-RemoveUserData`を付けたときだけ消します。

## 試験

| 試験 | 内容 | 必要な環境 |
| --- | --- | --- |
| `azookey-windows-tests.exe` | JSON、UTF-8/UTF-16の位置換算、キーの振り分けと変換、要求・応答の形式 | なし |
| `azookey-host-integration-test.exe` | 常駐プロセスとブリッジを起動し、「nihongo→Space→Enter」で「日本語」を確定。2つのアプリの入力が混ざらないこと | なし（SSHのセッションでも可） |
| `tsf-harness.exe` | TSFに対応したRichEditを開き、テキストサービスを有効にしてキーを送り、文書の文字列を確かめる | デスクトップのセッション。SSHのセッション（セッション0）ではTSFが使えません |

CIは`.github/workflows/windows.yml`で、ビルド・上の3つの試験・配布物の保存を行います。

## 制約と未確認のこと

- 対応はx64のアプリだけです。32ビット（x86）とArm64のアプリでは使えません。
- Zenzai（ニューラル変換）はWindowsでは無効です。変換エンジンのllama.cppをまだ同梱していません。誤字補正の重みも、Windows版の変換エンジンが読めないため使えません。
- 木構造の候補表示、設定画面、ユーザー辞書の編集画面、AI変換はWindowsにはまだありません。設定は既定値で動きます。
- 候補一覧のアクセシビリティ（ナレーターへの読み上げ）と、全画面のゲームなどUI-lessモードには未対応です。
- WindowsのSwiftは検査付き（+Asserts）の版だけが配布されており、依存ライブラリの最適化中に検査が止まるため、SIL検証を外してビルドしています（Linuxの通常版と同じ条件）。
- Smart App Controlが有効な機械では、署名のない実行ファイル・DLLが止められることがあります。開発機ではSwiftPMの一時実行ファイルが止められる事例がありました。配布するにはコード署名が必要です。
- 実アプリ（メモ帳、Edge、Word、ストアアプリなど）での入力、候補一覧の位置、高DPI、フォーカス移動時の確定は、デスクトップのセッションでの確認がまだです。
