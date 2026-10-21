import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopDictionaryBindingProtocolTests {
    private static let digest = String(repeating: "a", count: 64)

    @Test(arguments: ["", "payload text", String(repeating: "A", count: 64), String(repeating: "g", count: 64)])
    func malformedDigestsCannotChangeEitherRolesAppliedSettings(_ digest: String) async throws {
        var reader = DesktopReadingWorker()
        let fixture = try DesktopDictionarySyncFixture()
        defer { fixture.close() }
        let settings = DesktopWorkerSettingsFixture.settings()
        try DesktopWorkerSettingsFixture.configure(&reader, settings: settings)
        try DesktopWorkerSettingsFixture.configure(fixture.worker, settings: settings)
        #expect(throws: DesktopDictionarySyncFailure.invalidRevision) {
            try reader.process(.init(operation: "bind-initial-dictionary", readingProcessGeneration: reader.readingProcessGeneration,
                                     settingsRevision: 0, settings: settings, dictionaryRevision: digest))
        }
        await #expect(throws: DesktopDictionarySyncFailure.invalidRevision) {
            try await fixture.worker.processAsync(.init(operation: "bind-initial-dictionary", workerGeneration: fixture.worker.workerGeneration,
                                                        settingsRevision: 0, settings: settings, dictionaryRevision: digest))
        }
        #expect(try reader.process(.init(operation: "settings")).dictionaryRevision == nil)
        #expect(try fixture.worker.process(.init(operation: "settings")).dictionaryRevision == nil)
    }

    @Test func bindingRejectsInputEffectsAndDictionaryContentsOnBothWires() throws {
        let settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DesktopWorkerSettingsFixture.settings()))
        for role in ["reader", "candidate"] {
            let generation = role == "reader" ? "readingProcessGeneration" : "workerGeneration"
            let valid: [String: Any] = ["operation": "bind-initial-dictionary", generation: "generation",
                                       "settingsRevision": 0, "settings": settings, "dictionaryRevision": Self.digest]
            for field in ["items", "path", "event", "reference", "completion", "unknown"] {
                var invalid = valid
                invalid[field] = "not allowed"
                let encoded = try JSONSerialization.data(withJSONObject: invalid)
                if role == "reader" {
                    #expect(throws: (any Error).self) { try JSONDecoder().decode(DesktopReadingWorkerRequest.self, from: encoded) }
                } else {
                    #expect(throws: (any Error).self) { try JSONDecoder().decode(DesktopCandidateWorkerRequest.self, from: encoded) }
                }
            }
        }
    }

    @Test func candidateBindingNeedsThisWorkerAndPreparationBeforeRetainedContexts() async throws {
        let fixture = try DesktopDictionarySyncFixture()
        defer { fixture.close() }
        let settings = DesktopWorkerSettingsFixture.settings()
        let generation = fixture.worker.workerGeneration
        let absent = DesktopCandidateWorkerRequest(operation: "bind-initial-dictionary", workerGeneration: generation,
                                                    settingsRevision: 0, settings: settings, dictionaryRevision: Self.digest)
        await #expect(throws: DesktopWorkerSettingsFailure.fullSettingsRequired) { try await fixture.worker.processAsync(absent) }
        try DesktopWorkerSettingsFixture.configure(fixture.worker, settings: settings)
        await #expect(throws: DesktopDictionarySyncFailure.notPrepared) { try await fixture.worker.processAsync(absent) }
        let dictionary = try await fixture.prepare()
        await #expect(throws: DesktopCandidateFailure.wrongWorkerGeneration) {
            try await fixture.worker.processAsync(.init(operation: "bind-initial-dictionary", workerGeneration: "old-worker",
                                                        settingsRevision: 0, settings: settings, dictionaryRevision: dictionary))
        }
        var different = settings
        different.halfSpace.toggle()
        await #expect(throws: DesktopWorkerSettingsFailure.staleSettings) {
            try await fixture.worker.processAsync(.init(operation: "bind-initial-dictionary", workerGeneration: generation,
                                                        settingsRevision: 0, settings: different, dictionaryRevision: dictionary))
        }
        let batch = try fixture.batch("a")
        try DesktopCandidateTestSupport.retain(fixture.worker, batch)
        let binding = DesktopCandidateWorkerRequest(operation: "bind-initial-dictionary", workerGeneration: generation,
                                                     settingsRevision: 0, settings: settings, dictionaryRevision: dictionary)
        await #expect(throws: DesktopDictionarySyncFailure.bindingBusy) { try await fixture.worker.processAsync(binding) }
        #expect(try fixture.worker.process(.init(operation: "settings")).dictionaryRevision == nil)
        try DesktopCandidateTestSupport.retain(fixture.worker, batch)
        try fixture.closeContext()
        #expect(try await fixture.worker.processAsync(binding).dictionaryRevision == dictionary)
        #expect(throws: DesktopCandidateFailure.unknownBatch) { try DesktopCandidateTestSupport.retain(fixture.worker, batch) }
    }
}
