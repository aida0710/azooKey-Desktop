import Core
@testable import DesktopBridge
import Foundation
import KanaKanjiConverterModule
import Testing

@MainActor
@Suite struct DesktopReadingConversionTests {
    private func key(_ code: UInt16, modifiers: KeyEventCore.ModifierFlag = []) -> KeyEventCore {
        .init(modifierFlags: modifiers, characters: nil, charactersIgnoringModifiers: nil, keyCode: code)
    }

    @discardableResult
    private func type(_ text: String, into session: inout DesktopReadingSession) throws -> DesktopSnapshot {
        var snapshot = session.snapshot()
        for character in text {
            snapshot = try session.key(.init(
                modifierFlags: [], characters: String(character),
                charactersIgnoringModifiers: String(character), keyCode: 0))
        }
        return snapshot
    }

    private func request(
        from session: inout DesktopReadingSession, leftContext: String = ""
    ) throws -> DesktopCandidateRequest {
        try session.prepareCandidates(context: .init(
            context: "field", readingProcessGeneration: "reader", focusEpoch: 1,
            compositionRevision: 0, settingsRevision: 0, leftContext: leftContext, rightContext: "", privateInput: false))
    }

    private func batch(
        _ request: DesktopCandidateRequest, words: [String] = ["日本語", "二本語"], prefixLength: Int? = nil
    ) throws -> DesktopCandidateBatch {
        let count: ComposingCount = prefixLength.map(ComposingCount.surfaceCount)
            ?? .inputCount(request.composition.input.count)
        return try .init(
            authority: request.authority, workerGeneration: "converter", batchID: request.authority.requestID,
            candidates: words.enumerated().map { index, text in
                try .init(candidateID: "candidate-\(index)", text: text, composingCount: .init(count),
                          presentation: .init(tokens: [], annotation: nil, extraValues: [:],
                                              score: nil, comparisonGroup: nil, commitScope: nil))
            })
    }

    @Test func spaceFinalizesTerminalNAndRejectsCandidatesForTheEarlierInput() throws {
        var session = DesktopReadingSession()
        try type("nihon", into: &session)
        let earlier = try request(from: &session)
        #expect(earlier.composition.convertTarget == "にほn")
        let pending = try session.key(key(49))
        #expect(pending.preedit == "にほん")
        #expect(pending.inputState == "composing")
        #expect(pending.request == "candidates")
        #expect(pending.commits.isEmpty)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(batch(earlier, words: ["日本"]))
        }
        let current = try request(from: &session)
        #expect(current.composition.convertTarget == "にほん")
        #expect(current.authority.compositionRevision > earlier.authority.compositionRevision)
        _ = try session.adoptCandidates(batch(current, words: ["日本"]))
        #expect(session.snapshot().preedit == "にほん")
        let selected = try session.key(key(49))
        #expect(selected.preedit == "日本")
        #expect(selected.inputState == "previewing")
        #expect(selected.commits.isEmpty)
        #expect(selected.request == nil)
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["日本"])
        #expect(committed.candidateCompletions?.count == 1)
    }

    @Test func downSelectsOnlyAfterArrivalAndNavigationCommitsTheChosenIdentity() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        let waiting = try session.key(key(125))
        #expect(waiting.request == "candidates")
        #expect(waiting.preedit == "にほんご")
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request))
        #expect(session.snapshot().inputState == "composing")
        let first = try session.key(key(125))
        #expect(first.preedit == "日本語")
        #expect(first.inputState == "selecting")
        #expect(first.selection == 0)
        let second = try session.key(key(49))
        #expect(second.preedit == "二本語")
        #expect(second.selection == 1)
        #expect(second.generation == first.generation + 1)
        let previous = try session.key(key(49, modifiers: .shift))
        #expect(previous.preedit == "日本語")
        let wrapped = try session.key(key(126))
        #expect(wrapped.preedit == "二本語")
        let committed = try session.key(key(0x4C))
        #expect(committed.commits == ["二本語"])
        #expect(committed.candidateCompletions?.first?.candidateID == "candidate-1")
        #expect(committed.candidateCompletions?.first?.batchID == request.authority.requestID)
    }

    @Test func aPendingSegmentRangeSurvivesAnotherSpaceAndCommitsOnlyItsPrefix() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        let edited = try session.key(key(123, modifiers: .shift))
        #expect(edited.request == "candidates")
        #expect(edited.preedit == "にほんご")
        let first = try request(from: &session)
        #expect(first.composition.conversionRangeEnd == 3)
        _ = try session.key(key(49))
        let current = try request(from: &session)
        #expect(current.composition.conversionRangeEnd == 3)
        #expect(current.authority.requestID != first.authority.requestID)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(batch(first, words: ["日本"], prefixLength: 3))
        }
        _ = try session.adoptCandidates(batch(current, words: ["日本"], prefixLength: 3))
        #expect(session.snapshot().preedit == "にほんご")
        let selected = try session.key(key(49))
        #expect(selected.preedit == "日本ご")
        #expect(selected.inputState == "selecting")
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["日本"])
        #expect(committed.preedit == "ご")
        #expect(committed.candidateCompletions?.count == 1)
        let suffix = try session.key(key(0x24))
        #expect(suffix.commits == ["ご"])
        #expect(suffix.candidateCompletions == nil)
    }

    @Test func shiftingASelectedPrefixStartsFromThatCandidatesRealConsumption() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        let first = try request(from: &session)
        _ = try session.adoptCandidates(batch(first, words: ["荷"], prefixLength: 1))
        _ = try session.selectCurrentCandidate(index: 0)
        let edited = try session.key(key(124, modifiers: .shift))
        #expect(edited.preedit == "にほんご")
        #expect(edited.request == "candidates")
        let current = try request(from: &session)
        #expect(current.composition.conversionRangeEnd == 2)
        #expect(current.authority.compositionRevision > first.authority.compositionRevision)
    }

    @Test func escapeCancelsPendingConversionBeforeCancellingTheReading() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        _ = try session.key(key(123, modifiers: .shift))
        let pending = try request(from: &session)
        let cancelled = try session.key(key(53))
        #expect(cancelled.preedit == "にほんご")
        #expect(cancelled.inputState == "composing")
        #expect(cancelled.request == nil)
        #expect(cancelled.commits.isEmpty)
        #expect(session.composition.conversionRangeEnd == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(batch(pending, words: ["日本"], prefixLength: 3))
        }
        let empty = try session.key(key(53))
        #expect(empty.preedit.isEmpty)
        #expect(empty.commits.isEmpty)
    }

    @Test func typingWhileWaitingKeepsTheReadingAndRetiresTheOldSegmentRequest() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        _ = try session.key(key(123, modifiers: .shift))
        let pending = try request(from: &session)
        let edited = try type("a", into: &session)
        #expect(edited.preedit == "にほんごあ")
        #expect(edited.commits.isEmpty)
        #expect(session.composition.conversionRangeEnd == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(batch(pending, words: ["日本"], prefixLength: 3))
        }
        let cancelled = try session.key(key(53))
        #expect(cancelled.preedit.isEmpty)
    }

    @Test func typingAfterAPartialSelectionCommitsItsDisplayWithoutInventingALearningCandidate() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request, words: ["荷"], prefixLength: 1))
        _ = try session.selectCurrentCandidate(index: 0)
        let continued = try type("a", into: &session)
        #expect(continued.commits == ["荷ほんご"])
        #expect(continued.preedit == "あ")
        #expect(continued.candidateCompletions == nil)
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["あ"])
    }

    @Test func enterWhileCandidatesArePendingCommitsTheReadingAndRetiresTheReply() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        _ = try session.key(key(49))
        let pending = try request(from: &session)
        session.candidateWorkerUnavailable()
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["にほんご"])
        #expect(committed.preedit.isEmpty)
        #expect(committed.candidateCompletions == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(batch(pending))
        }
        let next = try type("a", into: &session)
        #expect(next.preedit == "あ")
    }

    @Test func arrivalOfAnEmptyBatchCannotClearOrCommitTheReading() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        _ = try session.key(key(49))
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request, words: []))
        let retried = try session.key(key(49))
        #expect(retried.request == "candidates")
        #expect(retried.preedit == "にほんご")
        #expect(retried.commits.isEmpty)
        #expect(retried.inputState == "composing")
        #expect(retried.candidateCompletions == nil)
    }

    @Test func previewPrefersAWholeReadingCandidateWithoutCombiningCandidateWords() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        _ = try session.key(key(49))
        let request = try request(from: &session)
        let prefix = try batch(request, words: ["荷"], prefixLength: 1).candidates[0]
        let whole = try batch(request).candidates[1]
        _ = try session.adoptCandidates(.init(
            authority: request.authority, workerGeneration: "converter", batchID: "mixed",
            candidates: [prefix, whole]))
        let selected = try session.key(key(49))
        #expect(selected.preedit == "二本語")
        #expect(selected.selection == 1)
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["二本語"])
        #expect(committed.candidateCompletions?.first?.candidateID == whole.candidateID)
        #expect(committed.candidateCompletions?.first?.batchID == "mixed")
    }

    @Test func rightCommitsOnlyTheSelectedPrefixAndEnterCanFinishTheWaitingSuffix() throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        let first = try request(from: &session)
        _ = try session.adoptCandidates(batch(first, words: ["荷"], prefixLength: 1))
        _ = try session.selectCurrentCandidate(index: 0)
        let prefix = try session.key(key(124))
        #expect(prefix.commits == ["荷"])
        #expect(prefix.preedit == "ほんご")
        #expect(prefix.inputState == "composing")
        #expect(prefix.request == "candidates")
        #expect(prefix.candidateCompletions?.count == 1)
        let pending = try request(from: &session, leftContext: "荷")
        let suffix = try session.key(key(0x24))
        #expect(suffix.commits == ["ほんご"])
        #expect(suffix.preedit.isEmpty)
        #expect(suffix.candidateCompletions == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(batch(pending, words: ["本語"]))
        }
    }

    @Test(arguments: [UInt16(49), UInt16(125)])
    func rightThenArrivalNeedsAnExplicitKeyToSelectTheSuffix(keyCode: UInt16) throws {
        var session = DesktopReadingSession()
        try type("nihongo", into: &session)
        let first = try request(from: &session)
        _ = try session.adoptCandidates(batch(first, words: ["荷"], prefixLength: 1))
        _ = try session.selectCurrentCandidate(index: 0)
        _ = try session.key(key(124))
        let suffix = try request(from: &session, leftContext: "荷")
        _ = try session.adoptCandidates(batch(suffix, words: ["本語"]))
        let reading = session.snapshot()
        #expect(reading.preedit == "ほんご")
        #expect(reading.inputState == "composing")
        #expect(reading.commits.isEmpty)
        let selected = try session.key(key(keyCode))
        #expect(selected.preedit == "本語")
        #expect(selected.inputState == "selecting")
        #expect(selected.commits.isEmpty)
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["本語"])
        #expect(committed.candidateCompletions?.count == 1)
    }
}
