import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingCandidateSessionTests {
    private func key(_ code: UInt16) -> KeyEventCore {
        .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: code)
    }

    private func enter(_ text: String, into session: inout DesktopReadingSession) throws {
        for character in text {
            _ = try session.key(.init(modifierFlags: [], characters: String(character),
                                      charactersIgnoringModifiers: String(character), keyCode: 0))
        }
    }

    private func request(
        from session: inout DesktopReadingSession, leftContext: String = ""
    ) throws -> DesktopCandidateRequest {
        try session.prepareCandidates(context: .init(
            context: "field", readingProcessGeneration: "reading-process", focusEpoch: 1,
            compositionRevision: 0, settingsRevision: 0, leftContext: leftContext, rightContext: "", privateInput: false))
    }

    private func batch(_ request: DesktopCandidateRequest, partial: Bool = false) throws -> DesktopCandidateBatch {
        try .init(authority: request.authority, workerGeneration: "candidate-process", batchID: "batch",
              candidates: [.init(candidateID: "candidate", text: partial ? "荷" : "日本語",
                                 composingCount: .init(.inputCount(partial ? 2 : 7)),
                                 presentation: .init(tokens: [], annotation: nil, extraValues: [:],
                                                     score: nil, comparisonGroup: nil, commitScope: nil))])
    }

    @Test func candidateArrivalCannotReplaceTheVisibleReading() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let request = try request(from: &session)
        let before = session.snapshot()
        _ = try session.adoptCandidates(batch(request))
        let after = session.snapshot()
        #expect(after.preedit == "にほんご")
        #expect(after.preedit == before.preedit)
        #expect(after.cursor == before.cursor)
        #expect(after.generation == before.generation)
        #expect(after.inputState == before.inputState)
        #expect(after.commits.isEmpty)
    }

    @Test func enterCommitsTheDisplayedSelectionOnceAfterTheWorkerStops() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request))
        let selected = try session.selectCurrentCandidate(index: 0)
        #expect(selected.preedit == "日本語")
        session.candidateWorkerUnavailable()
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["日本語"])
        #expect(committed.preedit.isEmpty)
        #expect(committed.candidateCompletions?.count == 1)
        #expect(committed.candidateCompletions?.first?.candidateID == "candidate")
        let following = try session.key(key(0x24))
        #expect(!following.consumed)
        #expect(following.commits.isEmpty)
        #expect(following.candidateCompletions == nil)
    }

    @Test func partialCommitKeepsTheSuffixAndItsNextReadingCommit() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request, partial: true))
        let selected = try session.selectCurrentCandidate(index: 0)
        #expect(selected.preedit == "荷ほんご")
        #expect(selected.cursor == 1)
        let committed = try session.key(key(0x4C))
        #expect(committed.commits == ["荷"])
        #expect(committed.preedit == "ほんご")
        #expect(committed.reading == "ほんご")
        #expect(committed.candidateCompletions?.count == 1)
        let suffix = try session.key(key(0x24))
        #expect(suffix.commits == ["ほんご"])
        #expect(suffix.preedit.isEmpty)
        #expect(suffix.candidateCompletions == nil)
        try enter("a", into: &session)
        #expect(session.snapshot().preedit == "あ")
    }

    @Test func partialCommitRequestsAndCommitsTheRemainingReadingWithItsUpdatedContext() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let first = try request(from: &session)
        _ = try session.adoptCandidates(batch(first, partial: true))
        _ = try session.selectCurrentCandidate(index: 0)
        let prefix = try session.key(key(0x24))
        #expect(prefix.commits == ["荷"])
        let prefixCompletion = try #require(prefix.candidateCompletions?.first)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try request(from: &session)
        }
        let remaining = try request(from: &session, leftContext: "荷")
        #expect(remaining.leftContext == "荷")
        #expect(remaining.authority.compositionRevision > first.authority.compositionRevision)
        let next = try DesktopCandidateBatch(
            authority: remaining.authority, workerGeneration: "candidate-process", batchID: "remaining",
            candidates: [.init(candidateID: "suffix", text: "本語", composingCount: .init(.inputCount(5)),
                               presentation: .init(tokens: [], annotation: nil, extraValues: [:],
                                                   score: nil, comparisonGroup: nil, commitScope: nil))])
        _ = try session.adoptCandidates(next)
        let selected = try session.selectCurrentCandidate(index: 0)
        #expect(selected.preedit == "本語")
        let suffix = try session.key(key(0x24))
        #expect(suffix.commits == ["本語"])
        #expect(suffix.preedit.isEmpty)
        let suffixCompletion = try #require(suffix.candidateCompletions?.first)
        #expect(suffixCompletion.candidateID == "suffix")
        #expect(suffixCompletion.commitID != prefixCompletion.commitID)
    }

    @Test func editingTheSelectedReadingMakesTheOldBatchUnavailable() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let request = try request(from: &session)
        let incoming = try batch(request)
        _ = try session.adoptCandidates(incoming)
        _ = try session.selectCurrentCandidate(index: 0)
        let moved = try session.key(key(0x73))
        #expect(moved.preedit == "にほんご")
        #expect(moved.cursor == 0)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(incoming)
        }
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["にほんご"])
        #expect(committed.candidateCompletions == nil)
    }

    @Test func anUnsupportedActionKeepsTheDisplayedCommitTarget() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request))
        _ = try session.selectCurrentCandidate(index: 0)
        let before = session.snapshot()
        #expect(throws: DesktopReadingSession.Failure.unsupportedAction) {
            try session.key(key(101))
        }
        #expect(session.snapshot().preedit == before.preedit)
        #expect(session.snapshot().generation == before.generation)
        let committed = try session.key(key(0x24))
        #expect(committed.commits == ["日本語"])
    }

    @Test func resetCommitsExactlyTheDisplayedTextIncludingItsUnconvertedSuffix() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request, partial: true))
        _ = try session.selectCurrentCandidate(index: 0)
        let reset = try session.reset(commit: true)
        #expect(reset.commits == ["荷ほんご"])
        #expect(reset.preedit.isEmpty)
        // A displayed candidate plus raw suffix is not a new synthetic candidate to learn.
        #expect(reset.candidateCompletions == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(batch(request, partial: true))
        }
    }

    @Test func deletionAtTheEndLeavesReadingModeReadyForANewCandidateRequest() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let first = try request(from: &session)
        _ = try session.adoptCandidates(batch(first))
        _ = try session.selectCurrentCandidate(index: 0)
        let unchanged = try session.key(key(0x75))
        #expect(unchanged.reading == "にほんご")
        #expect(unchanged.preedit == "にほんご")
        #expect(unchanged.inputState == "composing")
        let next = try request(from: &session)
        #expect(next.authority.requestID != first.authority.requestID)
        _ = try session.adoptCandidates(batch(next))
        let selected = try session.selectCurrentCandidate(index: 0)
        #expect(selected.preedit == "日本語")
    }

    @Test(arguments: [UInt16(0x75), UInt16(0x77)])
    func leavingSelectionWithoutChangingReadingCannotLearnTheOldDisplay(keyCode: UInt16) throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request))
        _ = try session.selectCurrentCandidate(index: 0)
        let reading = try session.key(key(keyCode))
        #expect(reading.preedit == "にほんご")
        let reset = try session.reset(commit: true)
        #expect(reset.commits == ["にほんご"])
        #expect(reset.candidateCompletions == nil)
    }

    @Test func switchingToEnglishCommitsTheDisplayedCandidateAndThenTypesDirectly() throws {
        var session = DesktopReadingSession()
        try enter("nihongo", into: &session)
        let request = try request(from: &session)
        _ = try session.adoptCandidates(batch(request))
        _ = try session.selectCurrentCandidate(index: 0)
        let switched = try session.key(key(102))
        #expect(switched.commits == ["日本語"])
        #expect(switched.candidateCompletions?.count == 1)
        #expect(switched.language == "english")
        #expect(switched.inputState == "none")
        let typed = try session.key(.init(
            modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a", keyCode: 0))
        #expect(typed.commits == ["a"])
        #expect(typed.preedit.isEmpty)
        #expect(typed.candidateCompletions == nil)
    }
}
