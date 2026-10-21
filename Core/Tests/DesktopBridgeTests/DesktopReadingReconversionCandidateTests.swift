import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingReconversionCandidateTests {
    private typealias Support = DesktopReadingReconversionTestSupport

    @Test func resolvedReconversionCommitsOnlyANewRealCandidateAndCompletesLearningOnce() throws {
        try DesktopCandidateTestSupport.withWorker { candidateWorker, directory in
            var fixture = try DesktopReadingWorkerFixture()
            let beforeMemory = try DesktopCandidateTestSupport.memory(in: directory)
            let prepared = try fixture.worker.process(.init(operation: "reconvert", reference: fixture.reference,
                candidateWorkerGeneration: candidateWorker.workerGeneration,
                reconversionContext: Support.document(selected: "ニホンゴ")))
            let query = try #require(prepared.reconversionReadingRequest)
            let lookup = try candidateWorker.process(.init(operation: "resolve-reconversion-reading", reconversionReadingRequest: query))
            let resolved = try fixture.worker.process(.init(operation: "resolve-reconversion", reference: fixture.reference,
                reconversionContext: Support.document(selected: "ニホンゴ"), reconversionReadingResult: lookup.reconversionReadingResult))
            let token = try #require(resolved.reconversion?.token)
            let confirmed = try Support.confirm(&fixture, token: token)
            #expect(confirmed.snapshot?.preedit == "にほんご")
            let beforeAdopt = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
            let requested = try fixture.worker.process(.init(operation: "prepare-candidates", reference: fixture.reference,
                candidateWorkerGeneration: candidateWorker.workerGeneration))
            let batch = try DesktopCandidateTestSupport.batch(candidateWorker, request: #require(requested.candidateRequest))
            try DesktopCandidateTestSupport.retain(candidateWorker, batch)
            _ = try fixture.adopt(batch)
            #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == beforeAdopt)
            #expect(try DesktopCandidateTestSupport.memory(in: directory) == beforeMemory)
            let candidate = try #require(batch.candidates.first { $0.text == "日本語" })
            let selection = DesktopCandidateSelection(batch: fixture.retained(batch), candidateID: candidate.candidateID)
            let committed = try fixture.worker.process(.init(operation: "commit-candidate", reference: fixture.reference,
                selection: selection, reconversionContext: Support.document()))
            let snapshot = try #require(committed.snapshot)
            #expect(snapshot.commits == ["日本語"])
            #expect(snapshot.preedit.isEmpty)
            #expect(snapshot.candidateCompletions?.count == 1)
            let completion = try #require(snapshot.candidateCompletions?.first)
            #expect(completion.candidateID == candidate.candidateID)
            #expect(completion.batchID == batch.batchID)
            let receipt = try DesktopCandidateTestSupport.complete(candidateWorker, completion)
            #expect(receipt.status == .completed && receipt.learningRequested)
            let afterLearning = try DesktopCandidateTestSupport.memory(in: directory)
            #expect(try DesktopCandidateTestSupport.complete(candidateWorker, completion).status == .alreadyCompleted)
            #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
                try fixture.worker.process(.init(operation: "commit-candidate", reference: fixture.reference, selection: selection))
            }
            #expect(try fixture.snapshot().candidateCompletions == nil)
            #expect(try DesktopCandidateTestSupport.memory(in: directory) == afterLearning)
            #expect(try fixture.key(53).commits.isEmpty)
        }
    }
}
