import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopWorkerSettingsTests {
    typealias Fixture = DesktopWorkerSettingsFixture

    @Test func settingsAcknowledgementContainsTheAppliedValuesWithoutChangingPreferences() throws {
        var settings = Fixture.settings()
        settings.halfSpace = true
        settings.candidateTextSize = .large
        settings.showRelativeScores = false
        settings.inferenceLimit = 7
        settings.profile = "worker profile"
        let preferences = Config.userDefaults.dictionaryRepresentation() as NSDictionary
        let customTable = CustomInputTableStore.load()
        var reader = DesktopReadingWorker()
        let hello = try reader.process(.init(operation: "hello"))
        #expect(hello.settings == nil)
        #expect(hello.settingsContract == "full")
        let applied = try Fixture.configure(&reader, settings: settings)
        #expect(applied.settings == settings)
        #expect(applied.settingsRevision == 0)
        #expect(applied.readingProcessGeneration == reader.readingProcessGeneration)
        let reference = try Fixture.focus(&reader)
        let snapshot = try Fixture.key(&reader, reference: reference, code: 49, text: " ")
        #expect(snapshot.commits == [" "])
        #expect(snapshot.candidateTextSize == .large)
        #expect(!snapshot.showRelativeScores)
        #expect(Config.userDefaults.dictionaryRepresentation() as NSDictionary == preferences)
        #expect(CustomInputTableStore.load() == customTable)
    }

    @Test func anIdenticalRevisionRetryDoesNotClearActiveInputAndDifferentSettingsCannotReplaceIt() throws {
        var reader = DesktopReadingWorker()
        var settings = Fixture.settings()
        try Fixture.configure(&reader, settings: settings, revision: 2)
        let reference = try Fixture.focus(&reader)
        _ = try Fixture.key(&reader, reference: reference, text: "nihongo")
        let repeated = try Fixture.configure(&reader, settings: settings, revision: 2)
        #expect(repeated.settingsRevision == 2)
        #expect(repeated.snapshot == nil)
        settings.halfSpace = true
        #expect(throws: DesktopWorkerSettingsFailure.staleSettings) {
            try Fixture.configure(&reader, settings: settings, revision: 2)
        }
        #expect(throws: DesktopWorkerSettingsFailure.settingsBusy) {
            try Fixture.configure(&reader, settings: settings, revision: 3)
        }
        #expect(try Fixture.key(&reader, reference: reference, code: 36).commits == ["にほんご"])
        #expect(throws: DesktopWorkerSettingsFailure.settingsBusy) {
            try Fixture.configure(&reader, settings: settings, revision: 3)
        }
        let blurred = try reader.process(.init(operation: "focus-out", reference: reference, submit: false))
        try Fixture.configure(&reader, settings: settings, revision: 3)
        let focused = try #require(reader.process(.init(operation: "focus-in", reference: blurred.nextReference,
                                                        surroundings: .init(leftContext: "", rightContext: "", privateInput: false))).reference)
        #expect(try Fixture.key(&reader, reference: focused, code: 49, text: " ").commits == [" "])
    }

    @Test func revisionIdentityPreservesExactUnicodeBytesAndRejectsStaleGenerations() throws {
        var reader = DesktopReadingWorker()
        var settings = Fixture.settings()
        settings.profile = "\u{e9}"
        try Fixture.configure(&reader, settings: settings, revision: 4)
        settings.profile = "e\u{301}"
        #expect(throws: DesktopWorkerSettingsFailure.staleSettings) {
            try Fixture.configure(&reader, settings: settings, revision: 4)
        }
        #expect(throws: DesktopWorkerSettingsFailure.staleSettings) {
            try Fixture.configure(&reader, settings: settings, revision: 3)
        }
        #expect(throws: DesktopReadingProtocolFailure.wrongProcess) {
            try reader.process(.init(operation: "configure-settings", readingProcessGeneration: "old-reader",
                                     settingsRevision: 5, settings: settings))
        }
        #expect(throws: DesktopWorkerSettingsFailure.fullSettingsRequired) {
            try reader.process(.init(operation: "learning-revision", readingProcessGeneration: reader.readingProcessGeneration,
                                     settingsRevision: 5))
        }
        #expect(try reader.process(.init(operation: "settings")).settingsRevision == 4)
    }

    @Test(arguments: ["live", "predictiveTyping", "aiEnabled", "debug"])
    func unsupportedSettingsAreRejectedWithoutSilentlyDisablingThem(_ key: String) throws {
        var reader = DesktopReadingWorker()
        let settings = Fixture.settings()
        try Fixture.configure(&reader, settings: settings)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        payload[key] = true
        let unsupported = try JSONDecoder().decode(DesktopWorkerSettings.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(throws: DesktopWorkerSettingsFailure.unsupportedSettings) {
            try Fixture.configure(&reader, settings: unsupported, revision: 1)
        }
        #expect(try reader.process(.init(operation: "settings")).settings == settings)
    }

    @Test(arguments: ["inferenceLimit", "customTable", "transformShortcut", "missing", "unknown", "dictionary"])
    func anInvalidFullSettingsPayloadCannotPartiallyChangeTheReader(_ invalid: String) throws {
        var reader = DesktopReadingWorker()
        let settings = Fixture.settings()
        try Fixture.configure(&reader, settings: settings)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        switch invalid {
        case "inferenceLimit": payload[invalid] = 0
        case "customTable": payload[invalid] = "a\tあ\na\tい\n"
        case "transformShortcut": payload[invalid] = ["key": "s", "modifiers": 32]
        case "missing": payload.removeValue(forKey: "halfSpace")
        case "unknown": payload[invalid] = false
        default: payload["userDictionary"] = ["items": []]
        }
        #expect(throws: (any Error).self) {
            let decoded = try JSONDecoder().decode(DesktopWorkerSettings.self, from: JSONSerialization.data(withJSONObject: payload))
            try Fixture.configure(&reader, settings: decoded, revision: 1)
        }
        #expect(try reader.process(.init(operation: "settings")).settings == settings)
        let reference = try Fixture.focus(&reader)
        #expect(try Fixture.key(&reader, reference: reference, code: 49, text: " ").commits == ["　"])
    }
}
