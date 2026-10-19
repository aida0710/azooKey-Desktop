import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Test func desktopSessionShowsLiveTreeAndCommitsTheDisplayedWholeSentence() throws {
    let oldTree = Config.TreeCandidates().value
    let oldLive = Config.LiveConversion().value
    defer {
        Config.TreeCandidates().value = oldTree
        Config.LiveConversion().value = oldLive
    }
    Config.TreeCandidates().value = true
    Config.LiveConversion().value = true
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try DesktopSession(dataDirectory: directory, resourcesDirectory: nil, useZenzai: false)
    defer { session.close() }
    for c in "watashihanihongowobenkyoushiteimasu" {
        _ = session.key(.init(modifierFlags: [], characters: String(c), charactersIgnoringModifiers: String(c), keyCode: 0))
    }
    let snapshot = session.snapshot()
    #expect(!snapshot.columns.isEmpty, "The reference tree appears while typing, before Space")
    let index = try #require(snapshot.selection)
    let candidate = try #require(snapshot.candidates.first { $0.index == index })
    #expect(candidate.text == snapshot.preedit)
    #expect(!snapshot.showCandidateIndex)
    let committed = session.select(candidateIndex: index, submit: true, expectedGeneration: snapshot.generation)
    #expect(committed.commits == [candidate.text])
    #expect(committed.preedit.isEmpty)
    Config.TreeCandidates().value = false
    for c in "nihongo" {
        _ = session.key(.init(modifierFlags: [], characters: String(c), charactersIgnoringModifiers: String(c), keyCode: 0))
    }
    #expect(session.snapshot().columns.isEmpty, "The upstream list still stays hidden during live conversion")
}

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
