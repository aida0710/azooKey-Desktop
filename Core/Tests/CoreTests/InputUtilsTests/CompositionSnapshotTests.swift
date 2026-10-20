import Core
import Foundation
import KanaKanjiConverterModule
import Testing

@MainActor
@Suite struct CompositionSnapshotTests {
    private struct ReadingCase {
        let style: InputStyle
        let input: String
        let reading: String
    }

    @Test func builtInTablesRestoreTheirActualReadingsAndAllowFurtherInput() throws {
        let scenarios: [ReadingCase] = [
            .init(style: .roman2kana, input: "kyo", reading: "きょ"),
            .init(style: .mapped(id: .defaultRomanToKana), input: "kyo", reading: "きょ"),
            .init(style: .mapped(id: .defaultAZIK), input: "kz", reading: "かん"),
            .init(style: .mapped(id: .defaultKanaJIS), input: "tw", reading: "かて"),
            .init(style: .mapped(id: .defaultKanaUS), input: "tw", reading: "かて"),
            .init(style: .mapped(id: .empty), input: "raw", reading: "raw"),
            .init(style: .direct, input: "e\u{301}", reading: "e\u{301}")
        ]
        for scenario in scenarios {
            var composition = CompositionState()
            composition.insertAtCursorPosition(scenario.input, inputStyle: scenario.style)
            var restored = try CompositionSnapshot.decode(CompositionSnapshot.capture(composition).encoded()).restore()
            #expect(restored.convertTarget.utf8.elementsEqual(scenario.reading.utf8))
            #expect(restored.composingText.input.map(\.piece) == composition.composingText.input.map(\.piece))
            #expect(restored.composingText.input.map(\.inputStyle) == composition.composingText.input.map(\.inputStyle))
            restored.insertAtCursorPosition("後", inputStyle: .direct)
            #expect(restored.convertTarget.utf8.elementsEqual((scenario.reading + "後").utf8))
        }
    }

    @Test func mixedInputKeepsItsFormalCursorRangeAndSubsequentEditing() throws {
        var composition = CompositionState()
        composition.insertAtCursorPosition("ni", inputStyle: .roman2kana)
        composition.insertAtCursorPosition("👩‍💻", inputStyle: .direct)
        composition.insertAtCursorPosition(pieces: [.key(intention: "0", input: "0", modifiers: [.shift])],
                                           inputStyle: .mapped(id: .defaultKanaJIS))
        composition.insertCompositionSeparator(inputStyle: .mapped(id: .defaultKanaJIS))
        composition.moveCursor(.backward)
        composition.editSegment(count: -1)
        let snapshot = try CompositionSnapshot.capture(composition)
        var restored = try CompositionSnapshot.decode(snapshot.encoded()).restore()
        #expect(restored.convertTarget == "に👩‍💻を")
        #expect(restored.readingCursorUTF16Offset == 6)
        #expect(restored.composingText.convertTargetCursorPosition == 2)
        #expect(restored.conversionTarget.convertTarget == "に👩‍💻")
        #expect(restored.lastInputStyle == .mapped(id: .defaultKanaJIS))
        #expect(restored.composingText.input.map(\.piece) == composition.composingText.input.map(\.piece))
        restored.insertAtCursorPosition("ka", inputStyle: .roman2kana)
        #expect(restored.convertTarget == "に👩‍💻かを")
        #expect(composition.convertTarget == "に👩‍💻を")
    }

    @Test func editedSyllablesKeepTheirRemainingFormalKeys() throws {
        var composition = CompositionState()
        composition.insertAtCursorPosition("kyo", inputStyle: .roman2kana)
        composition.moveCursor(.backward)
        composition.insertAtCursorPosition("a", inputStyle: .roman2kana)
        composition.deleteBackwardFromCursorPosition()
        composition.prefixComplete(composingCount: .surfaceCount(1))
        var restored = try CompositionSnapshot.capture(composition).restore()
        #expect(restored.convertTarget == "ょ")
        #expect(restored.composingText.input.map(\.piece) == composition.composingText.input.map(\.piece))
        #expect(restored.composingText.input.map(\.inputStyle) == composition.composingText.input.map(\.inputStyle))
        restored.insertAtCursorPosition("go", inputStyle: .roman2kana)
        #expect(restored.convertTarget == "ょご")
        let roman = restored.romanInputForSelection(composingCount: .surfaceCount(1))
        #expect(roman.text == "ょ")
        restored.prefixComplete(composingCount: roman.composingCount)
        #expect(restored.convertTarget == "ご")
    }

    @Test func customTablesRequireTheSameRegisteredRevision() throws {
        let name = "CompositionSnapshotTests.\(UUID().uuidString)"
        let table = InputTable(baseMapping: [
            [.piece(.character("x")), .piece(.character("y"))]: [.character("き"), .character("ょ")]
        ] as Dictionary)
        let exported = try InputStyleManager.exportTable(table)
        let revision = CompositionSnapshot.customInputTableRevision(exportedTable: exported)
        InputStyleManager.registerInputStyle(table: table, for: name)
        var composition = CompositionState()
        composition.insertAtCursorPosition("xy", inputStyle: .mapped(id: .tableName(name)))
        #expect(throws: CompositionSnapshotError.customTableRevisionMismatch(name)) {
            try CompositionSnapshot.capture(composition)
        }
        #expect(throws: CompositionSnapshotError.invalidValue("customTableRevision")) {
            try CompositionSnapshot.capture(composition, registeredCustomTables: [name: "not-a-sha256"])
        }
        let snapshot = try CompositionSnapshot.capture(composition, registeredCustomTables: [name: revision, "unused": revision])
        #expect(snapshot.customInputTableRevisions == [name: revision])
        #expect(throws: CompositionSnapshotError.customTableRevisionMismatch(name)) { try snapshot.restore() }
        let anotherRevision = CompositionSnapshot.customInputTableRevision(exportedTable: exported + "\n")
        #expect(anotherRevision != revision)
        #expect(throws: CompositionSnapshotError.customTableRevisionMismatch(name)) {
            try snapshot.restore(registeredCustomTables: [name: anotherRevision])
        }
        let restored = try CompositionSnapshot.decode(snapshot.encoded()).restore(registeredCustomTables: [name: revision])
        #expect(restored.convertTarget == "きょ")
        #expect(restored.composingText.input.map(\.piece) == [.character("x"), .character("y")])
        #expect(CompositionSnapshot.customInputTableRevision(exportedTable: "abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let replacedTable = InputTable(baseMapping: [
            [.piece(.character("x")), .piece(.character("y"))]: [.character("あ")]
        ] as Dictionary)
        InputStyleManager.registerInputStyle(table: replacedTable, for: name)
        // Even incorrect registration metadata cannot authorize a different reconstructed reading.
        #expect(throws: CompositionSnapshotError.inconsistentReading) {
            try snapshot.restore(registeredCustomTables: [name: revision])
        }
    }

    @Test func emptyCompositionRoundTripsWithoutInventingInput() throws {
        let restored = try CompositionSnapshot.decode(CompositionSnapshot.capture(.init()).encoded()).restore()
        #expect(restored.isEmpty)
        #expect(restored.composingText.input.isEmpty)
        #expect(restored.readingCursorUTF16Offset == 0)
        #expect(restored.conversionRangeEnd == nil)
    }

    @Test func restoringRejectsCanonicallyEquivalentButDifferentReadingScalars() throws {
        var composition = CompositionState()
        composition.insertAtCursorPosition("か\u{3099}", inputStyle: .direct)
        #expect(composition.convertTarget == "が")
        #expect(!composition.convertTarget.utf8.elementsEqual("が".utf8))
        let snapshot = try changedSnapshot(composition, changes: ["convertTarget": "が"])
        #expect(throws: CompositionSnapshotError.inconsistentReading) { try snapshot.restore() }
        #expect(composition.convertTarget.utf8.elementsEqual("か\u{3099}".utf8))
    }

    @Test(arguments: [-1, 3, 5])
    func cursorUsesCharacterOffsetsAndRejectsUTF16Offsets(offset: Int) throws {
        var composition = CompositionState()
        composition.insertAtCursorPosition("👩‍💻a", inputStyle: .direct)
        #expect(throws: CompositionSnapshotError.invalidValue("convertTargetCursorPosition")) {
            try changedSnapshot(composition, changes: ["convertTargetCursorPosition": offset])
        }
        let valid = try changedSnapshot(composition, changes: ["convertTargetCursorPosition": 1]).restore()
        #expect(valid.readingCursorUTF16Offset == 5)
    }

    @Test(arguments: [-1, 0, 3])
    func invalidSegmentBoundsAreRejected(end: Int) throws {
        var composition = CompositionState()
        composition.insertAtCursorPosition("kyo", inputStyle: .roman2kana)
        #expect(throws: CompositionSnapshotError.invalidValue("conversionRangeEnd")) {
            try changedSnapshot(composition, changes: ["conversionRangeEnd": end])
        }
    }

    @Test func unknownVersionsAndUnusedCustomRevisionsAreRejected() throws {
        let composition = CompositionState()
        #expect(throws: CompositionSnapshotError.unsupportedVersion(2)) {
            try changedSnapshot(composition, changes: ["schemaVersion": 2])
        }
        #expect(throws: CompositionSnapshotError.invalidValue("customInputTableRevisions")) {
            try changedSnapshot(composition, changes: ["customInputTableRevisions": ["unused": String(repeating: "0", count: 64)]])
        }
    }

    @Test func transportLimitsDoNotDiscardTheFormalReading() {
        var composition = CompositionState()
        let text = String(repeating: "a", count: CompositionSnapshotLimits.inputElementCount + 1)
        composition.insertAtCursorPosition(text, inputStyle: .direct)
        #expect(throws: CompositionSnapshotError.limitExceeded("input")) {
            try CompositionSnapshot.capture(composition)
        }
        #expect(composition.convertTarget == text)
        #expect(composition.readingCursorUTF16Offset == text.count)
        let oversized = Data(repeating: 0x20, count: CompositionSnapshotLimits.jsonByteCount + 1)
        #expect(throws: CompositionSnapshotError.limitExceeded("json")) {
            try CompositionSnapshot.decode(oversized)
        }
    }

    @Test func wireInputAndReadingLimitsAreCheckedBeforeRestoration() throws {
        var composition = CompositionState()
        composition.insertAtCursorPosition("a", inputStyle: .direct)
        let encoded = try CompositionSnapshot.capture(composition).encoded()
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let element = try #require((json["input"] as? [[String: Any]])?.first)
        #expect(throws: CompositionSnapshotError.limitExceeded("input")) {
            try changedSnapshot(composition, changes: [
                "input": Array(repeating: element, count: CompositionSnapshotLimits.inputElementCount + 1)
            ])
        }
        #expect(throws: CompositionSnapshotError.limitExceeded("convertTarget")) {
            try changedSnapshot(composition, changes: [
                "convertTarget": String(repeating: "a", count: CompositionSnapshotLimits.readingCharacterCount + 1)
            ])
        }
        #expect(composition.convertTarget == "a")
    }

    private func changedSnapshot(_ composition: CompositionState, changes: [String: Any]) throws -> CompositionSnapshot {
        let encoded = try CompositionSnapshot.capture(composition).encoded()
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.merge(changes) { _, replacement in replacement }
        return try CompositionSnapshot.decode(JSONSerialization.data(withJSONObject: json))
    }
}
