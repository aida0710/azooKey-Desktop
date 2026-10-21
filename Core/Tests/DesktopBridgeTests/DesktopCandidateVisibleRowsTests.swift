import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Test func changingVisibleRowsPreservesTheRealPageSelectionAndSingleCommit() throws {
    let previous = DesktopSettings()
    defer { try? previous.apply() }
    var settings = previous
    settings.live = false
    settings.tree = true
    try settings.apply()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try DesktopSession(dataDirectory: directory, resourcesDirectory: nil, useZenzai: false)
    defer { session.close() }
    for character in "hoshou" {
        _ = session.key(.init(modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character), keyCode: 0))
    }
    _ = session.key(.init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 49))
    _ = session.key(.init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 49))
    let original = session.snapshot()
    let selection = try #require(original.selection)
    let candidate = try #require(original.candidates.first { $0.index == selection })
    #expect(original.candidatePage.items.count == CandidatePage.size)

    for rows in Config.CandidateVisibleRows.Value.allCases {
        settings.candidateVisibleRows = rows
        let content = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DesktopSettings.self, from: content)
        try decoded.apply()
        #expect(DesktopSettings().candidateVisibleRows == rows)
        let snapshot = session.snapshot()
        let document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(document["candidateVisibleRows"] as? Int == rows.rawValue)
        #expect(snapshot.candidatePage == original.candidatePage)
        #expect(snapshot.selection == selection)
        #expect(snapshot.preedit == original.preedit)
        #expect(snapshot.generation == original.generation)
        #expect(snapshot.commits.isEmpty)
    }
    let committed = session.select(candidateIndex: selection, submit: true, expectedGeneration: original.generation)
    #expect(committed.commits == [candidate.text])
    #expect(session.select(candidateIndex: selection, submit: true, expectedGeneration: original.generation).commits.isEmpty)
}
