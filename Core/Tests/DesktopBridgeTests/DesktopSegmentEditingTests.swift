import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopSegmentEditingTests {
    func withSession(
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

    func key(_ code: UInt16, shift: Bool = false) -> KeyEventCore {
        .init(modifierFlags: shift ? [.shift] : [], characters: nil, charactersIgnoringModifiers: nil, keyCode: code)
    }

    func beginSelecting(_ session: DesktopSession) throws -> DesktopSnapshot {
        for character in "nihongowobenkyou" {
            _ = session.key(.init(modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character), keyCode: 0))
        }
        _ = session.key(key(49))
        return session.key(key(49))
    }

    func selectedCandidate(_ snapshot: DesktopSnapshot) throws -> DesktopSnapshot.CandidateItem {
        let index = try #require(snapshot.selection)
        return try #require(snapshot.candidates.first { $0.index == index })
    }

    func selectWholeCandidate(_ session: DesktopSession, from snapshot: DesktopSnapshot) throws -> DesktopSnapshot {
        let candidate = try #require(snapshot.candidates.max { ($0.comparisonGroup ?? 0) < ($1.comparisonGroup ?? 0) })
        return session.select(candidateIndex: candidate.index, submit: false, expectedGeneration: snapshot.generation)
    }

    @Test(arguments: [false, true], [false, true])
    func shiftArrowsChangeTheConvertedPrefixAndKeepTheRemainingReading(live: Bool, tree: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: tree) { session in
            var snapshot = try beginSelecting(session)
            let reading = snapshot.reading
            snapshot = try selectWholeCandidate(session, from: snapshot)
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
                #expect(selected.commitScope?.remainingReading == String(reading.suffix(removedCount)))
                #expect(selected.commitScope?.consumedReading == String(reading.dropLast(removedCount)))
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

            #expect(previousConsumedCount == initialSelected.comparisonGroup)
        }
    }

    @Test func previewAndCommitUseTheSameCandidateAndLeaveTheShownReading() throws {
        try withSession(liveConversion: false, treeCandidates: true) { session in
            var snapshot = try beginSelecting(session)
            _ = try selectWholeCandidate(session, from: snapshot)
            snapshot = session.key(key(123, shift: true))
            let preview = try #require(snapshot.nodes.first { $0.id == snapshot.focusedNode }?.preview)
            let confirmed = session.select(candidateIndex: preview.candidateIndex, submit: true, expectedGeneration: snapshot.generation)
            #expect(confirmed.commits == [preview.text])
            #expect(confirmed.reading == preview.scope?.remainingReading)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func committingAnEditedPrefixKeepsTheSuffixForCandidateChangesEscapeAndBackspace(live: Bool, tree: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: tree) { session in
            var snapshot = try beginSelecting(session)
            _ = try selectWholeCandidate(session, from: snapshot)
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

    @Test(arguments: [false, true], [UInt16(101), UInt16(109)])
    func romanConversionCommitsOnlyTheSelectedCandidate(live: Bool, functionKey: UInt16) throws {
        try withSession(liveConversion: live, treeCandidates: true) { session in
            let snapshot = try beginSelecting(session)
            let prefix = try #require(snapshot.candidates.first { $0.text == "に" && $0.comparisonGroup == 2 })
            _ = session.select(candidateIndex: prefix.index, submit: false, expectedGeneration: snapshot.generation)

            let committed = session.key(key(functionKey))
            #expect(committed.commits == [functionKey == 101 ? "ｎｉ" : "ni"])
            #expect(committed.reading == "ほんごをべんきょう")
            #expect(!committed.preedit.isEmpty)
        }
    }

    @Test(arguments: [UInt16(101), UInt16(109)])
    func romanConversionUsesTheEditedRangeAndStillConvertsWholeSelections(functionKey: UInt16) throws {
        try withSession(liveConversion: false, treeCandidates: false) { session in
            var snapshot = try beginSelecting(session)
            _ = try selectWholeCandidate(session, from: snapshot)
            for _ in 0..<6 {
                snapshot = session.key(key(123, shift: true))
            }
            snapshot = session.key(key(functionKey))
            #expect(snapshot.commits == [functionKey == 101 ? "ｎｉｈｏｎｇｏ" : "nihongo"])
            #expect(snapshot.reading == "をべんきょう")

            _ = session.reset(commit: false)
            snapshot = try beginSelecting(session)
            _ = try selectWholeCandidate(session, from: snapshot)
            snapshot = session.key(key(functionKey))
            #expect(snapshot.commits == [functionKey == 101 ? "ｎｉｈｏｎｇｏｗｏｂｅｎｋｙｏｕ" : "nihongowobenkyou"])
            #expect(snapshot.reading.isEmpty)
            #expect(snapshot.preedit.isEmpty)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func escapeAfterShrinkingTheRangeKeepsTheWholeReadingForEnterAndFurtherInput(live: Bool, tree: Bool) throws {
        try withSession(liveConversion: live, treeCandidates: tree) { session in
            for shouldEnter in [true, false] {
                _ = session.reset(commit: false)
                var snapshot = try beginSelecting(session)
                _ = try selectWholeCandidate(session, from: snapshot)
                for _ in 0..<6 {
                    snapshot = session.key(key(123, shift: true))
                }
                snapshot = session.key(key(53))
                #expect(snapshot.reading == "にほんごをべんきょう")
                #expect(snapshot.preedit.contains("勉強") || snapshot.preedit.hasSuffix("べんきょう"))
                let escapedText = snapshot.preedit
                if shouldEnter {
                    snapshot = session.key(key(36))
                    #expect(snapshot.commits == [escapedText])
                    #expect(snapshot.reading.isEmpty)
                } else {
                    snapshot = session.key(.init(modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a", keyCode: 0))
                    if live {
                        #expect(snapshot.reading == "にほんごをべんきょうあ")
                        #expect(snapshot.commits.isEmpty)
                    } else {
                        #expect(snapshot.commits == [escapedText])
                        #expect(snapshot.reading == "あ")
                    }
                }
            }
        }
    }
}
