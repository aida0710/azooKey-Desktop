import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopWorkerSettingsProtocolTests {
    typealias Fixture = DesktopWorkerSettingsFixture

    @Test func settingsMetadataAppearsOnlyInSettingsRepliesAndErrorsHaveNoEffects() throws {
        var reader = DesktopReadingWorker()
        let settings = Fixture.settings()
        let configured = try Fixture.configure(&reader, settings: settings)
        let metadata = try object(configured)
        #expect(Set(metadata.keys) == ["kind", "readingProcessGeneration", "settingsRevision", "settingsContract",
                                      "settings", "customInputTableRevisions", "unsupportedFeatures"])
        let reference = try Fixture.focus(&reader)
        let snapshot = try reader.process(.init(operation: "snapshot", reference: reference))
        #expect(snapshot.settings == nil)
        #expect(snapshot.settingsContract == nil)
        let rejected = try object(reader.rejected(DesktopWorkerSettingsFailure.settingsBusy))
        #expect(Set(rejected.keys) == ["kind", "readingProcessGeneration", "settingsRevision", "error"])
        #expect(rejected["error"] as? String == "worker_settings_busy")
    }

    @Test(arguments: ["dictionary", "wrong-role", "extra-shortcut-field"])
    func unknownFullSettingsFieldsAreRejectedByBothWireDecoders(_ invalid: String) throws {
        var settings = try object(Fixture.settings())
        var payload: [String: Any] = ["operation": "configure-settings", "settingsRevision": 0]
        switch invalid {
        case "dictionary": settings["userDictionary"] = ["items": []]
        case "wrong-role": payload["context"] = "unrelated"
        default: settings["transformShortcut"] = ["key": "s", "modifiers": 2, "fallback": "none"]
        }
        payload["settings"] = settings
        payload["readingProcessGeneration"] = "reader"
        let readingBytes = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DesktopReadingWorkerRequest.self, from: readingBytes) }
        payload.removeValue(forKey: "readingProcessGeneration")
        payload["workerGeneration"] = "candidate"
        let candidateBytes = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DesktopCandidateWorkerRequest.self, from: candidateBytes) }
    }

    @Test func reconfigurationRetiresCandidateOwnershipWithoutChangingTheInputLanguage() throws {
        var reader = DesktopReadingWorker()
        var settings = Fixture.settings()
        try Fixture.configure(&reader, settings: settings)
        let reference = try Fixture.focus(&reader)
        _ = try Fixture.key(&reader, reference: reference, text: "nihongo")
        let prepared = try reader.process(.init(operation: "prepare-candidates", reference: reference, candidateWorkerGeneration: "old-candidate"))
        #expect(prepared.candidateRequest != nil)
        _ = try Fixture.key(&reader, reference: reference, code: 53)
        _ = try Fixture.key(&reader, reference: reference, code: 102)
        let inactive = try reader.process(.init(operation: "focus-out", reference: reference, submit: false))
        settings.inputStyle = .defaultAZIK
        try Fixture.configure(&reader, settings: settings, revision: 1)
        let focused = try #require(reader.process(.init(operation: "focus-in", reference: inactive.nextReference,
                                                        surroundings: .init(leftContext: "", rightContext: "", privateInput: false))).reference)
        #expect(throws: DesktopReadingProtocolFailure.wrongCandidateWorker) {
            try reader.process(.init(operation: "candidate-worker-stopped", reference: focused, candidateWorkerGeneration: "old-candidate"))
        }
        let english = try Fixture.key(&reader, reference: focused, text: "a")
        #expect(english.language == "english")
        #expect(english.commits == ["a"])
        _ = try Fixture.key(&reader, reference: focused, code: 104)
        #expect(try Fixture.key(&reader, reference: focused, text: "kz").reading == "かん")
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
