# 画面の文言の共通カタログ

画面・読み上げ・通知に出す文言は、日本語と英語の正本を `Shared/Messages/` に置き、各OS向けの表を `Tools/generate-messages.py` で生成する。生成した表もコミットする。生成物を直接書き換えない。

## 正本の置き場所

`Shared/Messages/<表>/<区分>.json` に置く。表は次の2つ。

| 表 | 引き方 | 区分 |
| --- | --- | --- |
| `Localizable` | Swift `Localization.text`、Python `i18n.text`、GNOME 拡張 `messages` | キーの先頭（`candidate`、`settings` など）ごとのファイル |
| `UserDictionary` | Swift `UserDictionaryMessages.text`、Python のユーザー辞書画面 | `userDictionary.json` の1つ |

同じ表の中でキーは重複できない。区分のファイル分けは、並行して文言を足すときに同じファイルを触らないためのもので、キーの意味は変えない。

## 1件の書き方

```json
"candidate.position": {
  "ja": "変換候補 {position} / {total}",
  "en": "Candidates {position} / {total}",
  "gjs": "position"
}
```

- `ja` と `en` は必須。すべてのOSでこの文言を使う。
- 置き換える値は `{名前}` と書く。macOS で整数として `%d` に渡す値だけ `{名前:d}` と書く。同じ1件の中の文言は、すべて同じ置き換えを使う。波括弧そのものは書けない。
- 値の並び順は、基本の `ja` に最初に出てくる順。macOS の `String(format:)` にはこの順に渡す。英語で語順が変わる場合は、生成時に `%2$@` のような位置指定へ変える。
- OSによって言い方を変える必要があるときだけ、`macos`・`linux`・`windows` に `ja` と `en` の両方を書く。例: Linux と Windows は「Ctrl」、macOS は「Control」。
- `gjs` は GNOME 拡張の `messages` での名前。値がある文言は関数として出力する（`messages.position(1, 9)`）。
- `note` には、書く人向けの補足を書ける。生成物には出ない。
- もともと英語の画面名や区分名（`OS`、`AI`、`API キー`、`azooKey JSON` など）は、日本語の文言でも英語のまま残す。

## 生成先

| 生成物 | 使う側 | 選ぶ文言 |
| --- | --- | --- |
| `Core/Sources/Core/Resources/{ja,en}.lproj/*.strings` | macOS アプリと Core（Linux・Windows のブリッジも含む） | 基本＋`macos` |
| `Linux/azookey/locales/ja.json`、`user_dictionary.ja.json` | Linux の Python | 基本＋`linux` |
| `Linux/gnome-extension/candidateMessages.js` | GNOME 拡張（`gjs` のある文言だけ） | 基本＋`linux` |
| `Windows/src/shared/message_catalog_data.h` | Windows の C++（`{名前}` のまま、日本語と英語） | 基本＋`windows` |

Core がブリッジ経由で返す文言は `.strings` から引くため、`macos` の言い方になる。Linux や Windows で言い方を変えたい文言は、Core で文面を組み立てず、各OSの表から引く。Core が文言を返すときは、画面の言語を要求で受け取り `Localization.text(_:language:)` で引く。

## Windows（C++）での引き方

`Windows/src/shared/message_catalog_data.h` は表のほかに、次の関数を含む（名前空間 `azookey::messages`）。

```cpp
Language LanguageForLocaleName(std::wstring_view localeName);
const MessageEntry* FindMessage(std::string_view key, Table table = Table::Localizable);
std::wstring Text(std::string_view key, Language language,
                  std::initializer_list<std::pair<std::wstring_view, std::wstring_view>> values = {},
                  Table table = Table::Localizable);
```

- 表示言語は、利用者の UI 言語が日本語（`ja`、`ja-JP` など）なら日本語、それ以外は英語とする。`GetUserPreferredUILanguages` の先頭などの BCP 47 の名前を `LanguageForLocaleName` に渡す。
- `Text("candidate.position", language, {{L"position", L"2"}, {L"total", L"9"}})` のように `{名前}` を置き換える。未知のキーはキーそのものを返し、抜けが画面で分かるようにする。
- 生成物の動作は `Tools/tests/test-message-catalog.cpp` で確かめる（CI の `generated-data`）。

## 手順と検査

```bash
python3 Tools/generate-messages.py          # 生成物を書き直す
python3 Tools/generate-messages.py --check  # 正本と生成物の一致を検査する（不一致で終了コード1）
python3 Tools/tests/test-generate-messages.py
```

正本の形式の誤り（言語の欠け、置き換えの不一致、重複したキー）は終了コード2で止まる。CI の `generated-data` と `Tools/test-linux.sh` でも同じ検査を行う。
