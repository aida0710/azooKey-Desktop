import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingReconversionResolutionTests {
    private typealias Support = DesktopReadingReconversionTestSupport

    @Test func anUnknownDictionaryReadingUsesTheExistingLocalPromptBeforePreparingAnyDeletion() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let original = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        let query = try #require(Support.prepare(&fixture, selected: "相田", reading: nil).reconversionReadingRequest)
        let unknown = try fixture.worker.process(.init(operation: "resolve-reconversion", reference: fixture.reference,
            reconversionContext: Support.document(selected: "相田"), reconversionReadingResult: .init(request: query, reading: nil)))
        #expect(unknown.reconversionError == "reading_required")
        #expect(unknown.reconversionReading?.isEmpty == true)
        #expect(unknown.reconversion == nil && unknown.snapshot == nil)
        for character in "aida" {
            let edited = try fixture.worker.process(.init(operation: "reconversion-reading", reference: fixture.reference,
                event: Support.key(text: String(character)), reconversionContext: Support.document(selected: "相田")))
            #expect(edited.snapshot == nil && edited.reconversion == nil)
            #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == original)
        }
        let submitted = try fixture.worker.process(.init(operation: "reconversion-reading", reference: fixture.reference,
            event: Support.key(36), reconversionContext: Support.document(selected: "相田")))
        #expect(submitted.reconversion?.reading == "あいだ")
        #expect(submitted.reconversion?.text == "相田")
        #expect(submitted.reconversionReading == nil)
        #expect(submitted.snapshot == nil)
    }

    @Test(arguments: ["cancel", "reset", "key", "worker-stopped", "new-request", "settings"])
    func retiredDictionaryResultsNeverPrepareADeletion(retirement: String) throws {
        var fixture = try DesktopReadingWorkerFixture()
        let query = try #require(Support.prepare(&fixture, reading: nil).reconversionReadingRequest)
        switch retirement {
        case "cancel": _ = try fixture.worker.process(.init(operation: "cancel-reconversion", reference: fixture.reference))
        case "reset": _ = try fixture.worker.process(.init(operation: "reset", reference: fixture.reference, submit: false))
        case "key": _ = try fixture.key(text: "a")
        case "worker-stopped":
            _ = try fixture.worker.process(.init(operation: "candidate-worker-stopped", reference: fixture.reference,
                                                 candidateWorkerGeneration: "converter"))
        case "settings":
            _ = try fixture.worker.process(.init(operation: "learning-revision",
                readingProcessGeneration: fixture.worker.readingProcessGeneration, settingsRevision: 1))
        default: _ = try Support.prepare(&fixture, reading: nil)
        }
        let before = try DesktopReadingTestSupport.encodedJSON(fixture.snapshot())
        let rejected = try fixture.worker.process(.init(operation: "resolve-reconversion", reference: fixture.reference,
            reconversionContext: Support.document(selected: "日本語"), reconversionReadingResult: .init(request: query, reading: "にほんご")))
        #expect(rejected.reconversion == nil)
        #expect(rejected.reconversionError != nil)
        #expect(rejected.snapshot == nil)
        #expect(try DesktopReadingTestSupport.encodedJSON(fixture.snapshot()) == before)
    }

    @Test(arguments: ["worker", "request", "context", "reader", "focus", "composition", "settings", "text-bytes"])
    func resolutionMustMatchEveryOriginalAuthorityFieldAndExactText(change: String) throws {
        var fixture = try DesktopReadingWorkerFixture()
        let selected = "\u{212B}"
        let query = try #require(Support.prepare(&fixture, selected: selected, reading: nil).reconversionReadingRequest)
        let original = query.authority
        let modified = DesktopReconversionReadingRequest(authority: .init(
            context: change == "context" ? "other-field" : original.context,
            readingProcessGeneration: change == "reader" ? "other-reader" : original.readingProcessGeneration,
            focusEpoch: original.focusEpoch + (change == "focus" ? 1 : 0),
            compositionRevision: original.compositionRevision + (change == "composition" ? 1 : 0),
            settingsRevision: original.settingsRevision + (change == "settings" ? 1 : 0),
            requestID: change == "request" ? "other-request" : original.requestID),
            workerGeneration: change == "worker" ? "other-worker" : query.workerGeneration,
            text: change == "text-bytes" ? "Å" : selected, privateInput: false)
        let reply = try fixture.worker.process(.init(operation: "resolve-reconversion", reference: fixture.reference,
            reconversionContext: Support.document(selected: selected), reconversionReadingResult: .init(request: modified, reading: "あ")))
        #expect(reply.reconversionError == "stale_request")
        #expect(reply.reconversion == nil)
        #expect(try fixture.snapshot().preedit.isEmpty)
        let valid = try fixture.worker.process(.init(operation: "resolve-reconversion", reference: fixture.reference,
            reconversionContext: Support.document(selected: selected), reconversionReadingResult: .init(request: query, reading: "あ")))
        #expect(valid.reconversion?.text.utf8.elementsEqual(selected.utf8) == true)
    }

    @Test func aFocusReturnWithTheSameTextDoesNotAuthorizeAnOldPlan() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let token = try #require(Support.prepare(&fixture).reconversion?.token)
        let old = fixture.reference
        let blur = try fixture.worker.process(.init(operation: "focus-out", reference: old, submit: false))
        let focus = try fixture.worker.process(.init(operation: "focus-in", reference: blur.nextReference,
            surroundings: .init(leftContext: "前", rightContext: "後", privateInput: false)))
        fixture.reference = try #require(focus.reference)
        #expect(throws: DesktopReadingProtocolFailure.staleFocus) {
            try fixture.worker.process(.init(operation: "confirm-reconversion", reference: old,
                reconversionContext: Support.document(), reconversionToken: token))
        }
        let rejected = try Support.confirm(&fixture, token: token)
        #expect(rejected.reconversionError == "stale_request")
        #expect(rejected.snapshot?.preedit.isEmpty == true)
        #expect(rejected.snapshot?.commits.isEmpty == true)
    }

    @Test func unicodePositionsUseScalarsForDeletionAndRejectCanonicallyEquivalentDocumentBytes() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let selected = "👩‍💻e\u{301}"
        let context = Support.document(before: "\u{212B}", selected: selected)
        let prepared = try fixture.worker.process(.init(operation: "reconvert", reference: fixture.reference,
            reconversionContext: context, reading: "えもじ"))
        let replacement = try #require(prepared.reconversion)
        #expect(replacement.count == 5 && replacement.offset == -5)
        let differentBytes = try Support.confirm(&fixture, token: replacement.token, context: Support.document(before: "Å"))
        #expect(differentBytes.reconversionError == "changed_context")
        let restored = try Support.confirm(&fixture, token: replacement.token, context: Support.document(before: "\u{212B}"))
        #expect(restored.snapshot?.preedit == "えもじ")
        #expect(try fixture.key(53).commits.isEmpty)
        let cancelled = try fixture.key(53)
        #expect(cancelled.commits.first?.utf8.elementsEqual(selected.utf8) == true)
    }

    @Test func stagingAWorkerCopyDoesNotConsumeTheOriginalDeletionToken() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let token = try #require(Support.prepare(&fixture).reconversion?.token)
        var staged = fixture
        #expect(try Support.confirm(&staged, token: token).snapshot?.reading == "にほんご")
        #expect(try Support.confirm(&fixture, token: token).snapshot?.reading == "にほんご")
    }
}
