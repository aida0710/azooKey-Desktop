import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
final class DesktopDictionarySyncFixture {
    enum Failure: Error { case activation }

    let directory: URL
    let defaults: UserDefaults
    let sourceStore: UserDictionarySourceStore
    let worker: DesktopCandidateWorker
    private let suiteName = "azookey-dictionary-sync-\(UUID().uuidString)"

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let empty = Data("{\"items\":[]}".utf8)
        defaults.set(empty, forKey: Config.UserDictionary.key)
        defaults.set(empty, forKey: Config.SystemUserDictionary.key)
        sourceStore = UserDictionarySourceStore(defaults: defaults, fallbackDefaults: nil)
        worker = try DesktopCandidateWorker(directory: directory, dictionarySourceStore: sourceStore)
    }

    func close() {
        worker.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func save(_ items: [Config.UserDictionaryEntry], failActivation: Bool = false) async throws {
        try await UserDictionarySaveTransaction.save(
            items: items, systemItems: [],
            directoryURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: directory.appendingPathComponent("memory")),
            persistence: UserDictionaryConfigPersistence.make(items: items, defaults: defaults),
            activate: { if failActivation { throw Failure.activation } })
    }

    func prepare() async throws -> String {
        let response = try await worker.processAsync(.init(operation: "prepare-dictionary", workerGeneration: worker.workerGeneration))
        let encoded = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
        #expect(!encoded.contains("専用候補"))
        #expect(response.batch == nil && response.completion == nil && response.reconversionReadingResult == nil)
        return try #require(response.preparedDictionaryRevision)
    }

    @discardableResult
    func configure(_ dictionary: String, revision: Int = 1,
                   settings: DesktopWorkerSettings = DesktopWorkerSettingsFixture.settings()) async throws -> DesktopCandidateWorkerResponse {
        try await worker.processAsync(.init(operation: "configure-settings", workerGeneration: worker.workerGeneration,
                                            settingsRevision: revision, settings: settings, dictionaryRevision: dictionary))
    }

    func reading(of text: String, privateInput: Bool = false) throws -> String? {
        let request = try DesktopCandidateTestSupport.request("", settings: worker.settingsRevision)
        return try worker.process(.init(operation: "resolve-reconversion-reading", reconversionReadingRequest: .init(
            authority: request.authority, workerGeneration: worker.workerGeneration, text: text,
            privateInput: privateInput))).reconversionReadingResult?.reading
    }

    func batch(_ roman: String, revision: Int = 1, privateInput: Bool = false) throws -> DesktopCandidateBatch {
        try DesktopCandidateTestSupport.batch(worker, request: DesktopCandidateTestSupport.request(
            roman, revision: revision, settings: worker.settingsRevision, privateInput: privateInput))
    }

    func closeContext() throws {
        _ = try worker.process(.init(operation: "close", workerGeneration: worker.workerGeneration,
                                     context: "field", readingProcessGeneration: "reader-1"))
    }
}
