import Core
@testable import DesktopBridge
import Foundation
import KanaKanjiConverterModule
import Testing

@Suite struct DesktopReadingCandidatesTests {
    private func composition(_ text: String = "nihongo", style: InputStyle = .mapped(id: .defaultRomanToKana)) -> CompositionState {
        var composition = CompositionState()
        composition.insertAtCursorPosition(text, inputStyle: style)
        return composition
    }

    private func context(revision: Int = 1) -> DesktopReadingCandidateContext {
        .init(context: "field", readingProcessGeneration: "reading-process",
              focusEpoch: 1, compositionRevision: revision, settingsRevision: 0,
              leftContext: "", rightContext: "", privateInput: false)
    }

    private func candidate(_ id: String, text: String = "日本語", count: ComposingCount = .inputCount(7)) throws -> DesktopCandidateItem {
        .init(candidateID: id, text: text, composingCount: try .init(count),
              presentation: .init(tokens: [], annotation: nil, extraValues: [:],
                                  score: nil, comparisonGroup: nil, commitScope: nil))
    }

    private func batch(_ request: DesktopCandidateRequest, candidates: [DesktopCandidateItem]) -> DesktopCandidateBatch {
        .init(authority: request.authority, workerGeneration: "candidate-process", batchID: "batch", candidates: candidates)
    }

    private func choice(in candidates: DesktopReadingCandidates, index: Int = 0) throws -> DesktopCandidateSelection {
        let batch = try #require(candidates.batch)
        return .init(batch: .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID),
                     candidateID: batch.candidates[index].candidateID)
    }

    @Test func adoptingCandidatesDoesNotSelectOrChangeFormalInput() throws {
        var candidates = DesktopReadingCandidates()
        let input = composition()
        let before = try CompositionSnapshot.capture(input).encoded()
        let request = try candidates.prepare(composition: input, context: context())
        let incoming = batch(request, candidates: [try candidate("first")])
        let reference = try candidates.adopt(incoming, composition: input, context: context())
        #expect(reference.batchID == incoming.batchID)
        #expect(candidates.selectionIndex == nil)
        #expect(candidates.selectedText == nil)
        #expect(try CompositionSnapshot.capture(input).encoded() == before)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(incoming)) as? [String: Any])
        #expect(Set(wire.keys).isDisjoint(with: ["commits", "preedit", "cursor", "inputState"]))
    }

    @Test func anOlderRequestCannotReturnAfterTheSameReadingIsEnteredAgain() throws {
        var candidates = DesktopReadingCandidates()
        let first = try candidates.prepare(composition: composition(), context: context())
        _ = try candidates.prepare(composition: composition("a"), context: context(revision: 2))
        let latest = try candidates.prepare(composition: composition(), context: context(revision: 3))
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try candidates.adopt(batch(first, candidates: [candidate("old")]), composition: composition(), context: context(revision: 3))
        }
        #expect(candidates.batch == nil)
        _ = try candidates.adopt(batch(latest, candidates: [candidate("current")]), composition: composition(), context: context(revision: 3))
        #expect(candidates.batch?.candidates.first?.candidateID == "current")
    }

    @Test func aNewRequestRetiresThePreviousReplyEvenWithoutAReadingChange() throws {
        var candidates = DesktopReadingCandidates()
        let old = try candidates.prepare(composition: composition(), context: context())
        let latest = try candidates.prepare(composition: composition(), context: context())
        #expect(old.authority.requestID != latest.authority.requestID)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try candidates.adopt(batch(old, candidates: [candidate("old")]), composition: composition(), context: context())
        }
    }

    @Test(arguments: ["context", "process", "focus", "settings", "left", "right", "private"])
    func aChangedInputContextRejectsThePendingCandidate(field: String) throws {
        var candidates = DesktopReadingCandidates()
        let original = context()
        let changed = DesktopReadingCandidateContext(
            context: field == "context" ? "other-field" : original.context,
            readingProcessGeneration: field == "process" ? "other-process" : original.readingProcessGeneration,
            focusEpoch: field == "focus" ? 2 : original.focusEpoch,
            compositionRevision: original.compositionRevision,
            settingsRevision: field == "settings" ? 1 : original.settingsRevision,
            leftContext: field == "left" ? "左" : original.leftContext,
            rightContext: field == "right" ? "右" : original.rightContext,
            privateInput: field == "private")
        let request = try candidates.prepare(composition: composition(), context: original)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try candidates.adopt(batch(request, candidates: [candidate("first")]), composition: composition(), context: changed)
        }
        #expect(candidates.batch == nil)
    }

    @Test func matchingReadingCannotHideDifferentOriginalKeysOrCursor() throws {
        var candidates = DesktopReadingCandidates()
        let request = try candidates.prepare(composition: composition(), context: context())
        let incoming = batch(request, candidates: [try candidate("first")])
        #expect(throws: DesktopReadingCandidates.Failure.changedComposition) {
            try candidates.adopt(incoming, composition: composition("にほんご", style: .direct), context: context())
        }
        var moved = composition()
        moved.moveCursor(.backward)
        #expect(throws: DesktopReadingCandidates.Failure.changedComposition) {
            try candidates.adopt(incoming, composition: moved, context: context())
        }
        _ = try candidates.adopt(incoming, composition: composition(), context: context())
        #expect(candidates.batch?.candidates.count == 1)
    }

    @Test func anInvalidCandidateRejectsTheWholeBatchWithoutSelectingItsValidPrefix() throws {
        var candidates = DesktopReadingCandidates()
        let request = try candidates.prepare(composition: composition(), context: context())
        let incoming = batch(request, candidates: [
            try candidate("valid"), try candidate("invalid", count: .inputCount(8))
        ])
        #expect(throws: CompositionSnapshotError.invalidValue("inputCount")) {
            try candidates.adopt(incoming, composition: composition(), context: context())
        }
        #expect(candidates.batch == nil)
        #expect(candidates.selectionIndex == nil)
        _ = try candidates.adopt(batch(request, candidates: [candidate("valid")]), composition: composition(), context: context())
        #expect(candidates.batch?.candidates.count == 1)
    }

    @Test func identicalTextStillSelectsTheExactOpaqueCandidateIdentity() throws {
        var candidates = DesktopReadingCandidates()
        let request = try candidates.prepare(composition: composition(), context: context())
        _ = try candidates.adopt(batch(request, candidates: [candidate("first"), candidate("second")]),
                                 composition: composition(), context: context())
        let choice = try choice(in: candidates, index: 1)
        try candidates.select(choice, composition: composition(), context: context())
        let committed = try candidates.takeSelection(composition: composition(), context: context())
        #expect(committed.text == "日本語")
        #expect(committed.completion.candidateID == "second")
        #expect(committed.remaining.isEmpty)
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
            try candidates.takeSelection(composition: composition(), context: context())
        }
    }

    @Test func workerFailureKeepsTheSelectedPartialCommitButDisablesNewSelections() throws {
        var candidates = DesktopReadingCandidates()
        let request = try candidates.prepare(composition: composition(), context: context())
        _ = try candidates.adopt(batch(request, candidates: [candidate("partial", text: "荷", count: .inputCount(2))]),
                                 composition: composition(), context: context())
        let choice = try choice(in: candidates)
        try candidates.select(choice, composition: composition(), context: context())
        candidates.workerUnavailable()
        #expect(candidates.batch == nil)
        #expect(candidates.selectedText == "荷")
        #expect(candidates.selectedSuffix == "ほんご")
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
            try candidates.select(choice, composition: composition(), context: context())
        }
        let committed = try candidates.takeSelection(composition: composition(), context: context())
        #expect(committed.text == "荷")
        #expect(committed.remaining.convertTarget == "ほんご")
        #expect(committed.completion.workerGeneration == "candidate-process")
    }

    @Test func learningChangesKeepTheDisplayedSelectionAndUseTheCurrentRevision() throws {
        var candidates = DesktopReadingCandidates()
        var current = context()
        let request = try candidates.prepare(composition: composition(), context: current)
        _ = try candidates.adopt(batch(request, candidates: [candidate("selected")]), composition: composition(), context: current)
        let choice = try choice(in: candidates)
        try candidates.select(choice, composition: composition(), context: current)
        try candidates.updateLearningRevision(from: 0, to: 1)
        current.settingsRevision = 1
        let committed = try candidates.takeSelection(composition: composition(), context: current)
        #expect(committed.text == "日本語")
        #expect(committed.completion.authority.settingsRevision == 0)
        #expect(committed.completion.settingsRevision == 1)
    }

    @Test func invalidationMakesEvenACachedSelectionUnavailable() throws {
        var candidates = DesktopReadingCandidates()
        let request = try candidates.prepare(composition: composition(), context: context())
        _ = try candidates.adopt(batch(request, candidates: [candidate("first")]), composition: composition(), context: context())
        let choice = try choice(in: candidates)
        try candidates.select(choice, composition: composition(), context: context())
        candidates.invalidate()
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
            try candidates.takeSelection(composition: composition(), context: context())
        }
    }

    @Test func repeatedCandidateIdentitiesAreRejectedRatherThanMergedByText() throws {
        var candidates = DesktopReadingCandidates()
        let request = try candidates.prepare(composition: composition(), context: context())
        #expect(throws: DesktopReadingCandidates.Failure.invalidBatch) {
            try candidates.adopt(batch(request, candidates: [candidate("same"), candidate("same")]),
                                 composition: composition(), context: context())
        }
    }

    @Test func anActionFromAnOlderListCannotSelectTheSamePositionInANewList() throws {
        var candidates = DesktopReadingCandidates()
        let old = try candidates.prepare(composition: composition(), context: context())
        _ = try candidates.adopt(batch(old, candidates: [candidate("same", text: "古い表示")]),
                                 composition: composition(), context: context())
        let oldChoice = try choice(in: candidates)
        let latest = try candidates.prepare(composition: composition(), context: context())
        _ = try candidates.adopt(batch(latest, candidates: [candidate("same", text: "新しい表示")]),
                                 composition: composition(), context: context())
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
            try candidates.select(oldChoice, composition: composition(), context: context())
        }
        #expect(candidates.selectionIndex == nil)
        let currentChoice = try choice(in: candidates)
        try candidates.select(currentChoice, composition: composition(), context: context())
        #expect(candidates.selectedText == "新しい表示")
    }
}
