import Core
@testable import DesktopBridge
import Foundation
import Testing

@Test(arguments: ["👩‍💻A", "𠮷野", "e\u{301}", "🇯🇵", "日本語"])
func unicodeScalarOffsetMatchesTheEndOfEveryUnicodeSequence(text: String) {
    #expect(unicodeScalarOffset(in: text, utf16Offset: text.utf16.count) == text.unicodeScalars.count)
    #expect(unicodeScalarOffset(in: text, utf16Offset: NSNotFound) == text.unicodeScalars.count)
    #expect(unicodeScalarOffset(in: text, utf16Offset: -1) == 0)
}

@Test func unicodeScalarOffsetStopsBeforeAnIncompleteSurrogatePair() {
    let expected = [0, 0, 1, 2, 2, 3, 4]
    for offset in expected.indices {
        #expect(unicodeScalarOffset(in: "👩‍💻A", utf16Offset: offset) == expected[offset])
    }
}

@MainActor
@Test(arguments: ["👩‍💻A", "𠮷野", "e\u{301}", "🇯🇵", "日本語"])
func desktopSuggestionCursorEndsAfterTheEntireUnicodeText(text: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try DesktopSession(dataDirectory: directory, resourcesDirectory: nil, useZenzai: false)
    defer { session.close() }
    let initial = session.key(.init(modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a", keyCode: 0))
    let suggestion = session.applySuggestions([text], reading: initial.reading, expectedGeneration: initial.generation)
    #expect(suggestion.preedit == text)
    #expect(suggestion.cursor == text.unicodeScalars.count)
}
