import Core
@testable import DesktopBridge
import Testing

@MainActor
extension DesktopSegmentEditingTests {
    private func expectExistingCandidatesPreserved(original: DesktopSnapshot, expanded: DesktopSnapshot) {
        let preserved = expanded.candidates.prefix(original.candidates.count)
        #expect(preserved.map(\.index) == original.candidates.map(\.index))
        #expect(preserved.map(\.text) == original.candidates.map(\.text))
        #expect(preserved.map(\.commitScope) == original.candidates.map(\.commitScope))
    }

    @Test(arguments: [false, true])
    func liveRowSelectionStaysVisibleUntilExplicitlyCommitted(selectSameCandidate: Bool) throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            let initial = type("nihongo", into: session)
            let candidate = try #require(initial.candidates.first {
                $0.commitScope?.remainingReading.isEmpty == true
                    && (($0.index == initial.selection) == selectSameCandidate)
            })
            let selected = session.select(candidateIndex: candidate.index, submit: false, expectedGeneration: initial.generation)
            #expect(selected.inputState == "selecting")
            #expect(selected.commits.isEmpty)
            #expect(selected.reading == initial.reading)
            #expect(selected.selection == candidate.index)
            expectExistingCandidatesPreserved(original: initial, expanded: selected)
            #expect(selected.preedit == candidate.text)

            let committed = session.select(candidateIndex: candidate.index, submit: true, expectedGeneration: selected.generation)
            #expect(committed.commits == [candidate.text])
            #expect(committed.reading.isEmpty)
            #expect(committed.preedit.isEmpty)
            let duplicate = session.select(candidateIndex: candidate.index, submit: true, expectedGeneration: selected.generation)
            #expect(duplicate.commits.isEmpty)
            #expect(duplicate.preedit.isEmpty)
        }
    }

    @Test func liveWordSelectionKeepsItsSentenceAvailableForExplicitCommit() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            let initial = type("watashihanihongowobenkyoushiteimasu", into: session)
            let alternative = try #require(initial.columns.first { $0.count > 1 }?.dropFirst().first)
            let selected = session.selectNode(alternative, submit: false, expectedGeneration: initial.generation)
            #expect(selected.inputState == "selecting")
            #expect(selected.commits.isEmpty)
            #expect(selected.reading == initial.reading)
            expectExistingCandidatesPreserved(original: initial, expanded: selected)
            let candidate = try selectedCandidate(selected)

            let committed = session.select(candidateIndex: candidate.index, submit: true, expectedGeneration: selected.generation)
            #expect(committed.commits == [candidate.text])
            #expect(committed.reading == candidate.commitScope?.remainingReading)
        }
    }

    @Test func livePrefixSelectionKeepsTheSuffixAfterOneExplicitCommit() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            let initial = type("nihongowobenkyou", into: session)
            let candidate = try #require(initial.candidates.first {
                $0.commitScope.map { !$0.remainingReading.isEmpty } ?? false
            })
            let remaining = try #require(candidate.commitScope?.remainingReading)
            let selected = session.select(candidateIndex: candidate.index, submit: false, expectedGeneration: initial.generation)
            #expect(selected.commits.isEmpty)
            #expect(selected.selection == candidate.index)
            #expect(selected.preedit == candidate.text + remaining)
            expectExistingCandidatesPreserved(original: initial, expanded: selected)
            let committed = session.select(candidateIndex: candidate.index, submit: true, expectedGeneration: selected.generation)
            #expect(committed.commits == [candidate.text])
            #expect(committed.reading == remaining)
            #expect(!committed.preedit.isEmpty)

            let duplicate = session.select(candidateIndex: candidate.index, submit: true, expectedGeneration: selected.generation)
            #expect(duplicate.commits.isEmpty)
            #expect(duplicate.reading == remaining)
            #expect(duplicate.preedit == committed.preedit)
        }
    }

    @Test func staleLiveRowAndWordSelectionsCannotChangeOrCommitNewInput() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            let initial = type("nihongo", into: session)
            let candidate = try selectedCandidate(initial)
            let node = try #require(initial.nodes.first)
            let changed = type("a", into: session)
            for submit in [false, true] {
                let row = session.select(candidateIndex: candidate.index, submit: submit, expectedGeneration: initial.generation)
                let word = session.selectNode(node.id, submit: submit, expectedGeneration: initial.generation)
                for rejected in [row, word] {
                    #expect(rejected.commits.isEmpty)
                    #expect(rejected.reading == changed.reading)
                    #expect(rejected.preedit == changed.preedit)
                    #expect(rejected.selection == changed.selection)
                    #expect(rejected.generation == changed.generation)
                }
            }
        }
    }
}
