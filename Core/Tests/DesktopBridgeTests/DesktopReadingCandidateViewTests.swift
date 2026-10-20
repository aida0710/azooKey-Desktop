import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopReadingCandidateViewTests {
    private func prepared(partial: Bool = false) throws -> (fixture: DesktopReadingWorkerFixture, batch: DesktopCandidateBatch) {
        var fixture = try DesktopReadingWorkerFixture()
        _ = try fixture.key(text: "nihongo")
        let batch = try fixture.batch(partial: partial)
        return (fixture, batch)
    }

    @Test func adoptingAMainCandidateAddsOnlyAViewAndKeepsTheFormalSnapshotIdentical() throws {
        var source = try prepared()
        let batch = DesktopCandidateBatch(authority: source.batch.authority, workerGeneration: source.batch.workerGeneration,
            batchID: source.batch.batchID, candidates: source.batch.candidates, mainCandidateID: "candidate")
        let before = try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot())
        let adopted = try source.fixture.adopt(batch)
        let view = try #require(adopted.candidateView)
        #expect(adopted.kind == .acknowledgement)
        #expect(adopted.snapshot == nil)
        #expect(view.candidateReference == adopted.candidateReference)
        #expect(view.candidates.map(\.candidateID) == ["candidate"])
        #expect(view.selection == nil)
        #expect(view.focusedNode == nil)
        #expect(!view.showCandidateIndex)
        #expect(try DesktopReadingTestSupport.encodedJSON(source.fixture.snapshot()) == before)
        let committed = try source.fixture.keyResponse(36)
        #expect(committed.snapshot?.commits == ["にほんご"])
        #expect(committed.snapshot?.candidateCompletions == nil)
        #expect(committed.candidateView == nil)
    }

    @Test func anEmptyAdoptedBatchStillHasAnExplicitEmptyView() throws {
        var source = try prepared()
        let empty = DesktopCandidateBatch(authority: source.batch.authority, workerGeneration: source.batch.workerGeneration,
                                           batchID: source.batch.batchID, candidates: [])
        let adopted = try source.fixture.adopt(empty)
        let view = try #require(adopted.candidateView)
        #expect(view.candidateReference == adopted.candidateReference)
        #expect(view.candidates.isEmpty)
        #expect(view.nodes.isEmpty)
        #expect(view.candidatePage.totalCount == 0)
        #expect(view.selection == nil)
        #expect(adopted.snapshot == nil)
    }

    @Test(arguments: [false, true])
    func displayedScopesComeFromTheFormalConsumptionEvenWhenPresentationLies(partial: Bool) throws {
        var source = try prepared(partial: partial)
        let original = try #require(source.batch.candidates.first)
        let misleading = DesktopCandidateItem(candidateID: original.candidateID, text: original.text,
            composingCount: original.composingCount, presentation: .init(tokens: [], annotation: nil, extraValues: [:],
                score: nil, comparisonGroup: nil, commitScope: .init(consumedReading: "偽の読み", remainingReading: "偽の残り")))
        let batch = DesktopCandidateBatch(authority: source.batch.authority, workerGeneration: source.batch.workerGeneration,
                                           batchID: source.batch.batchID, candidates: [misleading])
        let view = try #require(source.fixture.adopt(batch).candidateView)
        let scope = CandidateCommitScope(consumedReading: partial ? "に" : "にほんご", remainingReading: partial ? "ほんご" : "")
        #expect(view.candidates.first?.commitScope == scope)
        #expect(view.nodes.first?.preview?.scope == scope)
        #expect(view.candidatePage.items.first?.reading == scope.consumedReading)
        _ = try source.fixture.select(batch)
        let committed = try source.fixture.keyResponse(36)
        #expect(committed.snapshot?.commits == [original.text])
        #expect(committed.snapshot?.preedit == scope.remainingReading)
        #expect(committed.snapshot?.candidateCompletions?.first?.candidateID == original.candidateID)
        #expect(committed.candidateView == nil)
    }

    @Test func explicitSelectionSharesTheOriginalInputReplyAndCommitsOnce() throws {
        var source = try prepared()
        _ = try source.fixture.adopt(source.batch)
        let selected = try source.fixture.worker.process(.init(operation: "select", reference: source.fixture.reference,
            selection: .init(batch: source.fixture.retained(source.batch), candidateID: "candidate")))
        let view = try #require(selected.candidateView)
        #expect(selected.kind == .input)
        #expect(selected.snapshot?.preedit == "日本語")
        #expect(selected.snapshot?.selection == view.selection)
        #expect(view.showCandidateIndex)
        #expect(view.candidates[try #require(view.selection)].candidateID == "candidate")
        let unchanged = try source.fixture.keyResponse(125)
        #expect(unchanged.candidateView?.selection == 0)
        #expect(unchanged.snapshot?.commits.isEmpty == true)
        let committed = try source.fixture.keyResponse(36)
        #expect(committed.snapshot?.commits == ["日本語"])
        #expect(committed.snapshot?.candidateCompletions?.count == 1)
        #expect(committed.candidateView == nil)
        #expect(try source.fixture.keyResponse(36).snapshot?.commits.isEmpty == true)
    }

    @Test func identicalTextKeepsItsOwnFormalScopeAndOpaqueSelectionIdentity() throws {
        var source = try prepared()
        let whole = try #require(source.batch.candidates.first)
        let prefix = DesktopCandidateItem(candidateID: "prefix", text: whole.text,
            composingCount: try .init(.inputCount(2)), presentation: whole.presentation)
        let batch = DesktopCandidateBatch(authority: source.batch.authority, workerGeneration: source.batch.workerGeneration,
            batchID: source.batch.batchID, candidates: [whole, prefix], mainCandidateID: whole.candidateID)
        let adopted = try #require(source.fixture.adopt(batch).candidateView)
        #expect(adopted.candidates.map(\.candidateID) == [whole.candidateID, "prefix"])
        #expect(adopted.candidates.map { $0.commitScope?.consumedReading } == ["にほんご", "に"])
        #expect(adopted.candidatePage.items.map(\.reading) == ["にほんご", "に"])
        let selected = try source.fixture.worker.process(.init(operation: "select", reference: source.fixture.reference,
            selection: .init(batch: source.fixture.retained(batch), candidateID: "prefix")))
        let view = try #require(selected.candidateView)
        #expect(view.selection == 1)
        #expect(view.candidatePage.position == 2)
        #expect(view.nodes.first { $0.id == view.focusedNode }?.preview?.scope?.remainingReading == "ほんご")
        let committed = try source.fixture.keyResponse(36)
        #expect(committed.snapshot?.commits == [whole.text])
        #expect(committed.snapshot?.preedit == "ほんご")
        #expect(committed.snapshot?.candidateCompletions?.first?.candidateID == "prefix")
    }

    @Test(arguments: ["edit", "reset", "focus-out", "stopped"])
    func retiredCandidatesNeverRemainInTheResponse(operation: String) throws {
        var source = try prepared()
        _ = try source.fixture.adopt(source.batch)
        let retired: DesktopReadingWorkerResponse
        switch operation {
        case "edit": retired = try source.fixture.keyResponse(text: "a")
        case "stopped":
            retired = try source.fixture.worker.process(.init(operation: "candidate-worker-stopped",
                reference: source.fixture.reference, candidateWorkerGeneration: "converter"))
        default:
            retired = try source.fixture.worker.process(.init(operation: operation,
                reference: source.fixture.reference, submit: false))
        }
        #expect(retired.candidateView == nil)
        #expect(throws: (any Error).self) { try source.fixture.select(source.batch) }
        if let nextReference = retired.nextReference { source.fixture.reference = nextReference }
        #expect(try source.fixture.snapshot().commits.isEmpty)
    }

    @Test func aStoppedWorkerRemovesItsViewButKeepsTheAlreadySelectedCommitTarget() throws {
        var source = try prepared(partial: true)
        _ = try source.fixture.adopt(source.batch)
        _ = try source.fixture.select(source.batch)
        let stopped = try source.fixture.worker.process(.init(operation: "candidate-worker-stopped",
            reference: source.fixture.reference, candidateWorkerGeneration: "converter"))
        #expect(stopped.candidateView == nil)
        let committed = try source.fixture.keyResponse(36)
        #expect(committed.snapshot?.commits == ["荷"])
        #expect(committed.snapshot?.preedit == "ほんご")
        #expect(committed.candidateView == nil)
    }

    @Test(arguments: [false, true])
    func viewScoresUseTheAppliedWorkerSettingsWithoutChangingStoredPreferences(showScores: Bool) throws {
        var source = try prepared()
        let blurred = try source.fixture.worker.process(.init(operation: "focus-out", reference: source.fixture.reference, submit: false))
        var settings = DesktopWorkerSettingsFixture.settings()
        settings.showRelativeScores = showScores
        let preferences = Config.userDefaults.dictionaryRepresentation() as NSDictionary
        try DesktopWorkerSettingsFixture.configure(&source.fixture.worker, settings: settings)
        source.fixture.reference = try #require(source.fixture.worker.process(.init(operation: "focus-in", reference: blurred.nextReference,
            surroundings: .init(leftContext: "", rightContext: "", privateInput: false))).reference)
        _ = try source.fixture.key(text: "nihongo")
        let batch = try source.fixture.batch()
        let view = try #require(source.fixture.adopt(batch).candidateView)
        #expect(view.showRelativeScores == showScores)
        #expect(view.nodes.allSatisfy { ($0.scorePresentation != nil) == showScores })
        #expect(Config.userDefaults.dictionaryRepresentation() as NSDictionary == preferences)
    }

    @Test func anOversizedViewCannotPartiallyAdoptOrConsumeThePendingRequest() throws {
        var source = try prepared()
        let original = try #require(source.batch.candidates.first)
        // The batch fits once, but the projected tree/page would repeat this text beyond the envelope limit.
        let large = DesktopCandidateItem(candidateID: original.candidateID,
            text: String(repeating: "x", count: DesktopWorkerProtocolLimits.jsonBytes / 3),
            composingCount: original.composingCount, presentation: original.presentation)
        let batch = DesktopCandidateBatch(authority: source.batch.authority, workerGeneration: source.batch.workerGeneration,
                                           batchID: source.batch.batchID, candidates: [large])
        #expect(throws: DesktopReadingProtocolFailure.requestLimit) { try source.fixture.adopt(batch) }
        #expect(try source.fixture.snapshot().preedit == "にほんご")
        #expect(try source.fixture.snapshot().selection == nil)
        #expect(try source.fixture.adopt(source.batch).candidateView?.candidates.first?.text == "日本語")
    }

    @Test func readingTheViewNeverSelectsAndPreviewKeepsCandidateNumbersHidden() throws {
        let support = DesktopReadingTestSupport()
        var session = DesktopReadingSession()
        try support.type("nihongo", into: &session)
        _ = try session.key(support.key(49))
        let request = try support.request(from: &session)
        _ = try session.adoptCandidates(support.batch(request))
        let before = try DesktopReadingTestSupport.encodedJSON(session.snapshot())
        for _ in 0..<2 {
            let view = try #require(try session.candidateView())
            #expect(view.selection == nil)
            #expect(!view.showCandidateIndex)
        }
        #expect(try DesktopReadingTestSupport.encodedJSON(session.snapshot()) == before)
        let preview = try session.key(support.key(49))
        #expect(preview.inputState == "previewing")
        #expect(try session.candidateView()?.selection == preview.selection)
        #expect(try session.candidateView()?.showCandidateIndex == false)
        let selecting = try session.key(support.key(125))
        #expect(selecting.inputState == "selecting")
        #expect(try session.candidateView()?.showCandidateIndex == true)
    }
}
