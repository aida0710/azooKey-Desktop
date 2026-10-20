import Core
import Foundation
import KanaKanjiConverterModule
import Testing

@Suite struct CandidateConsumptionTests {
    private func composition(_ input: String, style: InputStyle = .mapped(id: .defaultRomanToKana)) -> CompositionState {
        var composition = CompositionState()
        composition.insertAtCursorPosition(input, inputStyle: style)
        return composition
    }

    @Test func partialConsumptionKeepsTheFormalSuffixEditable() throws {
        let original = composition("nihongowobenkyou")
        let before = try CompositionSnapshot.capture(original).encoded()
        let consumed = try CandidateConsumption(composition: original, count: .init(.inputCount(2)))
        #expect(consumed.consumedReading == "に")
        #expect(consumed.remaining.convertTarget == "ほんごをべんきょう")
        var remaining = consumed.remaining
        remaining.moveCursor(.start)
        remaining.insertAtCursorPosition("a", inputStyle: .mapped(id: .defaultRomanToKana))
        #expect(remaining.convertTarget == "あほんごをべんきょう")
        #expect(try CompositionSnapshot.capture(original).encoded() == before)
    }

    @Test func surfaceConsumptionRetainsTheRemainderOfASplitKana() throws {
        var original = composition("kyou")
        original.editSegment(count: -1)
        original.editSegment(count: -1)
        #expect(original.conversionRangeEnd == 1)
        let consumed = try CandidateConsumption(composition: original, count: .init(.surfaceCount(1)))
        #expect(consumed.consumedReading == "き")
        #expect(consumed.remaining.convertTarget == "ょう")
        var remaining = consumed.remaining
        remaining.deleteBackwardFromCursorPosition()
        #expect(remaining.convertTarget == "ょ")
    }

    @Test func aCandidateCannotConsumePastTheCurrentSegment() throws {
        var original = composition("nihongo")
        original.editSegment(count: -2)
        #expect(original.conversionRangeEnd == 2)
        let before = try CompositionSnapshot.capture(original).encoded()
        #expect(throws: CandidateConsumption.Failure.outsideConversionRange) {
            try CandidateConsumption(composition: original, count: .init(.inputCount(7)))
        }
        #expect(try CompositionSnapshot.capture(original).encoded() == before)
    }

    @Test func anInputCountInsideARomanSyllableCannotRewriteTheRemainingReading() throws {
        let original = composition("nihongo")
        let before = try CompositionSnapshot.capture(original).encoded()
        #expect(throws: CandidateConsumption.Failure.inconsistentSuffix) {
            try CandidateConsumption(composition: original, count: .init(.inputCount(1)))
        }
        #expect(try CompositionSnapshot.capture(original).encoded() == before)
    }

    @Test func compositeConsumptionChecksEachLeafAndTheResultingRange() throws {
        let original = composition("nihongo")
        let count = ComposingCount.composite(lhs: .inputCount(2), rhs: .surfaceCount(1))
        let consumed = try CandidateConsumption(composition: original, count: .init(count))
        #expect(consumed.composingCount == count)
        #expect(consumed.consumedReading == "にほ")
        #expect(consumed.remaining.convertTarget == "んご")
        #expect(throws: CompositionSnapshotError.invalidValue("surfaceCount")) {
            try CandidateConsumption(composition: original, count: .init(.composite(
                lhs: .inputCount(2), rhs: .surfaceCount(4))))
        }
    }

    @Test(arguments: [ComposingCount.inputCount(0), .surfaceCount(0)])
    func zeroConsumptionCannotCreateAnOrdinaryConversionCommit(count: ComposingCount) throws {
        let original = composition("nihongo")
        #expect(throws: CandidateConsumption.Failure.noReadingConsumed) {
            try CandidateConsumption(composition: original, count: .init(count))
        }
    }

    @Test func emptyInputCannotAcceptAConversionCandidate() throws {
        #expect(throws: CandidateConsumption.Failure.emptyComposition) {
            try CandidateConsumption(composition: CompositionState(), count: .init(.inputCount(0)))
        }
    }

    @Test(arguments: ["👩‍💻", "e\u{301}", "🇯🇵", "𠮷"])
    func consumptionUsesGraphemesAndPreservesActualSuffixScalars(grapheme: String) throws {
        let original = composition(grapheme + "e\u{301}", style: .direct)
        let consumed = try CandidateConsumption(composition: original, count: .init(.surfaceCount(1)))
        #expect(consumed.consumedReading.utf8.elementsEqual(grapheme.utf8))
        #expect(consumed.remaining.convertTarget.utf8.elementsEqual("e\u{301}".utf8))
        let complete = try CandidateConsumption(composition: original, count: .init(.surfaceCount(2)))
        #expect(complete.remaining.isEmpty)
    }
}
