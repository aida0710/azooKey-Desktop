import Foundation
import Testing
@testable import DesktopBridge

@MainActor
@Test func desktopSessionConvertsAndCommitsRealCandidate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try DesktopSession(dataDirectory: directory, resourcesDirectory: nil, useZenzai: false)
    for c in "nihongo" { _ = session.key(.init(modifierFlags: [], characters: String(c), charactersIgnoringModifiers: String(c), keyCode: 0)) }
    let snapshot = session.key(.init(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49))
    #expect(!snapshot.candidates.isEmpty)
    let japanese = try #require(snapshot.candidates.first(where: { $0.text == "日本語" }))
    let committed = session.select(candidateIndex: japanese.index, submit: true)
    #expect(committed.commits == ["日本語"])
    #expect(committed.preedit.isEmpty)
}

@MainActor
@Test func desktopSessionRejectsStaleSelectionsAndClearsOnReset() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try DesktopSession(dataDirectory: directory, resourcesDirectory: nil, useZenzai: false)
    #expect(session.select(candidateIndex: 999, submit: true).commits.isEmpty)
    _ = session.key(.init(modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a", keyCode: 0))
    let snapshot = session.reset(commit: false)
    #expect(snapshot.preedit.isEmpty)
    #expect(snapshot.candidates.isEmpty)
}
