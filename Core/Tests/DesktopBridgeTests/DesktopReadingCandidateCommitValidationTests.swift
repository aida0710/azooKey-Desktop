import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingCandidateCommitValidationTests {
    private let fixture = DesktopReadingTestSupport()

    @Test func aRejectedDirectCommitPreservesTheSelectedCandidateWithoutAnOuterWorker() throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        let request = try fixture.request(from: &session)
        let batch = try fixture.batch(request)
        let reference = try session.adoptCandidates(batch)
        let first = DesktopCandidateSelection(batch: reference, candidateID: batch.candidates[0].candidateID)
        _ = try session.selectCandidate(first)
        let before = try DesktopReadingTestSupport.encodedJSON(session.snapshot())
        let view = try DesktopReadingTestSupport.encodedJSON(session.candidateView())
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
            try session.commitCandidate(.init(batch: reference, candidateID: "missing"))
        }
        #expect(try DesktopReadingTestSupport.encodedJSON(session.snapshot()) == before)
        #expect(try DesktopReadingTestSupport.encodedJSON(session.candidateView()) == view)
        let second = batch.candidates[1]
        let committed = try session.commitCandidate(.init(batch: reference, candidateID: second.candidateID))
        #expect(committed.commits == [second.text])
        #expect(committed.candidateCompletions?.first?.candidateID == second.candidateID)
        #expect(committed.candidateCompletions?.count == 1)
        #expect(try session.candidateView() == nil)
    }

    @Test(arguments: ["worker", "batch", "revision", "focus", "candidate"])
    func changingAnyPartOfTheSelectedIdentityCannotCommit(part: String) throws {
        var session = DesktopReadingSession()
        try fixture.type("nihongo", into: &session)
        let request = try fixture.request(from: &session)
        let batch = try fixture.batch(request)
        let reference = try session.adoptCandidates(batch)
        _ = try session.selectCandidate(.init(batch: reference, candidateID: batch.candidates[0].candidateID))
        let authority = reference.authority
        let changed = CandidateRequestAuthority(context: authority.context, readingProcessGeneration: authority.readingProcessGeneration,
            focusEpoch: authority.focusEpoch + (part == "focus" ? 1 : 0),
            compositionRevision: authority.compositionRevision + (part == "revision" ? 1 : 0),
            settingsRevision: authority.settingsRevision, requestID: authority.requestID)
        let wrong = DesktopCandidateBatchReference(authority: changed,
            workerGeneration: part == "worker" ? "other-worker" : reference.workerGeneration,
            batchID: part == "batch" ? "other-batch" : reference.batchID)
        let before = try DesktopReadingTestSupport.encodedJSON(session.snapshot())
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
            try session.commitCandidate(.init(batch: wrong, candidateID: part == "candidate" ? "other-candidate" : batch.candidates[0].candidateID))
        }
        #expect(try DesktopReadingTestSupport.encodedJSON(session.snapshot()) == before)
        #expect(try session.key(fixture.key(36)).commits == ["日本語"])
    }

    @Test(arguments: ["event", "submit", "index", "unknown", "selection-index", "missing-selection"])
    func aCommitRejectsNonidentityPayloadWithoutChangingSelection(extra: String) throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch()
        _ = try fixture.adopt(batch)
        _ = try fixture.select(batch)
        let request = DesktopReadingWorkerRequest(operation: "commit-candidate", reference: fixture.reference,
            selection: .init(batch: fixture.retained(batch), candidateID: "candidate"))
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        switch extra {
        case "selection-index":
            var selection = try #require(payload["selection"] as? [String: Any])
            selection["index"] = 0
            payload["selection"] = selection
        case "missing-selection": payload.removeValue(forKey: "selection")
        default: payload[extra] = true
        }
        let before = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: (any Error).self) {
            let decoded = try JSONDecoder().decode(DesktopReadingWorkerRequest.self, from: bytes)
            return try fixture.worker.process(decoded)
        }
        #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before)
        #expect(try fixture.key(36).commits == ["日本語"])
    }
}
