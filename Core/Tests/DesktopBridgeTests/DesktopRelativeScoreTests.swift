import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Test func hidingRelativeScoresKeepsTheSameCandidateFocusAndCommit() throws {
    let previousScores = Config.ShowRelativeScores().value
    let previousTree = Config.TreeCandidates().value
    let previousLive = Config.LiveConversion().value
    defer {
        Config.ShowRelativeScores().value = previousScores
        Config.TreeCandidates().value = previousTree
        Config.LiveConversion().value = previousLive
    }
    Config.ShowRelativeScores().value = true
    Config.TreeCandidates().value = true
    Config.LiveConversion().value = true
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try DesktopSession(dataDirectory: directory, resourcesDirectory: nil, useZenzai: false)
    defer { session.close() }
    for character in "nihongo" {
        _ = session.key(.init(modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character), keyCode: 0))
    }
    let visible = session.snapshot()
    let index = try #require(visible.selection)
    let candidate = try #require(visible.candidates.first { $0.index == index })
    #expect(visible.showRelativeScores)
    let visibleNodes = Set(visible.columns.flatMap { $0 })
    #expect(visible.nodes.filter { visibleNodes.contains($0.id) }.allSatisfy { $0.scorePresentation != nil })

    var settings = DesktopSettings()
    settings.showRelativeScores = false
    try settings.apply()
    #expect(!DesktopSettings().showRelativeScores)
    let hidden = session.snapshot()
    #expect(!hidden.showRelativeScores)
    #expect(hidden.nodes.allSatisfy { $0.scorePresentation == nil })
    #expect(hidden.nodes.map(\.relativeScore) == visible.nodes.map(\.relativeScore))
    #expect(hidden.selection == visible.selection)
    #expect(hidden.focusedNode == visible.focusedNode)
    #expect(hidden.selectedPath == visible.selectedPath)
    #expect(hidden.generation == visible.generation)
    let committed = session.select(candidateIndex: index, submit: true, expectedGeneration: hidden.generation)
    #expect(committed.commits == [candidate.text])
    #expect(committed.reading.isEmpty)
}
