import Core
@testable import DesktopBridge
import Foundation
import KanaKanjiConverterModule
import Testing

@MainActor
enum DesktopCandidateTestSupport {
    static func withWorker(_ test: (DesktopCandidateWorker, URL) throws -> Void) throws {
        let previousLearning = Config.Learning().value
        let previousPrediction = Config.DebugPredictiveTyping().value
        let previousLive = Config.LiveConversion().value
        Config.Learning().value = .inputAndOutput
        Config.DebugPredictiveTyping().value = false
        Config.LiveConversion().value = false
        defer {
            Config.Learning().value = previousLearning
            Config.DebugPredictiveTyping().value = previousPrediction
            Config.LiveConversion().value = previousLive
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = try DesktopCandidateWorker(directory: directory)
        defer { worker.shutdown() }
        try test(worker, directory)
    }

    static func composition(_ text: String, segmentEnd: Int? = nil) -> CompositionState {
        var composition = CompositionState()
        composition.insertAtCursorPosition(text, inputStyle: .mapped(id: .defaultRomanToKana))
        if let segmentEnd { composition.editSegment(count: segmentEnd - composition.convertTarget.count) }
        return composition
    }

    static func request(_ text: String, context: String = "field", generation: String = "reader-1",
                        focus: Int = 1, revision: Int = 1, settings: Int = 0, privateInput: Bool = false,
                        segmentEnd: Int? = nil) throws -> DesktopCandidateRequest {
        .init(authority: .init(context: context, readingProcessGeneration: generation,
                               focusEpoch: focus, compositionRevision: revision, settingsRevision: settings,
                               requestID: UUID().uuidString),
              composition: try .capture(composition(text, segmentEnd: segmentEnd)),
              leftContext: "", rightContext: "", privateInput: privateInput)
    }

    static func batch(_ worker: DesktopCandidateWorker, request: DesktopCandidateRequest) throws -> DesktopCandidateBatch {
        try #require(worker.process(.init(operation: "candidates", request: request)).batch)
    }

    static func reference(_ batch: DesktopCandidateBatch) -> DesktopCandidateBatchReference {
        .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID)
    }

    static func completion(_ batch: DesktopCandidateBatch, text: String, settings: Int = 0,
                           privateInput: Bool = false, commitID: String = UUID().uuidString) throws -> DesktopCandidateCompletion {
        let candidate = try #require(batch.candidates.first { $0.text == text })
        return .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID,
                     candidateID: candidate.candidateID, commitID: commitID,
                     settingsRevision: settings, privateInput: privateInput)
    }

    static func complete(_ worker: DesktopCandidateWorker, _ request: DesktopCandidateCompletion) throws -> DesktopCandidateCompletionResult {
        try #require(worker.process(.init(operation: "complete", completion: request)).completion)
    }

    static func retain(_ worker: DesktopCandidateWorker, _ batch: DesktopCandidateBatch) throws {
        _ = try worker.process(.init(operation: "retain", reference: reference(batch)))
    }

    static func learning(_ worker: DesktopCandidateWorker, _ value: Config.Learning.Value, revision: Int) throws {
        _ = try worker.process(.init(operation: "configure-learning", workerGeneration: worker.workerGeneration,
                                     settingsRevision: revision, learning: value))
    }

    static func memory(in directory: URL) throws -> [String: Data] {
        let memory = directory.appendingPathComponent("memory")
        let files = try FileManager.default.contentsOfDirectory(at: memory, includingPropertiesForKeys: [.isRegularFileKey])
        return try files.reduce(into: [:]) { contents, file in
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                contents[file.lastPathComponent] = try Data(contentsOf: file)
            }
        }
    }
}
