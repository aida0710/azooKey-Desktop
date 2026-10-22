@testable import Core
import Foundation
import Testing

@Suite("公開テキスト形式の限定取込")
struct UserDictionaryTextImportTests {
    @Test("ATOKの物理行・登録種別・コメントを区別し活用語と置換情報を除外する")
    func atokRowsKeepTheirLineNumbersAndSeparateCommentsFromPartOfSpeech() throws {
        let document = try UserDictionaryExchange.parse(
            UserDictionaryExchangeFixture.content("atok2017.txt"), format: .atok2017
        )
        #expect(document.rows.map(\.sourceLine) == [3, 4, 5, 6])
        #expect(try UserDictionaryExchangeFixture.entry(document.rows[0]).hint == "合成コメント")
        #expect(try UserDictionaryExchangeFixture.entry(document.rows[1]).hint?.isEmpty == true)
        #expect(document.rows[0].partOfSpeech == "名詞*")
        #expect(document.rows[1].partOfSpeech == "固有一般$")
        #expect(document.rows[2].problem == .unsupportedPartOfSpeech)
        #expect(document.rows[3].problem == .unsupportedFields)
        #expect(document.notices == [.properNounRegistration])
    }

    @Test("Mozcの3列目をヒントへ流用せず空の列と列不足を保持する")
    func mozcCommentsAndMalformedRowsAreNotSilentlyDropped() throws {
        let document = try UserDictionaryExchange.parse(
            UserDictionaryExchangeFixture.content("mozc.txt"), format: .mozc
        )
        #expect(document.rows.count == 7)
        #expect(document.rows.map(\.sourceLine) == Array(2...8).map(Optional.some))
        #expect(try UserDictionaryExchangeFixture.entry(document.rows[1]).hint == nil)
        #expect(document.rows[2].problem == .invalidColumns)
        #expect(try UserDictionaryExchangeFixture.entry(document.rows[4]).reading.isEmpty)
    }

    @Test("公開名詞名とATOK番号を受け入れ未知品詞を名詞へ推測変換しない")
    func onlyTheDocumentedNounCategoriesAreAccepted() throws {
        let atokNouns = ["名詞", "固有人姓", "固有人名", "固有人他", "固有地名", "固有組織", "固有商品", "固有一般"]
        let atokTypes = atokNouns + (1...8).map(String.init) + ["名詞サ変", "9", "名詞*$", "不明"]
        let atok = "!!atok_tango_text_header_1\r\n" + atokTypes.map { "てすと\t合成語\t\($0)" }.joined(separator: "\r\n")
        let atokDocument = try UserDictionaryExchange.parse(Data(atok.utf8), format: .atok2017)
        #expect(atokDocument.rows.prefix(16).allSatisfy { $0.problem == nil })
        #expect(atokDocument.rows.suffix(4).allSatisfy { $0.problem == .unsupportedPartOfSpeech })
        let mozcTypes = ["名詞", "固有名詞", "人名", "姓", "名", "組織", "地名", "名詞サ変", "短縮よみ", "名詞*"]
        let mozc = try UserDictionaryExchangeFixture.document(mozcTypes.map { "てすと\t合成語\t\($0)" }.joined(separator: "\n"))
        #expect(mozc.rows.prefix(7).allSatisfy { $0.problem == nil })
        #expect(mozc.rows.suffix(3).allSatisfy { $0.problem == .unsupportedPartOfSpeech })
    }

    @Test("旧ATOKと別形式のヘッダーをATOK2017やMozcとして読み込まない",
          arguments: ["!!DICUT10\nてすと\t語\t名詞", "!Microsoft IME Dictionary Tool\nてすと\t語\t名詞"])
    func unrelatedAndOldFormatsAreRejected(text: String) throws {
        for format in [UserDictionaryExchange.Format.atok2017, .mozc] {
            #expect(throws: UserDictionaryExchange.Failure.unsupportedFormat) {
                _ = try UserDictionaryExchange.parse(Data(text.utf8), format: format)
            }
        }
    }

    @Test("Mozc注釈の後ろに旧形式ヘッダーがあってもデータ行として取り込まない")
    func aLeadingCommentDoesNotHideAnUnsupportedHeader() throws {
        let text = "# comment\n!!DICUT10\nてすと\t合成語\t名詞"
        #expect(throws: UserDictionaryExchange.Failure.unsupportedFormat) {
            _ = try UserDictionaryExchange.parse(Data(text.utf8), format: .mozc)
        }
    }
}
