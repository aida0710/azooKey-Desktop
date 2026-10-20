import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
struct DesktopReadingProtocolTests {
    @Test func inputBoundsAreCheckedBeforeTheFirstCandidateRequestAndPreserveTheReading() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let before = try fixture.snapshot()
        #expect(throws: DesktopReadingProtocolFailure.invalidRequest) {
            try fixture.key(text: String(repeating: "a", count: CompositionSnapshotLimits.pieceUTF8ByteCount + 1))
        }
        let after = try fixture.snapshot()
        #expect(after.preedit == before.preedit)
        #expect(after.compositionRevision == before.compositionRevision)
        #expect(after.generation == before.generation)
        #expect(try fixture.key(36).commits == ["にほんご"])
    }

    @Test func invalidSurroundingsDoNotAcquireFocusAndMaximumInputIsBoundedToTheClientWindow() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let out = try fixture.worker.process(.init(operation: "focus-out", reference: fixture.reference, submit: false))
        fixture.reference = try #require(out.nextReference)
        #expect(throws: DesktopReadingProtocolFailure.requestLimit) {
            try fixture.worker.process(.init(operation: "focus-in", reference: fixture.reference, surroundings: .init(
                leftContext: String(repeating: "a", count: DesktopWorkerProtocolLimits.contextBytes + 1),
                rightContext: "", privateInput: false)))
        }
        let focused = try fixture.worker.process(.init(operation: "focus-in", reference: fixture.reference, surroundings: .init(
            leftContext: String(repeating: "l", count: DesktopWorkerProtocolLimits.contextBytes),
            rightContext: String(repeating: "r", count: DesktopWorkerProtocolLimits.contextBytes), privateInput: true)))
        fixture.reference = try #require(focused.reference)
        _ = try fixture.key(text: "a")
        let prepared = try fixture.worker.process(.init(operation: "prepare-candidates", reference: fixture.reference,
                                                       candidateWorkerGeneration: "converter"))
        #expect(prepared.candidateRequest?.leftContext == String(repeating: "l", count: 100))
        #expect(prepared.candidateRequest?.rightContext == String(repeating: "r", count: 100))
        #expect(prepared.candidateRequest?.privateInput == true)
    }

    @Test func contextCapacityRejectsNewContextsButReleasesOnlyTheClosedInactiveSlot() throws {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "a")
        var inactive: DesktopReadingContextReference?
        for index in 1..<DesktopWorkerProtocolLimits.contexts {
            inactive = try fixture.worker.process(.init(operation: "open",
                readingProcessGeneration: fixture.worker.readingProcessGeneration, context: "field-\(index)")).reference
        }
        #expect(throws: DesktopReadingProtocolFailure.requestLimit) {
            try fixture.worker.process(.init(operation: "open", readingProcessGeneration: fixture.worker.readingProcessGeneration,
                                             context: "overflow"))
        }
        #expect(throws: DesktopReadingProtocolFailure.contextActive) {
            try fixture.worker.process(.init(operation: "close", reference: fixture.reference))
        }
        _ = try fixture.worker.process(.init(operation: "close", reference: inactive))
        _ = try fixture.worker.process(.init(operation: "open", readingProcessGeneration: fixture.worker.readingProcessGeneration,
                                             context: "replacement"))
        #expect(try fixture.snapshot().preedit == "あ")
    }

    @Test func learningChangeBeforeCandidatesAdvancesFutureRequestsAcrossContexts() throws {
        var fixture = try DesktopReadingWorkerFixture()
        let other = try fixture.worker.process(.init(operation: "open",
            readingProcessGeneration: fixture.worker.readingProcessGeneration, context: "other"))
        _ = try fixture.worker.process(.init(operation: "learning-revision",
            readingProcessGeneration: fixture.worker.readingProcessGeneration, settingsRevision: 3))
        _ = try fixture.worker.process(.init(operation: "focus-out", reference: fixture.reference, submit: false))
        let focused = try fixture.worker.process(.init(operation: "focus-in", reference: other.reference,
            surroundings: .init(leftContext: "", rightContext: "", privateInput: false)))
        fixture.reference = try #require(focused.reference)
        _ = try fixture.key(text: "a")
        #expect(try fixture.batch().authority.settingsRevision == 3)
    }

    @Test func operationShapeRejectsNumericSelectionAndUnownedCompositionRevision() throws {
        let malformed = [
            #"{"operation":"select","reference":{"context":"field","readingProcessGeneration":"reader","focusEpoch":1},"selection":{"index":0}}"#,
            #"{"operation":"key","compositionRevision":5}"#,
            #"{"operation":"key","event":{"keyCode":0,"modifierFlags":0,"context":"other"}}"#,
            #"{"operation":"hello","settingsRevision":1}"#
        ]
        for json in malformed {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(DesktopReadingWorkerRequest.self, from: Data(json.utf8)) }
        }
    }
}
