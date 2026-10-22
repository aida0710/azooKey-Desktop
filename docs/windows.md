# Windows版（試作）

Windows 10/11 の 64 ビット（x64）と 32 ビット（x86）のアプリで使える日本語入力です。Text Services Framework（TSF）のテキストサービスとして動きます。変換はmacOS・Ubuntu版と同じCoreを使います。試作の段階で、配布物はまだありません。

## 構成

| 部品 | 役割 |
| --- | --- |
| `azookey-tsf.dll`、`x86\azookey-tsf.dll` | TSFのテキストサービス。入力欄を持つアプリごとに、そのアプリと同じビット数のものが読み込まれ、キーを受け取って未確定文字・確定・候補一覧を扱います。2つは同じ CLSID に登録します |
| `azookey-windows-host.exe` | 利用者ごとに1つ動く常駐プロセス。各アプリのテキストサービスから名前付きパイプで要求を受け、変換エンジンを1つだけ動かします |
| `bridge\azookey-desktop-bridge.exe` | Ubuntu版と同じ変換エンジン（Core、trait ZenzaiCPU）。Swiftの実行時ライブラリ、辞書、llama.cppのDLL（`llama.dll`・`ggml.dll`・`ggml-base.dll`・`ggml-cpu.dll`）を同じフォルダに置きます |
| `models\ggml-model-Q5_K_M.gguf` | Zenzaiのモデル（zenz-v3.2-small、Q5_K_M）。常駐プロセスがこのフォルダを`AZOOKEY_RESOURCES`としてブリッジへ渡します |
| `licenses\` | 同梱したllama.cpp（MIT、`llama.txt`）とモデル（Apache-2.0、`Apache-2.0.txt`）の告知 |

配布物は展開して約211MBです（CI run 39775273822の成果物。モデル74MB、Swiftと Visual C++ の実行時ライブラリ62MB、ブリッジ42MB、辞書29MB、llama.cppのDLL 2.3MB）。

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

## Zenzai（ニューラル変換）

macOS・Ubuntu版と同じZenzaiを、CPUだけで動かします。ブリッジは`AZOOKEY_RESOURCES`のフォルダにモデルがあればZenzaiを使い、無ければ辞書だけで変換します。配布物にはモデルを入れてあるので、導入すれば常に有効です（切り替える設定はまだありません）。モデルは最初の変換のときに読み込み、読み込めたかは応答の`zenzaiLoaded`に出ます。

| 項目 | 内容 |
| --- | --- |
| llama.cpp | [azooKey/llama.cpp](https://github.com/azooKey/llama.cpp)のb4846（`10131b23ee0dbd9d03dfc618cec9fe3402919277`）。上流のmacOS版の`llama.xcframework`、Ubuntu版のパッケージと同じリビジョンです。`Windows\scripts\build-llama.ps1`が取得したコミットを照合し、MSVCとNinjaでCPU用の共有ライブラリ（DLL 4つ、計約2.3MB）として作ります |
| 命令セット | `GGML_NATIVE=OFF`で、作る機械に関係なくAVX2・BMI2（MSVCではFMA・F16Cも）に固定します（Ubuntu版と同じ）。AVX2の無いCPUでの動作は、Zenzaiを使わない変換も含めて確かめていません |
| 並列 | OpenMPは使わず、ggml自身のスレッドで推論します。スレッド数は変換エンジンが論理CPU数から決め、8論理CPUなら6、4論理CPUなら3です |
| モデル | `ggml-model-Q5_K_M.gguf`（73,871,936バイト、SHA-256 `29c223d4c23327b80fd13ebb5ab2555057a46317997d5da391584ffbef0db673`）。取得元とハッシュはmacOS・Ubuntu版と同じで、`Tools\fetch-models.py --model gguf`が照合します |
| ブリッジへの渡し方 | 変換エンジン（AzooKeyKanaKanjiConverter）はWindowsでllama.cppを`systemLibrary`として扱い、自分の持つヘッダーで`llama.lib`をリンクします。CPUデバイスの取得に`ggml.lib`も要るので、`swift build --traits ZenzaiCPU -Xswiftc -L<llama.cppのlib> -Xswiftc -lggml`でビルドします。変換エンジンのヘッダーはb4846よりわずかに古い版ですが、変換エンジンが使う構造体と関数の宣言はすべて同じです（Ubuntu版も同じ組み合わせ） |

使えないもの: 個人化（プロファイルの言語モデル）と誤字補正の重みは、marisa形式のファイルをWindows版の変換エンジンが読めないため使えません。

### 応答時間とメモリ

GitHub Actionsの`windows-2022`実行環境（4論理CPU。変換エンジンの決め方ではZenzaiは3スレッド）で`Windows\tools\measure-zenzai.ps1`を実行した値です。releaseビルドの配布物を使い、毎回空のデータフォルダー（学習の影響なし）、ライブ変換は既定（有効）のまま、8つの読み（計172キー）を1文字ずつブリッジへ送りました。時間はブリッジへの要求から応答の受け取りまでで、候補の描画は含みません。1打目は辞書の読み込みを、Zenzaiありではモデルの読み込みも含みます。メモリは8つの読みを打ち終えた後のブリッジの値です。

| 実行環境のCPU（CI run） | モード | 1打目 | 2打目以降 中央値 / p95 / 最大 | Space 中央値 | 作業セット（最大） | プライベート |
| --- | --- | --- | --- | --- | --- | --- |
| AMD EPYC 7763（39777098150） | 辞書のみ | 104.4 ms | 9.6 / 29.3 / 48.5 ms | 17.3 ms | 30.9（41.1）MiB | 13.3 MiB |
| AMD EPYC 7763（39777098150） | Zenzai | 141.4 ms | 20.5 / 66.4 / 95.7 ms | 45.8 ms | 129.1（129.5）MiB | 97.7 MiB |
| AMD EPYC 9V74（39775273822） | 辞書のみ | 98.5 ms | 8.9 / 22.6 / 61.0 ms | 16.3 ms | 31.0（41.2）MiB | 13.2 MiB |
| AMD EPYC 9V74（39775273822） | Zenzai | 141.7 ms | 20.6 / 66.0 / 92.8 ms | 44.4 ms | 130.2（130.2）MiB | 98.9 MiB |

Zenzaiありでは、2打目以降の応答の中央値が約2.1〜2.3倍（11〜12ms増）、p95が約2.3〜2.9倍になり、作業セットが約98MiB、プライベートが約85MiB増えました。常駐プロセスを通した結合試験（ブリッジの起動を含む）の1打目は、3回のCIで256〜531msでした。

開発機のCore i3-10100T（4コア8スレッド）では測れていません。新しくビルドしたブリッジの実行がSmart App Controlに止められたためです（後述）。測れるようになったら同じスクリプトで測ります。

同じ8つの読みで、ライブ変換の結果がZenzaiで変わったのは次の2つでした（CI run 39777098150）。ほかの6つ（「橋の橋を渡る」「会議を開催する」など）は同じ結果でした。

| 読み | 辞書のみ | Zenzai |
| --- | --- | --- |
| kyouhaisyaniiku | 今日は医者に行く | 今日歯医者に行く |
| niwanihaniwaniwatorigairu | 庭には庭ニワトリがいる | 庭には庭にわとりがいる |

## ビルドと導入

Visual Studio Build Tools 2022（C++のx64ツール、Windows SDK、CMake）と、Swift 6.2（`Windows\scripts\install-swift.ps1`）を使います。Zenzaiのモデルの取得にはPythonが要ります。Pythonの無い機械では、別の機械で取得・照合した`build\models\ggml-model-Q5_K_M.gguf`を写して使えます。

```powershell
# Zenzaiのモデル（git-lfsは不要。リビジョンとSHA-256を照合する）
$env:GIT_LFS_SKIP_SMUDGE = '1'
git submodule update --init azooKeyMac/Resources/gguf
python Tools\fetch-models.py --model gguf
. Windows\scripts\enter-dev-shell.ps1
Windows\scripts\build-llama.ps1
Windows\scripts\build-package.ps1 -Output build\windows-package
# 管理者のPowerShellで
build\windows-package\install.ps1
```

`build-package.ps1`は、llama.cpp（`build\llama-windows\install`）とモデル（`build\models`）が無ければ止まります。場所は`-LlamaDirectory`・`-ModelDirectory`で変えられます。`install.ps1`は`C:\Program Files\azooKey Tree`へ置き、テキストサービスを登録し、サインイン時に常駐プロセスを起動するよう設定し、日本語のキーボード一覧に追加します。Win+Spaceで切り替えられます。削除は`uninstall.ps1`です。学習データは`-RemoveUserData`を付けたときだけ消します。

## 試験

| 試験 | 内容 | 必要な環境 |
| --- | --- | --- |
| `azookey-windows-tests.exe` | JSON、UTF-8/UTF-16の位置換算、キーの振り分けと変換、要求・応答の形式 | なし |
| `azookey-host-integration-test.exe` | 常駐プロセスとブリッジを起動し、「nihongo→Space→Enter」で「日本語」を確定。2つのアプリの入力が混ざらないこと。`--expect-zenzai`を付けると、常駐プロセスの隣の`models`のモデルでZenzaiが変換したこと（`zenzaiLoaded`）も確かめます。付けないときはZenzaiを「NOT RUN」と表示し、成功とは扱いません | なし（SSHのセッションでも可） |
| `Windows\tools\measure-zenzai.ps1` | 配布物のブリッジをモデルあり・なしで起動し、打鍵ごとの応答時間、メモリ、8つの読みの変換結果を並べる | なし |
| `tsf-harness.exe`（`Windows\tests\tsf-cases.ps1` で13種類） | TSFに対応したRichEditを開き、導入したテキストサービスを有効にしてキーを送り、文書の文字列を確かめる。変換と確定、F7、Backspace、数字キーと↓の候補選択、句読点、長音、Escの後の打ち直し、半角/全角・無変換・変換による切り替え、候補を自分で描くアプリ。途中の画面を撮影できる | デスクトップのセッション。SSHのセッション（セッション0）ではTSFが使えません |

CIは`.github/workflows/windows.yml`で、ビルド、上の試験（TSFの試験は64ビットと32ビットのアプリの両方）、撮影した画面と配布物の保存を行います。GitHubのWindowsの実行環境にはデスクトップのセッションがあるため、TSFの試験もそこで行います。CIはZenzai付きの配布物を作り、常駐プロセスの結合試験は`--expect-zenzai`で行います。TSFの試験の期待値は、Zenzai付きの配布物がTSF経由で返した変換結果です（辞書だけのときと比べ、nihongoの第2候補がニホンゴ、tesuto-がてすとーになります）。

## 制約と未確認のこと

- Arm64のアプリでは使えません（x64とx86には対応）。
- Zenzaiの個人化と誤字補正の重みは使えません（marisa形式を読めないため）。Zenzaiを切る設定もまだありません。
- 最初の打鍵は、ブリッジの起動と辞書・モデルの読み込みを待ちます。GitHubの実行環境では常駐プロセス経由の1打目が256〜531ms（3回）でした。テキストサービスは常駐プロセスの応答を2秒まで待つため、遅い機械や、ディスクのキャッシュが無い起動直後では1打目が間に合わない恐れがあります。実機では測っていません。
- 木構造の候補表示、設定画面、ユーザー辞書の編集画面、AI変換、確定取消・選択再変換は、Linuxの処理をCoreへまとめる作業と合わせて実装中です。いまの設定は既定値です。
- 候補一覧のナレーターへの読み上げには未対応です。
- WindowsのSwiftは検査付き（+Asserts）の版だけが配布されており、依存ライブラリの最適化中に検査が止まるため、SIL検証を外してビルドしています（Linuxの通常版と同じ条件）。
- Smart App Controlが有効な機械では、署名のない実行ファイル・DLLが止められることがあります。開発機（Core i3-10100T、Smart App Control有効）では、2026-10-22 20:44 JSTごろから、新しくビルドした実行ファイル（Zenzai付きのブリッジ、試験、SwiftPMの`core-manifest.exe`）が毎回止められるようになりました（Code Integrity 3077）。そのためZenzai付きのブリッジの実行と計測は、GitHubのCIだけで行いました。配布するにはコード署名が必要です。
- 自動試験はRichEditで行っています。メモ帳、Edge、Word、ストアアプリなどの実アプリでの入力、高DPIの複数画面、フォーカス移動時の確定は確認がまだです。
