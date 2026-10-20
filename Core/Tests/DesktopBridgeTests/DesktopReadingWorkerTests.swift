import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingWorkerTests {
    @Test func focusOutCommitsTheOriginalFieldOnceAndRejectsItsOldReference() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch()
        _ = try fixture.adopt(batch)
        _ = try fixture.select(batch)
        let original = fixture.reference
        let blurred = try fixture.worker.process(.init(operation: "focus-out", reference: original, submit: true))
        #expect(blurred.snapshot?.commits == ["日本語"])
        #expect(blurred.reference == original)
        #expect(blurred.snapshot?.candidateCompletions?.first?.authority.focusEpoch == original.focusEpoch)
        let inactive = try #require(blurred.nextReference)
        #expect(inactive.focusEpoch > original.focusEpoch)
        #expect(inactive.context == original.context)
        #expect(inactive.readingProcessGeneration == original.readingProcessGeneration)
        #expect(throws: DesktopReadingProtocolFailure.staleFocus) {
            try fixture.worker.process(.init(operation: "reset", reference: original, submit: true))
        }
        let opened = try fixture.worker.process(.init(operation: "open", readingProcessGeneration: fixture.worker.readingProcessGeneration,
                                                     context: "second"))
        let focused = try fixture.worker.process(.init(operation: "focus-in", reference: opened.reference,
                                                       surroundings: .init(leftContext: "", rightContext: "", privateInput: false)))
        fixture.reference = try #require(focused.reference)
        #expect(try fixture.key(text: "a").preedit == "あ")
        #expect(throws: DesktopReadingProtocolFailure.contextNotFocused) {
            try fixture.worker.process(.init(operation: "key", reference: inactive,
                                             event: .init(modifierFlags: [], characters: "x", charactersIgnoringModifiers: "x", keyCode: 0)))
        }
        #expect(try fixture.snapshot().reading == "あ")
    }

    @Test func aClosedContextCannotBeAddressedByItsPreviousLifetime() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let blurred = try fixture.worker.process(.init(operation: "focus-out", reference: fixture.reference, submit: false))
        _ = try fixture.worker.process(.init(operation: "close", reference: blurred.nextReference))
        let reopened = try fixture.worker.process(.init(operation: "open", readingProcessGeneration: fixture.worker.readingProcessGeneration,
                                                       context: "field"))
        #expect(reopened.reference?.focusEpoch != blurred.nextReference?.focusEpoch)
        #expect(throws: DesktopReadingProtocolFailure.staleFocus) {
            try fixture.worker.process(.init(operation: "close", reference: blurred.nextReference))
        }
    }

    @Test func aStaleProcessOrDifferentFieldCannotEditTheCurrentReading() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let old = DesktopReadingContextReference(context: "field", readingProcessGeneration: "old-process", focusEpoch: fixture.reference.focusEpoch)
        #expect(throws: DesktopReadingProtocolFailure.wrongProcess) {
            try fixture.worker.process(.init(operation: "reset", reference: old, submit: false))
        }
        let another = DesktopReadingContextReference(context: "other", readingProcessGeneration: fixture.worker.readingProcessGeneration,
                                                     focusEpoch: fixture.reference.focusEpoch)
        #expect(throws: DesktopReadingProtocolFailure.unknownContext) {
            try fixture.worker.process(.init(operation: "reset", reference: another, submit: false))
        }
        #expect(try fixture.snapshot().preedit == "にほんご")
    }

    @Test func unsupportedKeysKeepTheInputAndErrorsCannotReplayIt() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let before = try fixture.snapshot()
        #expect(throws: DesktopReadingSession.Failure.unsupportedAction) { try fixture.key(48, text: "\t") }
        let rejected = fixture.worker.rejected(DesktopReadingSession.Failure.unsupportedAction)
        #expect(rejected.snapshot == nil)
        #expect(rejected.kind == .error)
        #expect(try fixture.snapshot().generation == before.generation)
        #expect(try fixture.key(text: "a").reading == "にほんごあ")
    }

    @Test func candidateControlRepliesContainNoInputAndRequireTheExactRetainReference() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch()
        let wrong = DesktopCandidateBatchReference(authority: batch.authority, workerGeneration: "converter", batchID: "other")
        #expect(throws: DesktopReadingProtocolFailure.retainRequired) {
            try fixture.worker.process(.init(operation: "adopt-candidates", reference: fixture.reference,
                                             batch: batch, retainedReference: wrong))
        }
        let accepted = try fixture.adopt(batch)
        #expect(accepted.snapshot == nil)
        #expect(accepted.candidateReference == fixture.retained(batch))
        #expect(try fixture.snapshot().preedit == "にほんご")
        #expect(try fixture.select(batch).preedit == "日本語")
    }

    @Test func anOldListCannotSelectAnIdenticalCandidateIDInANewerList() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let old = try fixture.batch()
        _ = try fixture.adopt(old)
        let latest = try fixture.batch()
        _ = try fixture.adopt(latest)
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) { try fixture.select(old) }
        #expect(try fixture.select(latest).preedit == "日本語")
    }

    @Test func aStoppedWorkerKeepsTheSelectedPartialCommitAndRejectsOldStopNotifications() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch(partial: true)
        _ = try fixture.adopt(batch)
        _ = try fixture.select(batch)
        #expect(throws: DesktopReadingProtocolFailure.wrongCandidateWorker) {
            try fixture.worker.process(.init(operation: "candidate-worker-stopped", reference: fixture.reference,
                                             candidateWorkerGeneration: "previous-converter"))
        }
        let stopped = try fixture.worker.process(.init(operation: "candidate-worker-stopped", reference: fixture.reference,
                                                      candidateWorkerGeneration: "converter"))
        #expect(stopped.snapshot == nil)
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) { try fixture.select(batch) }
        let committed = try fixture.key(36)
        #expect(committed.commits == ["荷"])
        #expect(committed.reading == "ほんご")
        #expect(committed.candidateCompletions?.first?.candidateID == "candidate")
        let prepared = try fixture.worker.process(.init(operation: "prepare-candidates", reference: fixture.reference,
                                                       candidateWorkerGeneration: "next-converter"))
        #expect(prepared.candidateRequest?.leftContext == "荷")
        #expect(try fixture.key(36).commits == ["ほんご"])
    }

    @Test func learningRevisionKeepsSelectedIdentityAndAdvancesTheCompletionOnly() throws {
        var fixture = try DesktopReadingWorkerFixture(privateInput: true)
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch()
        _ = try fixture.adopt(batch)
        _ = try fixture.select(batch)
        let changed = try fixture.worker.process(.init(operation: "learning-revision",
                                                       readingProcessGeneration: fixture.worker.readingProcessGeneration, settingsRevision: 1))
        #expect(changed.snapshot == nil)
        #expect(changed.settingsRevision == 1)
        let completed = try #require(fixture.key(36).candidateCompletions?.first)
        #expect(completed.authority.settingsRevision == 0)
        #expect(completed.settingsRevision == 1)
        #expect(completed.privateInput)
    }
}
