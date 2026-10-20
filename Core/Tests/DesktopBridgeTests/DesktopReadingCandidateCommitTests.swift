import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingCandidateCommitTests {
    private func adopted(partial: Bool = false) throws -> (fixture: DesktopReadingWorkerFixture, batch: DesktopCandidateBatch) {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch(partial: partial)
        _ = try fixture.adopt(batch)
        return (fixture, batch)
    }

    private func commit(_ source: inout (fixture: DesktopReadingWorkerFixture, batch: DesktopCandidateBatch)) throws -> DesktopReadingWorkerResponse {
        try source.fixture.worker.process(.init(operation: "commit-candidate", reference: source.fixture.reference,
            selection: .init(batch: source.fixture.retained(source.batch), candidateID: "candidate")))
    }

    @Test(arguments: [false, true])
    func anIdentityCommitsOnceWithOrWithoutASeparateSelection(selectFirst: Bool) throws {
        var source = try adopted()
        if selectFirst {
            let selected = try source.fixture.select(source.batch)
            #expect(selected.commits.isEmpty)
            #expect(selected.candidateCompletions == nil)
            #expect(selected.preedit == "日本語")
        }
        let before = try source.fixture.snapshot()
        let response = try commit(&source)
        let snapshot = try #require(response.snapshot)
        #expect(response.kind == .input)
        #expect(response.reference == source.fixture.reference)
        #expect(response.candidateView == nil)
        #expect(snapshot.commits == ["日本語"])
        #expect(snapshot.reading.isEmpty)
        #expect(snapshot.preedit.isEmpty)
        #expect(snapshot.inputState == "none")
        #expect(snapshot.selection == nil)
        #expect(snapshot.generation == before.generation + 1)
        let previousRevision = try #require(before.compositionRevision)
        #expect(snapshot.compositionRevision == previousRevision + 1)
        #expect(snapshot.candidateCompletions?.count == 1)
        #expect(snapshot.candidateCompletions?.first?.candidateID == "candidate")
        #expect(snapshot.candidateCompletions?.first?.batchID == source.batch.batchID)
        #expect(snapshot.candidateCompletions?.first?.authority == source.batch.authority)
        let cleared = try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot())
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) { try commit(&source) }
        #expect(try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot()) == cleared)
        let appended = try source.fixture.key(text: "a")
        #expect(appended.preedit == "あ")
        #expect(appended.commits.isEmpty)
        #expect(appended.candidateCompletions == nil)
    }

    @Test(arguments: [false, true])
    func aPartialIdentityKeepsItsSuffixAndUpdatesTheNextRequestOnce(selectFirst: Bool) throws {
        var source = try adopted(partial: true)
        if selectFirst { _ = try source.fixture.select(source.batch) }
        let response = try commit(&source)
        let snapshot = try #require(response.snapshot)
        #expect(response.candidateView == nil)
        #expect(snapshot.commits == ["荷"])
        #expect(snapshot.preedit == "ほんご")
        #expect(snapshot.reading == "ほんご")
        #expect(snapshot.inputState == "composing")
        #expect(snapshot.selection == nil)
        #expect(snapshot.request == "candidates")
        #expect(snapshot.candidateCompletions?.count == 1)
        let remaining = try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot())
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) { try commit(&source) }
        #expect(try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot()) == remaining)
        let prepared = try source.fixture.worker.process(.init(operation: "prepare-candidates", reference: source.fixture.reference,
                                                               candidateWorkerGeneration: "converter"))
        #expect(prepared.candidateRequest?.leftContext == "荷")
        #expect(prepared.candidateRequest?.composition.convertTarget == "ほんご")
        #expect(prepared.candidateRequest?.authority.compositionRevision == snapshot.compositionRevision)
        let suffix = try source.fixture.keyResponse(36)
        #expect(suffix.snapshot?.commits == ["ほんご"])
        #expect(suffix.snapshot?.candidateCompletions == nil)
        #expect(suffix.candidateView == nil)
    }

    @Test(arguments: ["edit", "cancel", "reset", "worker-stopped"])
    func retiredCandidatesCannotCommitAndDoNotChangeTheCurrentInput(retirement: String) throws {
        var source = try adopted()
        _ = try source.fixture.select(source.batch)
        switch retirement {
        case "edit": _ = try source.fixture.key(text: "a")
        case "cancel": _ = try source.fixture.key(53)
        case "reset":
            _ = try source.fixture.worker.process(.init(operation: "reset", reference: source.fixture.reference, submit: false))
        default:
            _ = try source.fixture.worker.process(.init(operation: "candidate-worker-stopped", reference: source.fixture.reference,
                                                        candidateWorkerGeneration: "converter"))
        }
        let before = try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot())
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) { try commit(&source) }
        #expect(try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot()) == before)
        if retirement == "worker-stopped" {
            // A retired view cannot initiate a new commit; the already selected keyboard target remains valid.
            #expect(try source.fixture.key(36).commits == ["日本語"])
        }
    }

    @Test(arguments: [false, true])
    func theOldFocusCannotCommitIntoANewOrReopenedField(sameField: Bool) throws {
        var source = try adopted()
        let old = source.fixture.reference
        let blurred = try source.fixture.worker.process(.init(operation: "focus-out", reference: old, submit: false))
        let nextReference: DesktopReadingContextReference?
        if sameField {
            nextReference = blurred.nextReference
        } else {
            nextReference = try source.fixture.worker.process(.init(operation: "open",
                readingProcessGeneration: source.fixture.worker.readingProcessGeneration, context: "another-field")).reference
        }
        let focused = try source.fixture.worker.process(.init(operation: "focus-in", reference: nextReference,
            surroundings: .init(leftContext: "", rightContext: "", privateInput: false)))
        source.fixture.reference = try #require(focused.reference)
        _ = try source.fixture.key(text: "a")
        let before = try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot())
        let selection = DesktopCandidateSelection(batch: source.fixture.retained(source.batch), candidateID: "candidate")
        #expect(throws: DesktopReadingProtocolFailure.staleFocus) {
            try source.fixture.worker.process(.init(operation: "commit-candidate", reference: old, selection: selection))
        }
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) { try commit(&source) }
        #expect(try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot()) == before)
        #expect(try source.fixture.key(36).commits == ["あ"])
    }

    @Test func aNewBatchCannotBeCommittedWithAnOldReferenceEvenIfItsCandidateIDMatches() throws {
        var source = try adopted()
        let latest = try source.fixture.batch()
        _ = try source.fixture.adopt(latest)
        _ = try source.fixture.select(latest)
        let before = try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot())
        #expect(throws: DesktopReadingCandidates.Failure.unavailableCandidate) { try commit(&source) }
        #expect(try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot()) == before)
        source.batch = latest
        #expect(try commit(&source).snapshot?.candidateCompletions?.first?.batchID == latest.batchID)
    }

    @Test func identicalTextUsesTheRequestedIdentityAndItsOwnConsumption() throws {
        var source = try adopted()
        let full = try #require(source.batch.candidates.first)
        // The two synthetic list entries have the same surface but consume different portions of the formal reading.
        let partial = try DesktopCandidateItem(candidateID: "prefix", text: full.text,
                                               composingCount: .init(.inputCount(2)), presentation: full.presentation)
        source.batch = try source.fixture.batch()
        source.batch = .init(authority: source.batch.authority, workerGeneration: source.batch.workerGeneration,
                             batchID: source.batch.batchID, candidates: [full, partial], mainCandidateID: full.candidateID)
        _ = try source.fixture.adopt(source.batch)
        _ = try source.fixture.select(source.batch)
        let response = try source.fixture.worker.process(.init(operation: "commit-candidate", reference: source.fixture.reference,
            selection: .init(batch: source.fixture.retained(source.batch), candidateID: "prefix")))
        #expect(response.snapshot?.commits == ["日本語"])
        #expect(response.snapshot?.preedit == "ほんご")
        #expect(response.snapshot?.candidateCompletions?.first?.candidateID == "prefix")
        #expect(response.candidateView == nil)
    }

    @Test func aPrivateCommitKeepsTheCalculationAndCompletionRevisionsDistinct() throws {
        var fixture = try DesktopReadingWorkerFixture(privateInput: true)
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch()
        _ = try fixture.adopt(batch)
        _ = try fixture.worker.process(.init(operation: "learning-revision", readingProcessGeneration: fixture.worker.readingProcessGeneration,
                                             settingsRevision: 1))
        var source = (fixture: fixture, batch: batch)
        let response = try commit(&source)
        let completion = try #require(response.snapshot?.candidateCompletions?.first)
        #expect(response.settingsRevision == 1)
        #expect(completion.authority.settingsRevision == 0)
        #expect(completion.settingsRevision == 1)
        #expect(completion.privateInput)
        #expect(try source.fixture.snapshot().candidateCompletions == nil)
    }
}
