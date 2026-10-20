import Core
@testable import DesktopBridge
import Foundation
import KanaKanjiConverterModule
import Testing

@MainActor
@Suite struct DesktopCandidateMainIdentityTests {
    private func stored(_ count: ComposingCount) throws -> DesktopCandidateConversion.StoredItem {
        let candidate = Candidate(text: "同じ表記", value: -1, composingCount: count, lastMid: 0, data: [])
        return try .init(presentation: .init(candidate: candidate),
                         composition: DesktopCandidateTestSupport.composition("nihongo"))
    }

    @Test func identicalTextWithDifferentConsumptionCannotReplaceAnOmittedMainResult() throws {
        let prefix = try stored(.inputCount(2))
        let whole = try stored(.inputCount(7))
        #expect(prefix.item.text == whole.item.text)
        #expect(DesktopCandidateConversion.mainCandidateID(whole.candidate, in: [prefix]) == nil)
        #expect(DesktopCandidateConversion.mainCandidateID(whole.candidate, in: [prefix, whole]) == whole.item.candidateID)
        #expect(DesktopCandidateConversion.mainCandidateID(prefix.candidate, in: [prefix, whole]) == prefix.item.candidateID)
        #expect(DesktopCandidateConversion.mainCandidateID(nil, in: [prefix, whole]) == nil)
    }

    @Test func mainIdentityMatchesTheOriginalAnalysisAndNotJustTextAndCount() throws {
        let whole = try stored(.inputCount(7))
        var different = whole.candidate
        different.lastMid += 1
        #expect(DesktopCandidateConversion.mainCandidateID(different, in: [whole]) == nil)
        #expect(DesktopCandidateConversion.mainCandidateID(whole.candidate, in: [whole]) == whole.item.candidateID)
    }

    @Test(arguments: [false, true])
    func actualMainResultKeepsItsIdentityAndItsRealWholeOrPartialConsumption(partial: Bool) throws {
        try DesktopCandidateTestSupport.withWorker { worker, directory in
            let request = try DesktopCandidateTestSupport.request(
                partial ? "kyougo" : "nihongowobenkyou", segmentEnd: partial ? 3 : nil)
            let batch = try DesktopCandidateTestSupport.batch(worker, request: request)
            let composition = try request.composition.restore()
            let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
                                          applicationDirectoryURL: directory.appendingPathComponent("memory"),
                                          containerURL: directory, context: .init(useZenzai: false))
            defer { manager.deactivate(flushLearningData: false) }
            manager.restoreComposition(try #require(composition.checkpoint()))
            let actual = try #require(manager.mainCandidate)
            guard case .selecting(let selection, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
                Issue.record("Expected the actual conversion list")
                return
            }
            let index = try #require(selection.firstIndex(of: actual))
            let mainID = try #require(batch.mainCandidateID)
            #expect(mainID == batch.candidates[index].candidateID)
            let item = try #require(batch.candidates.first { $0.candidateID == mainID })
            #expect(item.text == actual.text)
            #expect(item.composingCount.composingCount == actual.composingCount)
            let consumption = try CandidateConsumption(composition: composition, count: item.composingCount)
            #expect(consumption.remaining.convertTarget == (partial ? "ご" : ""))
            #expect(consumption.remaining.isEmpty == !partial)
            #expect(batch.candidates.map(\.text) == selection.map(\.text))
        }
    }

    @Test func emptyConversionDoesNotInventAMainIdentity() throws {
        try DesktopCandidateTestSupport.withWorker { worker, _ in
            let batch = try DesktopCandidateTestSupport.batch(worker, request: DesktopCandidateTestSupport.request(""))
            #expect(batch.candidates.isEmpty)
            #expect(batch.mainCandidateID == nil)
        }
    }
}
