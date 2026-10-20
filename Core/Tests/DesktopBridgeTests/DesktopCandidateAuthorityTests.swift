import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopCandidateAuthorityTests {
    private typealias Fixture = DesktopCandidateTestSupport

    @Test func staleRequestsAndInvalidSnapshotsLeaveTheRetainedBatchUsable() throws {
        try Fixture.withWorker { worker, _ in
            let request = try Fixture.request("nihongo", focus: 3, revision: 4)
            let selected = try Fixture.batch(worker, request: request)
            try Fixture.retain(worker, selected)
            for stale in [request,
                          try Fixture.request("a", focus: 2, revision: 5),
                          try Fixture.request("a", focus: 3, revision: 3),
                          try Fixture.request("a", generation: "reader-2", focus: 3, revision: 5),
                          try Fixture.request("a", focus: 3, revision: 5, settings: 1)] {
                #expect(throws: DesktopCandidateFailure.staleAuthority) { try Fixture.batch(worker, request: stale) }
            }
            let invalid = try Fixture.request("a", focus: -1, revision: 5)
            #expect(throws: DesktopCandidateFailure.invalidRequest) { try Fixture.batch(worker, request: invalid) }
            let encoded = try request.composition.encoded()
            var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            json["convertTarget"] = "別の読み"
            let inconsistent = try CompositionSnapshot.decode(JSONSerialization.data(withJSONObject: json))
            let newerAuthority = try Fixture.request("a", focus: 3, revision: 5).authority
            let changed = DesktopCandidateRequest(authority: newerAuthority, composition: inconsistent,
                                                  leftContext: "", rightContext: "", privateInput: false)
            #expect(throws: CompositionSnapshotError.inconsistentReading) { try Fixture.batch(worker, request: changed) }
            #expect(try Fixture.complete(worker, Fixture.completion(selected, text: "日本語")).status == .completed)
        }
    }

    @Test func crossContextAndUnknownIDsCannotCompleteAnotherContextsCandidate() throws {
        try Fixture.withWorker { worker, _ in
            let first = try Fixture.batch(worker, request: Fixture.request("kyou", context: "first"))
            let second = try Fixture.batch(worker, request: Fixture.request("nihongo", context: "second"))
            try Fixture.retain(worker, first)
            try Fixture.retain(worker, second)
            let original = try Fixture.completion(first, text: "京")
            let foreign = DesktopCandidateCompletion(authority: second.authority, workerGeneration: first.workerGeneration,
                                                      batchID: first.batchID, candidateID: original.candidateID,
                                                      commitID: original.commitID, settingsRevision: 0, privateInput: false)
            #expect(throws: DesktopCandidateFailure.unknownBatch) { try Fixture.complete(worker, foreign) }
            let unknown = DesktopCandidateCompletion(authority: first.authority, workerGeneration: first.workerGeneration,
                                                      batchID: first.batchID, candidateID: UUID().uuidString,
                                                      commitID: original.commitID, settingsRevision: 0, privateInput: false)
            #expect(throws: DesktopCandidateFailure.unknownCandidate) { try Fixture.complete(worker, unknown) }
            let otherWorker = DesktopCandidateCompletion(authority: first.authority, workerGeneration: UUID().uuidString,
                                                          batchID: first.batchID, candidateID: original.candidateID,
                                                          commitID: original.commitID, settingsRevision: 0, privateInput: false)
            #expect(throws: DesktopCandidateFailure.wrongWorkerGeneration) { try Fixture.complete(worker, otherWorker) }
            #expect(try Fixture.complete(worker, original).status == .completed)
            #expect(try Fixture.complete(worker, Fixture.completion(second, text: "日本語")).status == .completed)
        }
    }

    @Test func releaseAndCloseEndTheReferenceLifetimeWithoutACommit() throws {
        try Fixture.withWorker { worker, directory in
            let first = try Fixture.batch(worker, request: Fixture.request("kyou"))
            try Fixture.retain(worker, first)
            let before = try Fixture.memory(in: directory)
            _ = try worker.process(.init(operation: "release", reference: Fixture.reference(first)))
            #expect(throws: DesktopCandidateFailure.unknownBatch) {
                try Fixture.complete(worker, Fixture.completion(first, text: "京"))
            }
            let second = try Fixture.batch(worker, request: Fixture.request("kyou", revision: 2))
            try Fixture.retain(worker, second)
            #expect(throws: DesktopCandidateFailure.staleAuthority) {
                try worker.process(.init(operation: "close", workerGeneration: worker.workerGeneration,
                                         context: "field", readingProcessGeneration: "reader-2"))
            }
            _ = try worker.process(.init(operation: "close", workerGeneration: worker.workerGeneration,
                                         context: "field", readingProcessGeneration: "reader-1"))
            #expect(throws: DesktopCandidateFailure.unknownBatch) {
                try Fixture.complete(worker, Fixture.completion(second, text: "京"))
            }
            #expect(try Fixture.memory(in: directory) == before)
            let reopened = try Fixture.batch(worker, request: Fixture.request("nihongo", generation: "reader-2"))
            #expect(reopened.candidates.contains { $0.text == "日本語" })
        }
    }

    @Test func retainingBeyondTheBoundDoesNotDiscardPreviouslySelectedCandidates() throws {
        try Fixture.withWorker { worker, _ in
            var retained: [DesktopCandidateBatch] = []
            for revision in 1...DesktopCandidateLimits.retainedBatches {
                let batch = try Fixture.batch(worker, request: Fixture.request("kyou", revision: revision))
                try Fixture.retain(worker, batch)
                retained.append(batch)
            }
            let excess = try Fixture.batch(worker, request: Fixture.request("kyou", revision: DesktopCandidateLimits.retainedBatches + 1))
            #expect(throws: DesktopCandidateFailure.retainedBatchLimit) { try Fixture.retain(worker, excess) }
            let first = try #require(retained.first)
            #expect(try Fixture.complete(worker, Fixture.completion(first, text: "京")).status == .completed)
            try Fixture.retain(worker, excess)
            #expect(try Fixture.complete(worker, Fixture.completion(excess, text: "京")).status == .completed)
        }
    }
}
