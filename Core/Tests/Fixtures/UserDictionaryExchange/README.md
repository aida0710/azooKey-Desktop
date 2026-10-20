# 辞書交換形式の合成fixture

個人の辞書・実ATOK・実Mozcのデータは使用していない。実製品の書出しから取り込む往復確認は未検証。

- `atok2017.txt`: UTF-8、ATOK 2017ヘッダー、注釈、名詞、登録種別の`*`/`$`、4列目のコメント、未対応の活用語・置換情報。
- `atok2017-shift-jis.txt`: 上記テキストをPythonの`shift_jis`で符号化した同内容。自動判定しない。
- `mozc.txt`: UTF-8、注釈、名詞、コメント、列不足、不正な読み、重複と衝突。
- `mozc-utf16le.txt` / `mozc-utf16be.txt`: 同じMozcテキストをBOM付きUTF-16の各バイト順で符号化。絵文字はサロゲートペアの確認にも使う。

ATOKの2ファイルの4行目にある末尾タブは、4列目が空文字のコメントであることを検証するデータ。末尾の空白として削除しない。

JSONのタブ・改行・空ヒント・欠落ヒント・元のUnicode表現はテスト内で生成する。性能試験用の1,000語も固定の生成規則をテスト内に持つ。

対応範囲の一次資料（2026-10-20確認）:

- [ATOK 2017の単語ファイル書式](https://support.justsystems.com/faq/1032/app/servlet/qadoc?QID=056444)
- [ATOKの名詞の種類と番号](https://www.atok.com/other/support/howtouse/mac/shrd/shrd_hinsi_meisi.htm)
- [ATOK出力時の文字コード・登録種別・コメント](https://www.atok.com/other/support/howtouse/mac/mn/pgs/mn_tool_ut_out_word_out_d.htm)
- [Mozcのテキスト取込](https://github.com/google/mozc/blob/master/src/client/user_dictionary/user_dictionary_importer.cc)
- [Mozcの品詞定義](https://github.com/google/mozc/blob/master/src/data/rules/user_pos.def)

ATOKは名詞と固有名詞系の名前・番号1〜8、Mozcは名詞・固有名詞・人名・姓・名・組織・地名に限る。azooKey側では受け入れた語をすべて固有名詞として登録し、元の品詞は保持しない。この方針は取込プレビューにもnoticeで返す。
