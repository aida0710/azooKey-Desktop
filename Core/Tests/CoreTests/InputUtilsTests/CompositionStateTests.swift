import Core
import Foundation
import KanaKanjiConverterModule
import Testing

@MainActor
@Suite struct CompositionStateTests {
    struct InputExample: Sendable {
        let style: InputStyle
        let pieces: [InputPiece]
        let reading: String

        init(style: InputStyle, input: String, reading: String) {
            self.style = style
            self.pieces = input.map(InputPiece.character)
            self.reading = reading
        }

        init(style: InputStyle, pieces: [InputPiece], reading: String) {
            self.style = style
            self.pieces = pieces
            self.reading = reading
        }

        static let examples: [Self] = [
            .init(style: .roman2kana, input: "nihongo", reading: "にほんご"),
            .init(style: .mapped(id: .defaultRomanToKana), input: "nihongo", reading: "にほんご"),
            .init(style: .mapped(id: .defaultAZIK), input: "kz", reading: "かん"),
            // UserAction retains the physical symbol and supplies its Japanese intention.
            .init(style: .mapped(id: .defaultKanaJIS), pieces: [
                .key(intention: nil, input: "t", modifiers: []),
                .key(intention: "＠", input: "@", modifiers: [])
            ], reading: "が"),
            .init(style: .mapped(id: .defaultKanaUS), pieces: [
                .key(intention: nil, input: "t", modifiers: []),
                .key(intention: "「", input: "[", modifiers: [])
            ], reading: "が"),
            .init(style: .mapped(id: .defaultKanaJIS),
                  pieces: [.key(intention: "0", input: "0", modifiers: [.shift])], reading: "を"),
            .init(style: .mapped(id: .defaultKanaUS), input: "）", reading: "を"),
            .init(style: .direct, input: "👩‍💻e\u{301}", reading: "👩‍💻e\u{301}")
        ]
    }

    @Test(arguments: InputExample.examples)
    func inputStylesPreserveTheirFormalReadingAndOriginalPieces(example: InputExample) {
        var composition = CompositionState()
        for piece in example.pieces {
            composition.insertAtCursorPosition(pieces: [piece], inputStyle: example.style)
        }
        #expect(composition.convertTarget == example.reading)
        #expect(composition.composingText.input.map(\.piece) == example.pieces)
        #expect(composition.composingText.input.allSatisfy { $0.inputStyle == example.style })
        #expect(composition.lastInputStyle == example.style)
        #expect(composition.composingText.convertTargetCursorPosition == example.reading.count)
        #expect(composition.readingCursorUTF16Offset == example.reading.utf16.count)
    }

    @Test func middleEditsAndBoundaryDeletesPreserveTheUneditedSuffix() {
        var composition = CompositionState()
        composition.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        composition.moveCursor(.backward)
        composition.insertAtCursorPosition("a", inputStyle: .roman2kana)
        #expect(composition.convertTarget == "にほんあご")
        #expect(composition.readingCursorUTF16Offset == 4)
        composition.deleteBackwardFromCursorPosition()
        #expect(composition.convertTarget == "にほんご")
        composition.deleteForwardFromCursorPosition()
        #expect(composition.convertTarget == "にほん")
        composition.moveCursor(.start)
        composition.deleteBackwardFromCursorPosition()
        #expect(composition.readingCursorUTF16Offset == 0)
        #expect(composition.convertTarget == "にほん")
        composition.insertAtCursorPosition("ka", inputStyle: .roman2kana)
        #expect(composition.convertTarget == "かにほん")
        composition.moveCursor(.end)
        composition.deleteForwardFromCursorPosition()
        #expect(composition.convertTarget == "かにほん")
        #expect(composition.readingCursorUTF16Offset == 4)
    }

    @Test(arguments: ["👩‍💻", "𠮷", "e\u{301}", "🇯🇵"])
    func cursorAndDeletionKeepWholeGraphemes(grapheme: String) {
        var composition = CompositionState()
        composition.insertAtCursorPosition(grapheme, inputStyle: .direct)
        composition.insertAtCursorPosition("ka", inputStyle: .roman2kana)
        composition.moveCursor(.backward)
        #expect(composition.convertTarget == grapheme + "か")
        #expect(composition.composingText.convertTargetCursorPosition == 1)
        #expect(composition.readingCursorUTF16Offset == grapheme.utf16.count)
        composition.deleteBackwardFromCursorPosition()
        #expect(composition.convertTarget == "か")
        #expect(composition.readingCursorUTF16Offset == 0)
        composition.deleteForwardFromCursorPosition()
        #expect(composition.isEmpty)
    }

    @Test func customMappingKeepsItsOriginalKeysWhenTheInputIsEditable() {
        let tableName = "CompositionStateTests.\(UUID().uuidString)"
        let table = InputTable(baseMapping: [
            [.piece(.character("x")), .piece(.character("y"))]: [.character("き"), .character("ょ")],
            [.piece(.character("a"))]: [.character("あ")]
        ] as Dictionary)
        InputStyleManager.registerInputStyle(table: table, for: tableName)
        let style = InputStyle.mapped(id: .tableName(tableName))
        var composition = CompositionState()
        composition.insertAtCursorPosition("xy", inputStyle: style)
        #expect(composition.convertTarget == "きょ")
        #expect(composition.composingText.input.map(\.piece) == [.character("x"), .character("y")])
        composition.moveCursor(.backward)
        composition.insertAtCursorPosition("a", inputStyle: style)
        #expect(composition.convertTarget == "きあょ")
        #expect(composition.readingCursorUTF16Offset == 2)
        composition.deleteBackwardFromCursorPosition()
        #expect(composition.convertTarget == "きょ")
        composition.deleteForwardFromCursorPosition()
        #expect(composition.convertTarget == "き")
    }

    @Test func separatorCompletesNasalReadingOnceAndReturnsTheCursorToTheEnd() {
        var composition = CompositionState()
        composition.insertAtCursorPosition("kan", inputStyle: .roman2kana)
        composition.moveCursor(.start)
        let inserted = composition.insertCompositionSeparator(inputStyle: .roman2kana)
        #expect(inserted)
        #expect(composition.convertTarget == "かん")
        #expect(composition.readingCursorUTF16Offset == 2)
        let inputCount = composition.composingText.input.count
        composition.editSegment(count: -1)
        let insertedAgain = composition.insertCompositionSeparator(inputStyle: .direct)
        #expect(!insertedAgain)
        #expect(composition.conversionRangeEnd == nil)
        #expect(composition.composingText.input.count == inputCount)
        #expect(composition.lastInputStyle == .roman2kana)
    }

    @Test func readingEditsAndCancellationFinishWhileAConversionSnapshotHasNoReply() async throws {
        var composition = CompositionState()
        composition.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        let snapshot = composition.conversionTarget
        let (requests, requested) = AsyncStream<ComposingText>.makeStream()
        let (replies, release) = AsyncStream<Void>.makeStream()
        let conversion = Task.detached {
            requested.yield(snapshot)
            for await _ in replies { break }
            return snapshot
        }
        defer {
            release.finish()
            requested.finish()
            conversion.cancel()
        }
        var incoming = requests.makeAsyncIterator()
        let held = try #require(await incoming.next())
        // No reply is released until all edits and cancellation have completed.
        composition.moveCursor(.backward)
        composition.insertAtCursorPosition("a", inputStyle: .roman2kana)
        composition.deleteBackwardFromCursorPosition()
        composition.deleteForwardFromCursorPosition()
        #expect(composition.convertTarget == "にほん")
        composition.stopComposition()
        #expect(composition.isEmpty)
        #expect(composition.readingCursorUTF16Offset == 0)
        #expect(composition.conversionRangeEnd == nil)
        #expect(composition.lastInputStyle == .direct)
        #expect(held.convertTarget == "にほんご")
        release.yield(())
        let late = await conversion.value
        #expect(late.convertTarget == "にほんご")
        #expect(composition.isEmpty)
        composition.insertAtCursorPosition("ka", inputStyle: .roman2kana)
        #expect(composition.convertTarget == "か")
    }
}
