import Core
@testable import DesktopBridge
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
@Suite struct DesktopCandidateWorkerTests {
    private typealias Fixture = DesktopCandidateTestSupport

    @Test func emptyReadingHasNoCandidateAndTheReplyCannotEditTheInputField() throws {
        try Fixture.withWorker { worker, _ in
            let reply = try worker.process(.init(operation: "candidates", request: Fixture.request("")))
            #expect(try #require(reply.batch).candidates.isEmpty)
            let encoded = try JSONEncoder().encode(reply)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            for forbidden in ["commits", "preedit", "cursor", "inputState", "consumed"] {
                #expect(json[forbidden] == nil)
                #expect((json["batch"] as? [String: Any])?[forbidden] == nil)
            }
            let next = try Fixture.batch(worker, request: Fixture.request("nihongo", revision: 2))
            #expect(next.candidates.contains { $0.text == "日本語" })
        }
    }

    @Test func exportedCandidatesKeepTheActualConverterTextCountsAndPresentation() throws {
        try Fixture.withWorker { worker, directory in
            let request = try Fixture.request("nihongowobenkyou")
            let batch = try Fixture.batch(worker, request: request)
            let composition = try request.composition.restore()
            let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
                                          applicationDirectoryURL: directory.appendingPathComponent("memory"),
                                          containerURL: directory, context: .init(useZenzai: false))
            defer { manager.deactivate(flushLearningData: false) }
            manager.restoreComposition(try #require(composition.checkpoint()))
            guard case .selecting(let actual, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
                Issue.record("Expected actual converter candidates")
                return
            }
            let presentations = manager.makeCandidatePresentations(actual)
            #expect(batch.candidates.count == actual.count)
            #expect(Set(batch.candidates.map(\.candidateID)).count == actual.count)
            for (item, presentation) in zip(batch.candidates, presentations) {
                #expect(item.text == presentation.candidate.text)
                #expect(item.composingCount.composingCount == presentation.candidate.composingCount)
                #expect(item.presentation.tokens.map(\.text) == presentation.candidate.data.map(\.word))
                #expect(item.presentation.tokens.map(\.reading) == presentation.candidate.data.map(\.ruby))
                #expect(item.presentation.score == Double(presentation.candidate.value))
                #expect(item.presentation.comparisonGroup == presentation.consumedInputCount)
                #expect(item.presentation.commitScope == presentation.commitScope)
            }
            let actualPresentation = try #require(presentations.first)
            let first = try DesktopCandidateConversion.StoredItem(presentation: actualPresentation, composition: composition)
            let sameText = try DesktopCandidateConversion.StoredItem(presentation: actualPresentation, composition: composition)
            #expect(first.candidate == sameText.candidate)
            #expect(first.item.text == sameText.item.text)
            #expect(first.item.candidateID != sameText.item.candidateID)
        }
    }

    @Test func aRetainedPartialCandidateKeepsItsSourceAcrossANewerCalculation() throws {
        try Fixture.withWorker { worker, _ in
            let request = try Fixture.request("kyougo", segmentEnd: 3)
            let selected = try Fixture.batch(worker, request: request)
            try Fixture.retain(worker, selected)
            let candidate = try #require(selected.candidates.first { $0.text == "京" })
            let consumption = try CandidateConsumption(composition: request.composition.restore(), count: candidate.composingCount)
            #expect(consumption.consumedReading == "きょう")
            #expect(consumption.remaining.convertTarget == "ご")
            let newer = try Fixture.batch(worker, request: Fixture.request("nihongo", revision: 2))
            let completion = try Fixture.completion(selected, text: "京")
            let completed = try Fixture.complete(worker, completion)
            #expect(completed.status == .completed)
            #expect(completed.candidateID == candidate.candidateID)
            try Fixture.retain(worker, newer)
            let next = try Fixture.complete(worker, Fixture.completion(newer, text: "日本語"))
            #expect(next.status == .completed)
            #expect(request.composition.convertTarget == "きょうご")
        }
    }

    @Test func repeatingACompletedIDReturnsOnlyThePreviousReceipt() throws {
        try Fixture.withWorker { worker, directory in
            let batch = try Fixture.batch(worker, request: Fixture.request("kyou"))
            try Fixture.retain(worker, batch)
            let request = try Fixture.completion(batch, text: "京")
            let completed = try Fixture.complete(worker, request)
            #expect(completed.status == .completed)
            #expect(completed.learningRequested)
            let stored = try Fixture.memory(in: directory)
            #expect(!stored.isEmpty)
            let repeated = try Fixture.complete(worker, request)
            #expect(repeated.status == .alreadyCompleted)
            #expect(repeated.candidateID == request.candidateID)
            #expect(try Fixture.memory(in: directory) == stored)
            let changed = try Fixture.completion(batch, text: "京", privateInput: true, commitID: request.commitID)
            #expect(throws: DesktopCandidateFailure.commitIDConflict) { try Fixture.complete(worker, changed) }
            #expect(try Fixture.memory(in: directory) == stored)
        }
    }

    @Test func anUnretainedOldBatchIsRetiredButASelectedSameTextBatchHasAnotherIdentity() throws {
        try Fixture.withWorker { worker, _ in
            let first = try Fixture.batch(worker, request: Fixture.request("kyou"))
            let firstCompletion = try Fixture.completion(first, text: "京")
            #expect(throws: DesktopCandidateFailure.batchNotRetained) { try Fixture.complete(worker, firstCompletion) }
            let second = try Fixture.batch(worker, request: Fixture.request("kyou", revision: 2))
            let old = try #require(first.candidates.first { $0.text == "京" })
            let new = try #require(second.candidates.first { $0.text == "京" })
            #expect(old.candidateID != new.candidateID)
            #expect(first.batchID != second.batchID)
            #expect(throws: DesktopCandidateFailure.unknownBatch) { try Fixture.retain(worker, first) }
            try Fixture.retain(worker, second)
            #expect(try Fixture.complete(worker, Fixture.completion(second, text: "京")).status == .completed)
        }
    }
}
