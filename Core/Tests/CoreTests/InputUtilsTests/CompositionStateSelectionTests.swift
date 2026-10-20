import Core
import KanaKanjiConverterModule
import Testing

@MainActor
@Suite struct CompositionStateSelectionTests {
    @Test func segmentRangeUsesTheSelectedConsumptionAndPreservesTheWholeReading() {
        var composition = CompositionState()
        composition.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        composition.editSegment(count: -1)
        #expect(composition.conversionTarget.convertTarget == "にほん")
        #expect(composition.convertTarget == "にほんご")
        composition.editSegment(count: 1, selectedCount: .inputCount(2))
        #expect(composition.conversionTarget.convertTarget == "にほ")
        composition.moveCursor(.start)
        #expect(composition.conversionRangeEnd == nil)
        #expect(composition.convertTarget == "にほんご")
        #expect(composition.readingCursorUTF16Offset == 0)
    }

    @Test func aPrefixInsideOneRomanSyllableDoesNotRewriteTheLiveInput() {
        var composition = CompositionState()
        composition.insertAtCursorPosition("kyo", inputStyle: .roman2kana)
        composition.editSegment(count: -1)
        var prefix = composition.conversionTarget
        #expect(prefix.convertTarget == "き")
        prefix.stopComposition()
        #expect(composition.convertTarget == "きょ")
        #expect(composition.composingText.input.map(\.piece) == Array("kyo").map(InputPiece.character))
        composition.prefixComplete(composingCount: .surfaceCount(1))
        #expect(composition.convertTarget == "ょ")
        #expect(composition.readingCursorUTF16Offset == 1)
        #expect(composition.conversionRangeEnd == nil)
    }

    @Test func romanSelectionKeepsOriginalKeysWhenAFormalBoundaryExists() {
        let scenarios = [
            (input: "kyo", prefix: "き", suffix: "ょ"),
            (input: "kanta", prefix: "kan", suffix: "た"),
            (input: "nihongo", prefix: "nihon", suffix: "ご"),
            (input: "kitte", prefix: "kit", suffix: "て")
        ]
        for scenario in scenarios {
            var composition = CompositionState()
            composition.insertAtCursorPosition(scenario.input, inputStyle: .roman2kana)
            composition.editSegment(count: -1)
            let selection = composition.romanInputForSelection()
            #expect(selection.text == scenario.prefix)
            composition.prefixComplete(composingCount: selection.composingCount)
            #expect(composition.convertTarget == scenario.suffix)
            #expect(composition.readingCursorUTF16Offset == scenario.suffix.utf16.count)
        }
    }

    @Test func compositeConsumptionLeavesExactlyTheRemainingFormalInput() {
        var composition = CompositionState()
        composition.insertAtCursorPosition("nikyogo", inputStyle: .roman2kana)
        let consumption = ComposingCount.composite(lhs: .inputCount(2), rhs: .surfaceCount(1))
        #expect(!composition.consumesWholeComposition(composingCount: consumption))
        composition.moveCursor(.start)
        composition.prefixComplete(composingCount: consumption)
        #expect(composition.convertTarget == "ょご")
        #expect(composition.readingCursorUTF16Offset == 2)
        #expect(composition.consumesWholeComposition(composingCount: .surfaceCount(2)))
        composition.prefixComplete(composingCount: .surfaceCount(2))
        #expect(composition.isEmpty)
        #expect(composition.readingCursorUTF16Offset == 0)
    }

    @Test func checkpointKeepsReadingStyleRangeAndCursorAfterTheLiveStateChanges() throws {
        var composition = CompositionState()
        #expect(composition.checkpoint() == nil)
        composition.insertAtCursorPosition("nihongo", inputStyle: .mapped(id: .defaultRomanToKana))
        composition.moveCursor(.backward)
        composition.editSegment(count: -1)
        let checkpoint = try #require(composition.checkpoint(selectedText: "日本"))
        composition.stopComposition()
        let restored = CompositionState(checkpoint: checkpoint)
        #expect(restored.convertTarget == "にほんご")
        #expect(restored.lastInputStyle == .mapped(id: .defaultRomanToKana))
        #expect(restored.conversionRangeEnd == 3)
        #expect(restored.conversionTarget.convertTarget == "にほん")
        #expect(restored.readingCursorUTF16Offset == 3)
        #expect(restored.composingText.input.map(\.piece) == Array("nihongo").map(InputPiece.character))
        #expect(composition.isEmpty)
    }

    @Test func emptyAndClampedSegmentEditsNeverCreateInput() {
        var composition = CompositionState()
        composition.editSegment(count: 1)
        #expect(composition.conversionRangeEnd == nil)
        composition.insertAtCursorPosition("kyo", inputStyle: .roman2kana)
        composition.editSegment(count: -10)
        #expect(composition.conversionRangeEnd == 1)
        composition.editSegment(count: 10)
        #expect(composition.conversionRangeEnd == 2)
        #expect(composition.convertTarget == "きょ")
    }
}
