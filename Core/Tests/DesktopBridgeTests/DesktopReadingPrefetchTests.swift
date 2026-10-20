import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingPrefetchTests {
    private let fixture = DesktopReadingTestSupport()

    @Test func defaultInputStillWaitsForAnExplicitConversionRequest() throws {
        var session = DesktopReadingSession()
        let reading = try fixture.type("nihongo", into: &session)
        #expect(reading.request == nil)
        #expect(reading.preedit == "にほんご")
        #expect(try session.key(fixture.key(49)).request == "candidates")
    }

    @Test func editedReadingRequestsCandidatesWithoutSelectingOrChangingTheInput() throws {
        var session = DesktopReadingSession(candidateRequestMode: .afterEditing)
        let reading = try fixture.type("nihongo", into: &session)
        #expect(reading.request == "candidates")
        #expect(reading.preedit == "にほんご")
        #expect(reading.inputState == "composing")
        #expect(reading.selection == nil)
        #expect(reading.commits.isEmpty)
        #expect(reading.candidateCompletions == nil)
        let request = try fixture.request(from: &session)
        #expect(request.authority.compositionRevision == reading.compositionRevision)
        let before = try DesktopReadingTestSupport.encodedJSON(session.snapshot())
        _ = try session.adoptCandidates(fixture.batch(request))
        #expect(try DesktopReadingTestSupport.encodedJSON(session.snapshot()) == before)
        let committed = try session.key(fixture.key(0x24))
        #expect(committed.commits == ["にほんご"])
        #expect(committed.candidateCompletions == nil)
    }

    @Test func editingRetiresPrefetchedCandidatesAndUsesTheCurrentCursor() throws {
        var session = DesktopReadingSession(candidateRequestMode: .afterEditing)
        try fixture.type("nihongo", into: &session)
        let earlier = try fixture.request(from: &session)
        let moved = try session.key(fixture.key(123))
        #expect(moved.request == "candidates")
        #expect(moved.preedit == "にほんご")
        #expect(moved.cursor == 3)
        let current = try fixture.request(from: &session)
        #expect(current.authority.compositionRevision > earlier.authority.compositionRevision)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(fixture.batch(earlier))
        }
        let deleted = try session.key(fixture.key(51))
        #expect(deleted.request == "candidates")
        #expect(deleted.preedit == "にほご")
        #expect(deleted.cursor == 2)
        #expect(deleted.commits.isEmpty)
        #expect(deleted.candidateCompletions == nil)
    }

    @Test func unchangedCursorAndEmptyReadingDoNotRequestWork() throws {
        var session = DesktopReadingSession(candidateRequestMode: .afterEditing)
        try fixture.type("a", into: &session)
        #expect(try session.key(fixture.key(124)).request == nil)
        let empty = try session.key(fixture.key(51))
        #expect(empty.preedit.isEmpty)
        #expect(empty.request == nil)
        let english = try session.key(fixture.key(102))
        #expect(english.request == nil)
        let direct = try fixture.type("a", into: &session)
        #expect(direct.commits == ["a"])
        #expect(direct.request == nil)
    }

    @Test func prefetchedArrivalCannotBypassTheExistingCompositionSeparator() throws {
        var session = DesktopReadingSession(candidateRequestMode: .afterEditing)
        try fixture.type("nihongo", into: &session)
        let request = try fixture.request(from: &session)
        _ = try session.adoptCandidates(fixture.batch(request))
        let normalized = try session.key(fixture.key(49))
        #expect(normalized.preedit == "にほんご")
        #expect(normalized.request == "candidates")
        #expect(normalized.commits.isEmpty)
        #expect(normalized.candidateCompletions == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(fixture.batch(request))
        }
        let current = try fixture.request(from: &session)
        #expect(current.authority.compositionRevision > request.authority.compositionRevision)
        _ = try session.adoptCandidates(fixture.batch(current))
        let selected = try session.key(fixture.key(49))
        #expect(selected.preedit == "日本語")
        #expect(selected.inputState == "previewing")
        #expect(selected.request == nil)
        #expect(selected.commits.isEmpty)
        #expect(selected.candidateCompletions == nil)
        let committed = try session.key(fixture.key(0x24))
        #expect(committed.commits == ["日本語"])
        #expect(committed.candidateCompletions?.count == 1)
        #expect(committed.candidateCompletions?.first?.candidateID == "candidate-0")
        #expect(committed.candidateCompletions?.first?.batchID == current.authority.requestID)
        let repeated = try session.key(fixture.key(0x24))
        #expect(repeated.commits.isEmpty)
        #expect(repeated.candidateCompletions == nil)
    }

    @Test func cancellingAPendingRangeDoesNotStartAnotherPrefetch() throws {
        var session = DesktopReadingSession(candidateRequestMode: .afterEditing)
        try fixture.type("nihongo", into: &session)
        _ = try session.key(fixture.key(123, modifiers: .shift))
        let pending = try fixture.request(from: &session)
        let cancelled = try session.key(fixture.key(53))
        #expect(cancelled.preedit == "にほんご")
        #expect(cancelled.request == nil)
        #expect(session.composition.conversionRangeEnd == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(fixture.batch(pending, words: ["日本"], prefixLength: 3))
        }
        #expect(try session.key(fixture.key(53)).preedit.isEmpty)
    }

    @Test func aPartialCommitKeepsItsSuffixAndOnlyLearnsTheExplicitPrefix() throws {
        var session = DesktopReadingSession(candidateRequestMode: .afterEditing)
        try fixture.type("nihongo", into: &session)
        let request = try fixture.request(from: &session)
        _ = try session.adoptCandidates(fixture.batch(request, words: ["荷"], prefixLength: 1))
        _ = try session.selectCurrentCandidate(index: 0)
        let prefix = try session.key(fixture.key(124))
        #expect(prefix.commits == ["荷"])
        #expect(prefix.preedit == "ほんご")
        #expect(prefix.request == "candidates")
        #expect(prefix.candidateCompletions?.count == 1)
        let pending = try fixture.request(from: &session, leftContext: "荷")
        _ = try session.adoptCandidates(fixture.batch(pending, words: ["本語"]))
        let suffix = try session.key(fixture.key(0x24))
        #expect(suffix.commits == ["ほんご"])
        #expect(suffix.candidateCompletions == nil)
    }

    @Test func workerLossAndResetRetirePrefetchWithoutLosingTheReading() throws {
        var session = DesktopReadingSession(candidateRequestMode: .afterEditing)
        try fixture.type("nihongo", into: &session)
        let pending = try fixture.request(from: &session)
        session.candidateWorkerUnavailable()
        #expect(session.snapshot().preedit == "にほんご")
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(fixture.batch(pending))
        }
        let continued = try fixture.type("a", into: &session)
        #expect(continued.request == "candidates")
        #expect(continued.preedit == "にほんごあ")
        let next = try fixture.request(from: &session)
        let reset = try session.reset(commit: false)
        #expect(reset.preedit.isEmpty)
        #expect(reset.commits.isEmpty)
        #expect(reset.candidateCompletions == nil)
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) {
            try session.adoptCandidates(fixture.batch(next))
        }
    }
}
