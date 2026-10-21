import Core
@testable import DesktopBridge
import KanaKanjiConverterModule
import Testing

@MainActor
@Suite struct DesktopCandidateMainUnicodeTests {
    @Test(arguments: ["text", "word", "ruby"])
    func canonicallyEquivalentBytesCannotStandInForTheOriginalMain(field: String) throws {
        let original = Candidate(text: "é", value: -1, composingCount: .inputCount(7), lastMid: 0,
                                 data: [.init(word: "é", ruby: "バ", cid: 0, mid: 0, value: -1)])
        var equivalent = original
        switch field {
        case "text": equivalent.text = "e\u{301}"
        case "word": equivalent.data[0].word = "e\u{301}"
        default: equivalent.data[0].ruby = "ハ\u{3099}"
        }
        // Upstream's value equality intentionally follows Swift's canonical String equality.
        #expect(original == equivalent)
        let composition = DesktopCandidateTestSupport.composition("nihongo")
        let other = try DesktopCandidateConversion.StoredItem(presentation: .init(candidate: equivalent), composition: composition)
        let exact = try DesktopCandidateConversion.StoredItem(presentation: .init(candidate: original), composition: composition)
        #expect(DesktopCandidateConversion.mainCandidateID(original, in: [other]) == nil)
        #expect(DesktopCandidateConversion.mainCandidateID(original, in: [other, exact]) == exact.item.candidateID)
    }
}
