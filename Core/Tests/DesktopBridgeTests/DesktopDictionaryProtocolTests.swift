import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopDictionaryProtocolTests {
    @Test func dictionaryAcknowledgementsAreOptInAndDoNotChangeTheExistingInitialWireShape() throws {
        var reader = DesktopReadingWorker()
        let hello = try reader.process(.init(operation: "hello"))
        let initial = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any])
        #expect(initial["dictionaryRevision"] == nil)
        let settings = DesktopWorkerSettingsFixture.settings()
        let revision = String(repeating: "a", count: 64)
        let applied = try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                               settingsRevision: 1, settings: settings, dictionaryRevision: revision))
        #expect(applied.dictionaryRevision == revision)
        let focus = try DesktopWorkerSettingsFixture.focus(&reader)
        _ = try DesktopWorkerSettingsFixture.key(&reader, reference: focus, text: "a")
        let repeated = try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                                settingsRevision: 1, settings: settings, dictionaryRevision: revision))
        #expect(repeated.dictionaryRevision == revision && repeated.snapshot == nil)
        #expect(throws: DesktopDictionarySyncFailure.revisionRequired) {
            try DesktopWorkerSettingsFixture.configure(&reader, settings: settings, revision: 2)
        }
        #expect(throws: DesktopWorkerSettingsFailure.staleSettings) {
            try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                     settingsRevision: 1, settings: settings, dictionaryRevision: String(repeating: "b", count: 64)))
        }
        #expect(try DesktopWorkerSettingsFixture.key(&reader, reference: focus, code: 36).commits == ["あ"])
    }

    @Test(arguments: ["", "user text", "a", String(repeating: "A", count: 64), String(repeating: "g", count: 64)])
    func anInvalidDictionaryRevisionCannotChangeFormalInput(_ revision: String) throws {
        var reader = DesktopReadingWorker()
        let focus = try DesktopWorkerSettingsFixture.focus(&reader)
        _ = try DesktopWorkerSettingsFixture.key(&reader, reference: focus, text: "a")
        #expect(throws: DesktopDictionarySyncFailure.invalidRevision) {
            try reader.process(.init(operation: "configure-settings", readingProcessGeneration: reader.readingProcessGeneration,
                                     settingsRevision: 1, settings: DesktopWorkerSettingsFixture.settings(), dictionaryRevision: revision))
        }
        #expect(try DesktopWorkerSettingsFixture.key(&reader, reference: focus, code: 36).commits == ["あ"])
    }

    @Test func preparationRejectsUnknownFieldsAndDictionaryContentOnTheWire() throws {
        let allowed = "{\"operation\":\"prepare-dictionary\",\"workerGeneration\":\"worker\"}"
        #expect(try JSONDecoder().decode(DesktopCandidateWorkerRequest.self, from: Data(allowed.utf8)).operation == "prepare-dictionary")
        for field in ["items", "path", "settings", "dictionaryRevision"] {
            let payload = ["operation": "prepare-dictionary", "workerGeneration": "worker", field: "unsupported"]
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(DesktopCandidateWorkerRequest.self, from: JSONSerialization.data(withJSONObject: payload))
            }
        }
    }
}
