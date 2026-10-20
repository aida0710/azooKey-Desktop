import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingMainIdentityTests {
    private func markingMain(_ batch: DesktopCandidateBatch, id: String = "candidate") -> DesktopCandidateBatch {
        .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID,
              candidates: batch.candidates, mainCandidateID: id)
    }

    @Test(arguments: [false, true])
    func mainArrivalHasNoInputEffectsAndDoesNotChangeExplicitSelection(partial: Bool) throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = markingMain(try fixture.batch(partial: partial))
        let before = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        let adopted = try fixture.adopt(batch)
        #expect(adopted.kind == .acknowledgement)
        #expect(adopted.snapshot == nil)
        #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before)
        #expect(try fixture.select(batch).preedit == (partial ? "荷ほんご" : "日本語"))
        let committed = try fixture.key(36)
        #expect(committed.commits == [partial ? "荷" : "日本語"])
        #expect(committed.preedit == (partial ? "ほんご" : ""))
        #expect(committed.candidateCompletions?.count == 1)
        #expect(committed.candidateCompletions?.first?.candidateID == batch.mainCandidateID)
    }

    @Test func aMainIDOutsideTheBatchIsRejectedWithoutConsumingThePendingRequest() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch()
        #expect(throws: DesktopReadingCandidates.Failure.invalidBatch) {
            try fixture.adopt(markingMain(batch, id: "absent"))
        }
        #expect(try fixture.snapshot().preedit == "にほんご")
        #expect(try fixture.snapshot().selection == nil)
        #expect(try fixture.adopt(markingMain(batch)).snapshot == nil)
    }

    @Test func mainMetadataCannotMakeAnOldWorkerOrCompositionCurrent() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let earlier = markingMain(try fixture.batch())
        let wrongWorker = DesktopCandidateBatch(authority: earlier.authority, workerGeneration: "old-converter",
                                               batchID: earlier.batchID, candidates: earlier.candidates,
                                               mainCandidateID: earlier.mainCandidateID)
        #expect(throws: DesktopReadingProtocolFailure.wrongCandidateWorker) { try fixture.adopt(wrongWorker) }
        _ = try fixture.key(text: "a")
        #expect(throws: DesktopReadingCandidates.Failure.staleRequest) { try fixture.adopt(earlier) }
        #expect(try fixture.snapshot().preedit == "にほんごあ")
        #expect(try fixture.snapshot().commits.isEmpty)
    }

    @Test func aMainCandidateWithInvalidConsumptionDoesNotAuthorizeTheBatch() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch()
        let original = try #require(batch.candidates.first)
        let invalid = DesktopCandidateItem(candidateID: original.candidateID, text: original.text,
                                           composingCount: try .init(.inputCount(8)), presentation: original.presentation)
        let incoming = DesktopCandidateBatch(authority: batch.authority, workerGeneration: batch.workerGeneration,
                                             batchID: batch.batchID, candidates: [invalid], mainCandidateID: invalid.candidateID)
        #expect(throws: (any Error).self) { try fixture.adopt(incoming) }
        #expect(try fixture.snapshot().preedit == "にほんご")
        #expect(try fixture.adopt(markingMain(batch)).snapshot == nil)
    }

    @Test func mainMetadataCannotChangeTheExistingWholeCandidatePreference() throws {
        let support = DesktopReadingTestSupport()
        var session = DesktopReadingSession()
        try support.type("nihongo", into: &session)
        _ = try session.key(support.key(49))
        let request = try support.request(from: &session)
        let prefix = try support.batch(request, words: ["荷"], prefixLength: 1).candidates[0]
        let whole = try support.batch(request).candidates[1]
        _ = try session.adoptCandidates(.init(
            authority: request.authority, workerGeneration: "converter", batchID: "mixed",
            candidates: [prefix, whole], mainCandidateID: prefix.candidateID))
        #expect(session.snapshot().preedit == "にほんご")
        let selected = try session.key(support.key(49))
        #expect(selected.selection == 1)
        #expect(selected.preedit == whole.text)
        let committed = try session.key(support.key(36))
        #expect(committed.candidateCompletions?.first?.candidateID == whole.candidateID)
    }
}
