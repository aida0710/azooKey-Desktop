import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingReconversionTests {
    private typealias Support = DesktopReadingReconversionTestSupport

    @Test func prepareLeavesFormalInputUntouchedAndOnlyAnActualDeletionAcknowledgementRestoresTheReading() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let before = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        let prepared = try Support.prepare(&fixture)
        let replacement = try #require(prepared.reconversion)
        #expect(prepared.kind == .acknowledgement)
        #expect(prepared.snapshot == nil)
        #expect(replacement.text == "日本語")
        #expect(replacement.reading == "にほんご")
        #expect(replacement.offset == -3)
        #expect(replacement.count == 3)
        #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before)
        let early = try Support.confirm(&fixture, token: replacement.token, context: Support.document(selected: "日本語"))
        #expect(early.reconversionError == "changed_context")
        #expect(early.snapshot?.preedit.isEmpty == true && early.snapshot?.commits.isEmpty == true)
        let restored = try #require(Support.confirm(&fixture, token: replacement.token).snapshot)
        #expect(restored.reading == "にほんご")
        #expect(restored.preedit == "にほんご")
        #expect(restored.request == "candidates")
        #expect(restored.selection == nil)
        #expect(restored.commits.isEmpty && restored.candidateCompletions == nil)
        let repeated = try Support.confirm(&fixture, token: replacement.token)
        #expect(repeated.reconversionError == "composition_active")
        #expect(repeated.snapshot?.commits.isEmpty == true)
        #expect(repeated.snapshot?.preedit == "にほんご")
    }

    @Test func undoRestoresRawRomanInputAndThePreviousCandidateOnlyThroughANewIdentity() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let oldBatch = try Support.originalCommit(&fixture)
        let plan = try fixture.worker.process(.init(operation: "undo-commit", reference: fixture.reference,
            reconversionContext: Support.document(before: "前日本語")))
        let token = try #require(plan.reconversion?.token)
        let restored = try #require(Support.confirm(&fixture, token: token).snapshot)
        #expect(restored.canUndoCommit == false)
        let before = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) {
            try fixture.worker.process(.init(operation: "commit-candidate", reference: fixture.reference,
                selection: .init(batch: fixture.retained(oldBatch), candidateID: "candidate")))
        }
        #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before)
        let newBatch = try fixture.batch()
        let original = try #require(newBatch.candidates.first)
        let other = try DesktopCandidateItem(candidateID: "different", text: "二本語",
                                             composingCount: original.composingCount, presentation: original.presentation)
        let reordered = DesktopCandidateBatch(authority: newBatch.authority, workerGeneration: newBatch.workerGeneration,
            batchID: newBatch.batchID, candidates: [other, original])
        _ = try fixture.adopt(reordered)
        #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before)
        #expect(try fixture.key(49).preedit == "日本語")
        let roman = try fixture.key(109)
        #expect(roman.commits == ["nihongo"])
        #expect(roman.candidateCompletions == nil)
        #expect(try fixture.key(53).commits.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationRestoresTheOriginalOnceWithoutLearning(reset: Bool) throws {
        var fixture = try DesktopReadingWorkerFixture()
        let token = try #require(Support.prepare(&fixture).reconversion?.token)
        _ = try Support.confirm(&fixture, token: token)
        let cancelled: DesktopSnapshot
        if reset {
            cancelled = try #require(fixture.worker.process(.init(operation: "reset", reference: fixture.reference, submit: false)).snapshot)
        } else {
            #expect(try fixture.key(53).commits.isEmpty)
            cancelled = try fixture.key(53)
        }
        #expect(cancelled.commits == ["日本語"])
        #expect(cancelled.preedit.isEmpty)
        #expect(cancelled.candidateCompletions == nil)
        #expect(try fixture.key(53).commits.isEmpty)
    }

    @Test(arguments: [UInt16(0), 36, 124, 97, 98, 100, 101, 109])
    func aPrefixCannotBeCommittedDuringReconversionAndCancelStillRestoresTheWholeOriginal(keyCode: UInt16) throws {
        var fixture = try DesktopReadingWorkerFixture()
        let token = try #require(Support.prepare(&fixture).reconversion?.token)
        _ = try Support.confirm(&fixture, token: token)
        let prepared = try fixture.worker.process(.init(operation: "prepare-candidates", reference: fixture.reference,
            candidateWorkerGeneration: "converter"))
        let request = try #require(prepared.candidateRequest)
        let candidate = try DesktopCandidateItem(candidateID: "prefix", text: "荷", composingCount: .init(.surfaceCount(1)),
            presentation: .init(tokens: [], annotation: nil, extraValues: [:], score: nil, comparisonGroup: nil, commitScope: nil))
        let batch = DesktopCandidateBatch(authority: request.authority, workerGeneration: "converter", batchID: "partial", candidates: [candidate])
        _ = try fixture.adopt(batch)
        let selection = DesktopCandidateSelection(batch: fixture.retained(batch), candidateID: "prefix")
        if keyCode != 0 { _ = try fixture.worker.process(.init(operation: "select", reference: fixture.reference, selection: selection)) }
        let before = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        let failed = keyCode == 0
            ? try fixture.worker.process(.init(operation: "commit-candidate", reference: fixture.reference, selection: selection))
            : try fixture.worker.process(.init(operation: "key", reference: fixture.reference, event: Support.key(keyCode)))
        #expect(failed.snapshot?.reconversionError == "whole_selection_required")
        #expect(failed.snapshot?.commits.isEmpty == true)
        #expect(failed.snapshot?.candidateCompletions == nil)
        #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before)
        let cancelled = try fixture.worker.process(.init(operation: "reset", reference: fixture.reference, submit: false))
        #expect(cancelled.snapshot?.commits == ["日本語"])
    }

    @Test(arguments: ["missing", "private", "partial", "changed", "reset"])
    func undoRequiresAnUnchangedRecentWholeCommit(condition: String) throws {
        var fixture = try DesktopReadingWorkerFixture(privateInput: condition == "private")
        if condition != "missing" {
            if condition == "partial" {
                _ = try fixture.key(text: "nihongo")
                let batch = try fixture.batch(partial: true)
                _ = try fixture.adopt(batch)
                _ = try fixture.worker.process(.init(operation: "commit-candidate", reference: fixture.reference,
                    selection: .init(batch: fixture.retained(batch), candidateID: "candidate"), reconversionContext: Support.document()))
            } else if condition == "private" {
                _ = try fixture.key(text: "a")
                _ = try fixture.worker.process(.init(operation: "key", reference: fixture.reference, event: Support.key(36),
                    reconversionContext: Support.document()))
            } else {
                _ = try Support.originalCommit(&fixture)
            }
        }
        if condition == "reset" { _ = try fixture.worker.process(.init(operation: "reset", reference: fixture.reference, submit: false)) }
        let before = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        let reply = try fixture.worker.process(.init(operation: "undo-commit", reference: fixture.reference,
            reconversionContext: Support.document(before: condition == "changed" ? "別日本語" : "前日本語")))
        #expect(reply.reconversion == nil)
        #expect(reply.snapshot == nil)
        #expect(reply.reconversionError != nil)
        // A changed document also retires the no-longer-valid undo entry.
        if condition != "changed" { #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before) }
    }
}
