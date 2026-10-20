import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
@Test func selectingALiveCandidateKeepsTheSharedManagerWindowVisible() throws {
    let previousLive = Config.LiveConversion().value
    let previousTree = Config.TreeCandidates().value
    defer {
        Config.LiveConversion().value = previousLive
        Config.TreeCandidates().value = previousTree
    }
    Config.LiveConversion().value = true
    Config.TreeCandidates().value = true
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: directory, containerURL: nil,
        context: .init(useZenzai: false)
    )
    manager.learningEnabled = false
    manager.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
    guard case .composing(let candidates, let selectedIndex) = manager.getCurrentCandidateWindow(inputState: .composing) else {
        Issue.record("Expected live candidates before an explicit selection")
        return
    }
    let index = try #require(selectedIndex)
    let candidate = candidates[index]

    // The macOS delegate selects a row, then refreshes using .selecting.
    manager.requestSelectingRow(index)
    guard case .selecting(let visible, let selection) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("An explicit live selection must remain available for confirmation")
        return
    }
    #expect(selection == index)
    #expect(visible == candidates)
    #expect(manager.selectedCandidate == candidate)
    #expect(manager.convertTarget == "にほんご")
    manager.prefixCandidateCommited(candidate, leftSideContext: "")
    #expect(manager.isEmpty)

    manager.stopComposition()
    if case .hidden = manager.getCurrentCandidateWindow(inputState: .selecting) {
        #expect(manager.selectedCandidate == nil)
    } else {
        Issue.record("Finishing composition must hide its old candidates")
    }
}
