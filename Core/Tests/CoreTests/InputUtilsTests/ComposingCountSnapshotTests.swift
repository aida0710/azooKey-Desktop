import Core
import Foundation
import KanaKanjiConverterModule
import Testing

@MainActor
@Suite struct ComposingCountSnapshotTests {
    @Test func eachCountKindRoundTripsAndConsumesOnlyItsFormalPrefix() throws {
        let scenarios: [(ComposingCount, String)] = [
            (.inputCount(2), "きょご"),
            (.surfaceCount(1), "きょご"),
            (.composite(lhs: .inputCount(2), rhs: .surfaceCount(1)), "ょご"),
            (.composite(lhs: .surfaceCount(1), rhs: .composite(lhs: .inputCount(3), rhs: .surfaceCount(1))), "")
        ]
        for (count, suffix) in scenarios {
            var composition = CompositionState()
            composition.insertAtCursorPosition("nikyogo", inputStyle: .roman2kana)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(ComposingCountSnapshot(count))
            let decoded = try JSONDecoder().decode(ComposingCountSnapshot.self, from: encoded)
            #expect(decoded.composingCount == count)
            #expect(try encoder.encode(decoded) == encoded)
            composition.prefixComplete(composingCount: try decoded.validated(for: composition))
            #expect(composition.convertTarget == suffix)
            #expect(composition.readingCursorUTF16Offset == suffix.utf16.count)
        }
    }

    @Test func laterLeavesAreBoundedAgainstTheRemainingInput() throws {
        var composition = CompositionState()
        composition.insertAtCursorPosition("nikyogo", inputStyle: .roman2kana)
        let invalid: [ComposingCount] = [
            .inputCount(8), .surfaceCount(5),
            .composite(lhs: .inputCount(2), rhs: .surfaceCount(4)),
            .composite(lhs: .surfaceCount(4), rhs: .inputCount(1))
        ]
        for count in invalid {
            let snapshot = try ComposingCountSnapshot(count)
            #expect(throws: (any Error).self) { try snapshot.validated(for: composition) }
            #expect(composition.convertTarget == "にきょご")
            #expect(composition.composingText.input.map(\.piece) == Array("nikyogo").map(InputPiece.character))
        }
    }

    @Test func zeroConsumptionKeepsAnEmptyOrNonemptyComposition() throws {
        let zero = try ComposingCountSnapshot(.composite(lhs: .inputCount(0), rhs: .surfaceCount(0)))
        var composition = CompositionState()
        #expect(try zero.validated(for: composition) == zero.composingCount)
        composition.insertAtCursorPosition("ka", inputStyle: .roman2kana)
        #expect(try zero.validated(for: composition) == zero.composingCount)
        #expect(composition.convertTarget == "か")
    }

    @Test(arguments: [
        #"{"kind":"unknown","count":1}"#,
        #"{"kind":"inputCount","count":-1}"#,
        #"{"kind":"surfaceCount","count":-1}"#,
        #"{"kind":"inputCount","count":1.5}"#,
        #"{"kind":"inputCount","count":16385}"#,
        #"{"kind":"surfaceCount","count":16385}"#,
        #"{"kind":"composite","lhs":{"kind":"inputCount","count":0}}"#
    ])
    func invalidWireCountsAreRejectedBeforeApplication(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ComposingCountSnapshot.self, from: Data(json.utf8))
        }
    }

    @Test func invalidLocalCountsAreAlsoRejected() {
        #expect(throws: CompositionSnapshotError.invalidValue("negativeCount")) {
            try ComposingCountSnapshot(.inputCount(-1))
        }
        #expect(throws: CompositionSnapshotError.limitExceeded("composingCount")) {
            try ComposingCountSnapshot(.surfaceCount(Int.max))
        }
    }

    @Test func recursiveDepthIsBoundedDuringDecodingAndCapture() throws {
        let leaf = #"{"kind":"inputCount","count":0}"#
        var json = leaf
        var count = ComposingCount.inputCount(0)
        for _ in 1..<CompositionSnapshotLimits.composingCountDepth {
            json = #"{"kind":"composite","lhs":\#(json),"rhs":\#(leaf)}"#
            count = .composite(lhs: count, rhs: .inputCount(0))
        }
        _ = try JSONDecoder().decode(ComposingCountSnapshot.self, from: Data(json.utf8))
        _ = try ComposingCountSnapshot(count)
        json = #"{"kind":"composite","lhs":\#(json),"rhs":\#(leaf)}"#
        count = .composite(lhs: count, rhs: .inputCount(0))
        #expect(throws: CompositionSnapshotError.limitExceeded("composingCountDepth")) {
            try JSONDecoder().decode(ComposingCountSnapshot.self, from: Data(json.utf8))
        }
        #expect(throws: CompositionSnapshotError.limitExceeded("composingCountDepth")) {
            try ComposingCountSnapshot(count)
        }
    }

    @Test func broadCountTreesCannotBypassTheNodeLimit() throws {
        var json = #"{"kind":"surfaceCount","count":0}"#
        var count = ComposingCount.surfaceCount(0)
        // Six balanced levels contain exactly 127 nodes without approaching the depth limit.
        for _ in 0..<6 {
            json = #"{"kind":"composite","lhs":\#(json),"rhs":\#(json)}"#
            count = .composite(lhs: count, rhs: count)
        }
        _ = try JSONDecoder().decode(ComposingCountSnapshot.self, from: Data(json.utf8))
        _ = try ComposingCountSnapshot(count)
        json = #"{"kind":"composite","lhs":\#(json),"rhs":{"kind":"surfaceCount","count":0}}"#
        count = .composite(lhs: count, rhs: .surfaceCount(0))
        #expect(throws: CompositionSnapshotError.limitExceeded("composingCountNodes")) {
            try JSONDecoder().decode(ComposingCountSnapshot.self, from: Data(json.utf8))
        }
        #expect(throws: CompositionSnapshotError.limitExceeded("composingCountNodes")) {
            try ComposingCountSnapshot(count)
        }
    }
}
