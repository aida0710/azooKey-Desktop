# Windows版（試作）

Windows 10/11 の 64 ビット（x64）と 32 ビット（x86）のアプリで使える日本語入力です。Text Services Framework（TSF）のテキストサービスとして動きます。変換はmacOS・Ubuntu版と同じCoreを使います。試作の段階で、配布物はまだありません。

## 構成

| 部品 | 役割 |
| --- | --- |
| `azookey-tsf.dll`、`x86\azookey-tsf.dll` | TSFのテキストサービス。入力欄を持つアプリごとに、そのアプリと同じビット数のものが読み込まれ、キーを受け取って未確定文字・確定・候補一覧を扱います。2つは同じ CLSID に登録します |
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

入力中の文字は、打っている間は点線、変換中の文節は太い下線、ほかの文節は細い下線で表示します。色はアプリの配色に任せます。パスワード・PINの入力欄（InputScope）では変換を通さず、そのまま入力します。

## 候補の表示

打っている間は未確定の文字だけを出し、Space で変換すると、文字の下に番号付きの候補（Core の 9 件のページ）を出します。下に場所がなければ上に出し、入力中の行には重ねません。候補をクリックすると選択、ダブルクリック・「確定」・Enter で確定します（Linux と同じく、選択と確定を分けています）。‹ › でページを送ります。候補の一覧はアプリからフォーカスを奪いません。

描画は Direct2D で、モニターごとの表示倍率に合わせます。配色は `Shared/CandidatePalettes.json` から生成した明・暗・高コントラスト（明・暗）の4種類で、Windows のアプリの配色と高コントラストの設定に従います。選択中の候補は、背景・枠・文字の色をそろえて示し、色だけに頼りません。

全画面のゲームなど、候補を自分で描くアプリ（TSF の UI-less モード）には、候補一覧を `ITfCandidateListUIElementBehavior` として渡し、IME の候補パネルは出しません。

打っている間に枝分かれする木（Linux の木構造の候補表示）は、描画の部分まで作ってあります。各節点の位置の計算を GTK・GNOME と同じ Core の処理にまとめてから表示します。

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
| `tsf-harness.exe`（`Windows\tests\tsf-cases.ps1` で13種類） | TSFに対応したRichEditを開き、導入したテキストサービスを有効にしてキーを送り、文書の文字列を確かめる。変換と確定、F7、Backspace、数字キーと↓の候補選択、句読点、長音、Escの後の打ち直し、半角/全角・無変換・変換による切り替え、候補を自分で描くアプリ。途中の画面を撮影できる | デスクトップのセッション。SSHのセッション（セッション0）ではTSFが使えません |

CIは`.github/workflows/windows.yml`で、ビルド、上の試験（TSFの試験は64ビットと32ビットのアプリの両方）、撮影した画面と配布物の保存を行います。GitHubのWindowsの実行環境にはデスクトップのセッションがあるため、TSFの試験もそこで行います。試験の期待値は、辞書のみの変換結果をブリッジで確かめたものです。

## 制約と未確認のこと

- Arm64のアプリでは使えません（x64とx86には対応）。
- Zenzai（ニューラル変換）はWindowsでは無効です。変換エンジンのllama.cppをまだ同梱していません。誤字補正の重みも、Windows版の変換エンジンが読めないため使えません。
- 木構造の候補表示、設定画面、ユーザー辞書の編集画面、AI変換、確定取消・選択再変換は、Linuxの処理をCoreへまとめる作業と合わせて実装中です。いまの設定は既定値です。
- 候補一覧のナレーターへの読み上げには未対応です。
- WindowsのSwiftは検査付き（+Asserts）の版だけが配布されており、依存ライブラリの最適化中に検査が止まるため、SIL検証を外してビルドしています（Linuxの通常版と同じ条件）。
- Smart App Controlが有効な機械では、署名のない実行ファイル・DLLが止められることがあります。開発機ではSwiftPMの一時実行ファイルが止められる事例がありました。配布するにはコード署名が必要です。
- 自動試験はRichEditで行っています。メモ帳、Edge、Word、ストアアプリなどの実アプリでの入力、高DPIの複数画面、フォーカス移動時の確定は確認がまだです。
