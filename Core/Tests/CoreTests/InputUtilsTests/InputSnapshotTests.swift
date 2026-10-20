import Core
import Foundation
import KanaKanjiConverterModule
import Testing

@Suite struct InputSnapshotTests {
    @Test func allPieceCasesKeepTheirActualScalarsAndKeyIntentions() throws {
        let pieces: [InputPiece] = [
            .character("a"), .character("👩‍💻"), .character("e\u{301}"),
            .compositionSeparator,
            .key(intention: nil, input: "t", modifiers: []),
            .key(intention: "＠", input: "@", modifiers: []),
            .key(intention: "0", input: "0", modifiers: [.shift])
        ]
        for piece in pieces {
            let encoded = try JSONEncoder().encode(InputPieceSnapshot(piece))
            let decoded = try JSONDecoder().decode(InputPieceSnapshot.self, from: encoded)
            #expect(decoded.piece == piece)
            // The wire must also preserve canonically equivalent scalar sequences.
            let again = try JSONEncoder().encode(decoded)
            let firstJSON = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            let secondJSON = try JSONSerialization.jsonObject(with: again) as? [String: Any]
            for field in ["value", "input", "intention"] {
                let first = firstJSON?[field] as? String
                let second = secondJSON?[field] as? String
                #expect(first.map { Array($0.utf8) } == second.map { Array($0.utf8) })
            }
        }
    }

    @Test func allInputStylesKeepTheirTableIdentities() throws {
        let styles: [InputStyle] = [
            .direct, .roman2kana, .mapped(id: .defaultRomanToKana),
            .mapped(id: .defaultAZIK), .mapped(id: .defaultKanaJIS),
            .mapped(id: .defaultKanaUS), .mapped(id: .empty),
            .mapped(id: .tableName("利用者の表"))
        ]
        for style in styles {
            let encoded = try JSONEncoder().encode(InputStyleSnapshot(style))
            let decoded = try JSONDecoder().decode(InputStyleSnapshot.self, from: encoded)
            #expect(decoded.inputStyle == style)
        }
    }

    @Test(arguments: [
        #"{"kind":"unknown"}"#,
        #"{"kind":"character","value":""}"#,
        #"{"kind":"character","value":"ab"}"#,
        #"{"kind":"character","value":"a","input":"b"}"#,
        #"{"kind":"key","input":"a","intention":"ab","modifiers":[]}"#,
        #"{"kind":"key","input":"ab","intention":null,"modifiers":[]}"#,
        #"{"kind":"key","input":"a","intention":null,"modifiers":["control"]}"#,
        #"{"kind":"key","input":"a","intention":null,"modifiers":["shift","shift"]}"#
    ])
    func malformedPiecesAreRejected(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(InputPieceSnapshot.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"kind":"unknown"}"#,
        #"{"kind":"mapped","table":{"kind":"unknown"}}"#,
        #"{"kind":"mapped","table":{"kind":"tableName","name":""}}"#,
        #"{"kind":"mapped","table":{"kind":"defaultAZIK","name":"other"}}"#,
        #"{"kind":"direct","table":{"kind":"empty"}}"#
    ])
    func malformedStylesAreRejected(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(InputStyleSnapshot.self, from: Data(json.utf8))
        }
    }

    @Test func oneGraphemeStillHasABoundedWireSize() {
        let oversized = "e" + String(repeating: "\u{301}", count: CompositionSnapshotLimits.pieceUTF8ByteCount)
        #expect(oversized.count == 1)
        #expect(throws: CompositionSnapshotError.limitExceeded("character")) {
            try InputPieceSnapshot(.character(Character(oversized)))
        }
    }
}
