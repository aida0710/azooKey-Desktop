import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
struct DesktopReadingWorkerFixture {
    var worker: DesktopReadingWorker
    var reference: DesktopReadingContextReference

    init(privateInput: Bool = false) throws {
        var worker = DesktopReadingWorker()
        let opened = try worker.process(.init(operation: "open", readingProcessGeneration: worker.readingProcessGeneration,
                                              context: "field"))
        let focused = try worker.process(.init(operation: "focus-in", reference: opened.reference,
                                               surroundings: .init(leftContext: "", rightContext: "", privateInput: privateInput)))
        self.worker = worker
        reference = try #require(focused.reference)
    }

    mutating func key(_ code: UInt16 = 0, text: String? = nil) throws -> DesktopSnapshot {
        let response = try worker.process(.init(
            operation: "key", reference: reference,
            event: .init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: code)))
        return try #require(response.snapshot)
    }

    mutating func snapshot() throws -> DesktopSnapshot {
        try #require(worker.process(.init(operation: "snapshot", reference: reference)).snapshot)
    }

    mutating func batch(partial: Bool = false) throws -> DesktopCandidateBatch {
        let prepared = try worker.process(.init(operation: "prepare-candidates", reference: reference,
                                                candidateWorkerGeneration: "converter"))
        let request = try #require(prepared.candidateRequest)
        return try .init(authority: request.authority, workerGeneration: "converter", batchID: UUID().uuidString,
                         candidates: [.init(candidateID: "candidate", text: partial ? "荷" : "日本語",
                                            composingCount: .init(.inputCount(partial ? 2 : 7)),
                                            presentation: .init(tokens: [], annotation: nil, extraValues: [:],
                                                                score: nil, comparisonGroup: nil, commitScope: nil))])
    }

    func retained(_ batch: DesktopCandidateBatch) -> DesktopCandidateBatchReference {
        .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID)
    }

    mutating func adopt(_ batch: DesktopCandidateBatch) throws -> DesktopReadingWorkerResponse {
        try worker.process(.init(operation: "adopt-candidates", reference: reference,
                                 batch: batch, retainedReference: retained(batch)))
    }

    mutating func select(_ batch: DesktopCandidateBatch) throws -> DesktopSnapshot {
        let response = try worker.process(.init(operation: "select", reference: reference,
                                               selection: .init(batch: retained(batch), candidateID: "candidate")))
        return try #require(response.snapshot)
    }
}
