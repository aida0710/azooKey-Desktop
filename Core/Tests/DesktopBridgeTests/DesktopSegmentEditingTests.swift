import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopSegmentEditingTests {
    private func withSession(
        liveConversion: Bool,
        treeCandidates: Bool,
        _ test: (DesktopSession) throws -> Void
    ) throws {
        let oldLive = Config.LiveConversion().value
        let oldTree = Config.TreeCandidates().value
        defer {
            Config.LiveConversion().value = oldLive
            Config.TreeCandidates().value = oldTree
        }
        Config.LiveConversion().value = liveConversion
        Config.TreeCandidates().value = treeCandidates
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try DesktopSession(dataDirectory: directory, resourcesDirectory: nil, useZenzai: false)
        defer { session.close() }
        try test(session)
    }

    private func key(_ code: UInt16, shift: Bool = false) -> KeyEventCore {
        .init(modifierFlags: shift ? [.shift] : [], characters: nil, charactersIgnoringModifiers: nil, keyCode: code)
    }

    private func beginSelecting(_ session: DesktopSession) throws -> DesktopSnapshot {
        for character in "nihongowobenkyou" {
            _ = session.key(.init(modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character), keyCode: 0))
        }
        _ = session.key(key(49))
        return session.key(key(49))
    }

    private func selectedCandidate(_ snapshot: DesktopSnapshot) throws -> DesktopSnapshot.CandidateItem {
        let index = try #require(snapshot.selection)
        return try #require(snapshot.candidates.first { $0.index == index })
    }

    @Test(arguments: [false, true], [false, true])
    func shiftArrowsChangeTheConvertedPrefixAndKeepTheRemainingReading(live: Bool, tree: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: tree) { session in
            var snapshot = try beginSelecting(session)
            let reading = snapshot.reading
            let wholeCandidate = try #require(snapshot.candidates.max { ($0.comparisonGroup ?? 0) < ($1.comparisonGroup ?? 0) })
            snapshot = session.select(candidateIndex: wholeCandidate.index, submit: false, expectedGeneration: snapshot.generation)
            let initialSelected = try selectedCandidate(snapshot)
            var previousConsumedCount = try #require(initialSelected.comparisonGroup)

            for removedCount in 1...6 {
                snapshot = session.key(key(123, shift: true))
                let selected = try selectedCandidate(snapshot)
                let consumedCount = try #require(selected.comparisonGroup)
                #expect(consumedCount < previousConsumedCount)
                #expect(snapshot.reading == reading)
                #expect(snapshot.preedit == selected.text + String(reading.suffix(removedCount)))
                #expect(snapshot.cursor == selected.text.unicodeScalars.count)
                #expect(snapshot.candidates.allSatisfy { $0.comparisonGroup == consumedCount })
                previousConsumedCount = consumedCount
            }

            for removedCount in (0..<6).reversed() {
                snapshot = session.key(key(124, shift: true))
                let selected = try selectedCandidate(snapshot)
                let consumedCount = try #require(selected.comparisonGroup)
                #expect(consumedCount > previousConsumedCount)
                #expect(snapshot.reading == reading)
                #expect(snapshot.preedit == selected.text + String(reading.suffix(removedCount)))
                previousConsumedCount = consumedCount
            }

            #expect(previousConsumedCount == wholeCandidate.comparisonGroup)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func committingAnEditedPrefixKeepsTheSuffixForCandidateChangesEscapeAndBackspace(live: Bool, tree: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: tree) { session in
            var snapshot = try beginSelecting(session)
            let wholeCandidate = try #require(snapshot.candidates.max { ($0.comparisonGroup ?? 0) < ($1.comparisonGroup ?? 0) })
            _ = session.select(candidateIndex: wholeCandidate.index, submit: false, expectedGeneration: snapshot.generation)
            snapshot = session.key(key(123, shift: true))
            let suffix = String(snapshot.reading.suffix(1))
            let selected = try selectedCandidate(snapshot)

            snapshot = session.key(key(36))
            #expect(snapshot.commits == [selected.text])
            #expect(snapshot.reading == suffix)
            #expect(!snapshot.preedit.isEmpty)

            snapshot = session.key(key(49))
            #expect(snapshot.reading == suffix)
            snapshot = session.key(key(49))
            #expect(snapshot.reading == suffix)
            snapshot = session.key(key(53))
            #expect(snapshot.reading == suffix)
            snapshot = session.key(key(51))
            #expect(snapshot.reading.isEmpty)
            #expect(snapshot.preedit.isEmpty)
            #expect(snapshot.commits.isEmpty)
        }
    }
}
