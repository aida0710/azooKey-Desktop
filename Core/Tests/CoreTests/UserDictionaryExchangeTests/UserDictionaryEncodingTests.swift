@testable import Core
import Foundation
import Testing

@Suite("辞書交換テキストの文字コード")
struct UserDictionaryEncodingTests {
    @Test("UTF8とBOM付きUTF16の両バイト順で同じ項目と物理行を得る",
          arguments: ["mozc.txt", "mozc-utf16le.txt", "mozc-utf16be.txt"])
    func automaticDecodingPreservesAllScalarsAndLineNumbers(file: String) throws {
        let expected = try UserDictionaryExchange.parse(
            UserDictionaryExchangeFixture.content("mozc.txt"), format: .mozc
        )
        let actual = try UserDictionaryExchange.parse(
            UserDictionaryExchangeFixture.content(file), format: .mozc
        )
        #expect(actual.encoding == (file == "mozc.txt" ? .utf8 : .utf16))
        #expect(actual.rows.map(\.sourceLine) == expected.rows.map(\.sourceLine))
        #expect(actual.rows.map { $0.item?.reading } == expected.rows.map { $0.item?.reading })
        #expect(actual.rows.map { $0.item?.word } == expected.rows.map { $0.item?.word })
        #expect(actual.rows.map { $0.item?.hint } == expected.rows.map { $0.item?.hint })
    }

    @Test("UTF8のBOMはヘッダーの一部にせず明示UTF8でも読み込める")
    func utf8ByteOrderMarkIsRemoved() throws {
        var content = Data([0xEF, 0xBB, 0xBF])
        content.append(try UserDictionaryExchangeFixture.content("atok2017.txt"))
        for encoding in [UserDictionaryExchange.TextEncoding.automatic, .utf8] {
            let document = try UserDictionaryExchange.parse(content, format: .atok2017, encoding: encoding)
            #expect(document.rows.count == 4)
            #expect(document.encoding == .utf8)
        }
    }

    @Test("ShiftJISを明示した場合だけ受け入れ自動判定では推測しない")
    func shiftJISRequiresExplicitSelection() throws {
        let content = try UserDictionaryExchangeFixture.content("atok2017-shift-jis.txt")
        let document = try UserDictionaryExchange.parse(content, format: .atok2017, encoding: .shiftJIS)
        #expect(try UserDictionaryExchangeFixture.entry(document.rows[0]).word == "合成語甲")
        #expect(try UserDictionaryExchangeFixture.entry(document.rows[0]).hint == "合成コメント")
        #expect(document.rows.map(\.sourceLine) == [3, 4, 5, 6])
        #expect(document.encoding == .shiftJIS)
        #expect(throws: UserDictionaryExchange.Failure.unknownEncoding) {
            _ = try UserDictionaryExchange.parse(content, format: .atok2017)
        }
    }

    @Test("不完全なバイト列と別文字コードを置換文字で修復しない",
          arguments: [
            (Data([0xC3]), UserDictionaryExchange.TextEncoding.utf8),
            (Data([0x82]), .shiftJIS),
            (Data([0x82, 0x20]), .shiftJIS),
            (Data([0xFF, 0xFE, 0x42]), .utf16),
            (Data([0xFF, 0xFE, 0x00, 0xD8]), .utf16),
            (Data([0xFE, 0xFF, 0xDC, 0x00]), .utf16),
            (Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00]), .utf16),
            (Data([0x41, 0x00]), .utf16),
            (Data([0xEF, 0xBB, 0xBF, 0x41]), .shiftJIS),
            (Data([0xFF, 0xFE, 0x41, 0x00]), .utf8)
          ])
    func malformedEncodingsAreRejected(example: (Data, UserDictionaryExchange.TextEncoding)) throws {
        #expect(throws: UserDictionaryExchange.Failure.self) {
            _ = try UserDictionaryExchange.parse(example.0, format: .mozc, encoding: example.1)
        }
    }

    @Test("UTF32とバイナリのNULを対応テキストとして扱わない",
          arguments: [Data([0xFF, 0xFE, 0x00, 0x00]), Data([0x00, 0x00, 0xFE, 0xFF]), Data([0x41, 0x00, 0x42])])
    func unsupportedBinaryInputsAreRejected(content: Data) throws {
        #expect(throws: UserDictionaryExchange.Failure.self) {
            _ = try UserDictionaryExchange.parse(content, format: .mozc)
        }
    }
}
