import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
@Test(arguments: ["👩‍💻A", "𠮷野", "e\u{301}", "🇯🇵", "日本語"])
func markedTextSelectionUsesUTF16ForOrdinaryAndSuggestionCandidates(text: String) throws {
    let manager = SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: FileManager.default.temporaryDirectory,
        containerURL: nil,
        context: .init(useZenzai: false)
    )
    manager.learningEnabled = false
    manager.insertAtCursorPosition(text, inputStyle: .direct)
    manager.requestSetCandidateWindowState(visible: true)
    guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("Expected an ordinary candidate for the direct input")
        return
    }
    let row = try #require(candidates.firstIndex { $0.text == text })
    manager.requestSelectingRow(row)
    #expect(manager.getCurrentMarkedText(inputState: .selecting).selectionRange == NSRange(location: text.utf16.count, length: 0))

    manager.setReplaceSuggestions([
        .init(text: text, value: 0, composingCount: .surfaceCount(text.count), lastMid: 0, data: [])
    ])
    manager.requestSelectingSuggestionRow(0)
    #expect(manager.getCurrentMarkedText(inputState: .replaceSuggestion).selectionRange == NSRange(location: text.utf16.count, length: 0))
}
