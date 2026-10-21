import Core
@testable import DesktopBridge
import Testing

@MainActor
@Suite struct DesktopReadingReconversionCancellationTests {
    private typealias Support = DesktopReadingReconversionTestSupport

    @Test(arguments: ["reset", "focus-out"], ["prepared", "confirmed", "selected"])
    func nonSubmittingControlsClearReconversionWithoutReturningTextOrLearning(operation: String, stage: String) throws {
        var fixture = try DesktopReadingWorkerFixture()
        let token = try #require(Support.prepare(&fixture).reconversion?.token)
        if stage != "prepared" { _ = try Support.confirm(&fixture, token: token) }
        let selection = stage == "selected" ? try selectWholeCandidate(&fixture) : nil
        let originalReference = fixture.reference
        let response = try fixture.worker.process(.init(operation: operation, reference: originalReference, submit: false))
        let cleared = try #require(response.snapshot)
        #expect(response.kind == .input && response.reference == originalReference)
        #expect(cleared.commits.isEmpty)
        #expect(cleared.preedit.isEmpty && cleared.reading.isEmpty)
        #expect(cleared.selection == nil && cleared.candidateCompletions == nil)
        #expect(cleared.canUndoCommit == false && cleared.request == nil)
        #expect(response.candidateView == nil)

        if operation == "focus-out" {
            #expect(throws: DesktopReadingProtocolFailure.staleFocus) {
                try fixture.worker.process(.init(operation: "reset", reference: originalReference, submit: false))
            }
            let focused = try fixture.worker.process(.init(operation: "focus-in", reference: #require(response.nextReference),
                surroundings: .init(leftContext: "別", rightContext: "", privateInput: false)))
            fixture.reference = try #require(focused.reference)
        }
        let rejected = try Support.confirm(&fixture, token: token)
        #expect(rejected.reconversionError == "stale_request")
        #expect(rejected.snapshot?.commits.isEmpty == true && rejected.snapshot?.preedit.isEmpty == true)
        if let selection {
            #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
                try fixture.worker.process(.init(operation: "commit-candidate", reference: fixture.reference, selection: selection))
            }
        }
        #expect(try fixture.key(53).commits.isEmpty)
        #expect(try fixture.key(text: "a").commits.isEmpty)
        let nextCommit = try fixture.key(36)
        #expect(nextCommit.commits == ["あ"])
        #expect(nextCommit.candidateCompletions == nil)
    }

    private func selectWholeCandidate(_ fixture: inout DesktopReadingWorkerFixture) throws -> DesktopCandidateSelection {
        let prepared = try fixture.worker.process(.init(operation: "prepare-candidates", reference: fixture.reference,
            candidateWorkerGeneration: "converter"))
        let request = try #require(prepared.candidateRequest)
        let candidate = try DesktopCandidateItem(candidateID: "whole", text: "日本語", composingCount: .init(.surfaceCount(4)),
            presentation: .init(tokens: [], annotation: nil, extraValues: [:], score: nil, comparisonGroup: nil, commitScope: nil))
        let batch = DesktopCandidateBatch(authority: request.authority, workerGeneration: "converter", batchID: "reconversion",
                                         candidates: [candidate])
        _ = try fixture.adopt(batch)
        let selection = DesktopCandidateSelection(batch: fixture.retained(batch), candidateID: candidate.candidateID)
        let selected = try fixture.worker.process(.init(operation: "select", reference: fixture.reference, selection: selection))
        #expect(selected.snapshot?.preedit == "日本語")
        #expect(selected.snapshot?.commits.isEmpty == true)
        return selection
    }
}
