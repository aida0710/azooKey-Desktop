import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopWorkerDefaultsLimitTests {
    typealias Fixture = DesktopWorkerDefaultsFixture

    @Test(arguments: ["table-format", "table-utf8", "table-size", "custom-without-table",
                      "inference-limit", "profile-size", "shortcut", "settings-size"])
    func invalidDefaultsDoNotBreakHelloOrSilentlyBecomeAnEmptyTable(_ invalid: String) throws {
        var table: Data?
        var overrides: [String: Config.OverrideValue] = [:]
        switch invalid {
        case "table-format": table = Data("missing tab\n".utf8)
        case "table-utf8": table = Data([0xFF])
        case "table-size": table = Data(repeating: 0x61, count: DesktopWorkerProtocolLimits.settingsBytes + 1)
        case "custom-without-table":
            overrides[Config.InputStyle.key] = .encoded(try JSONEncoder().encode(Config.InputStyle.Value.custom))
        case "inference-limit": overrides[Config.ZenzaiInferenceLimit.key] = .integer(0)
        case "profile-size":
            overrides[Config.ZenzaiProfile.key] = .string(String(repeating: "a", count: DesktopSettingsValidation.profileCharacters + 1))
        case "settings-size":
            let shortcut = KeyboardShortcut(key: String(repeating: "x", count: DesktopWorkerProtocolLimits.settingsBytes), modifiers: [])
            overrides[Config.TransformShortcut.key] = .encoded(try JSONEncoder().encode(shortcut))
        default:
            overrides[Config.TransformShortcut.key] = .encoded(try JSONEncoder().encode(KeyboardShortcut(key: "", modifiers: [])))
        }
        try Fixture.withSavedTable(table) {
            var reader = Config.withOverrides(overrides) { DesktopReadingWorker() }
            for operation in ["hello", "settings"] {
                let reply = try reader.process(.init(operation: operation))
                #expect(reply.readingProcessGeneration == reader.readingProcessGeneration)
                #expect(reply.settingsContract == "full")
                #expect(reply.defaultSettings == nil)
                #expect(reply.defaultSettingsError == "invalid_worker_defaults")
                #expect(reply.error == nil)
                #expect(reply.settings == nil)
                #expect(try JSONEncoder().encode(reply).count < DesktopWorkerProtocolLimits.jsonBytes)
            }
            try Fixture.replaceSavedTable(nil)
            let configured = try DesktopWorkerSettingsFixture.configure(&reader, settings: DesktopWorkerSettingsFixture.settings())
            #expect(configured.settings != nil)
            #expect(configured.defaultSettingsError == nil)
            #expect(try reader.process(.init(operation: "settings")).defaultSettingsError == "invalid_worker_defaults")
        }
    }

    @Test func twoIndividuallyValidPayloadsCannotOverflowTheReplyEnvelope() throws {
        try Fixture.withSavedTable(nil) {
            let captured = try Fixture.fillingSettingsLimit(DesktopWorkerSettings(capturingCustomTable: ""))
            let shortcut = try JSONEncoder().encode(captured.transformShortcut)
            var reader = Config.withOverrides([Config.TransformShortcut.key: .encoded(shortcut)]) { DesktopReadingWorker() }
            let firstHello = try reader.process(.init(operation: "hello"))
            #expect(firstHello.defaultSettings == captured)
            #expect(firstHello.defaultSettingsError == nil)
            let applied = try Fixture.fillingSettingsLimit(DesktopWorkerSettingsFixture.settings())
            try DesktopWorkerSettingsFixture.configure(&reader, settings: applied)
            for operation in ["hello", "settings"] {
                let reply = try reader.process(.init(operation: operation))
                #expect(reply.defaultSettings == nil)
                #expect(reply.defaultSettingsError == "invalid_worker_defaults")
                #expect(reply.settings == applied)
                #expect(reply.error == nil)
                #expect(try JSONEncoder().encode(reply).count <= DesktopWorkerProtocolLimits.jsonBytes)
            }
            try DesktopWorkerSettingsFixture.configure(&reader, settings: DesktopWorkerSettingsFixture.settings(), revision: 1)
            #expect(try reader.process(.init(operation: "settings")).defaultSettings == captured)
        }
    }
}
