import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopWorkerDefaultsTests {
    typealias Fixture = DesktopWorkerDefaultsFixture

    @Test func startupValuesAreCapturedOnceAndStaySeparateFromAppliedSettings() throws {
        let originalTable = "q\tにほんご\n"
        try Fixture.withSavedTable(Data(originalTable.utf8)) {
            var initial = DesktopWorkerSettingsFixture.settings()
            initial.tree = false
            initial.candidateTextSize = .large
            initial.showRelativeScores = false
            initial.halfSpace = true
            initial.backslash = true
            initial.optionDirect = true
            initial.punctuation = .periodAndComma
            initial.inputStyle = .defaultAZIK
            initial.learning = .onlyOutput
            initial.profile = "起動時の設定"
            initial.personalization = .hard
            initial.inferenceLimit = 17
            initial.typoCorrection = true
            initial.transformShortcut = .init(key: "t", modifiers: [.control, .shift])
            initial.customTable = originalTable
            let preferences = Config.userDefaults.dictionaryRepresentation() as NSDictionary
            let runtime = try DesktopWorkerSettingsRuntime(initial)
            var reader = runtime.perform { DesktopReadingWorker() }
            let hello = try reader.process(.init(operation: "hello"))
            #expect(hello.defaultSettings == initial)
            #expect(hello.defaultSettingsError == nil)
            #expect(hello.settings == nil)
            #expect(hello.customInputTableRevisions == [:])
            #expect(CustomInputTableStore.load() == initial.customTable)

            try Fixture.replaceSavedTable(Data("q\tかな\n".utf8))
            let changed = DesktopWorkerSettingsFixture.settings()
            let reply = try Config.withOverrides([Config.TypeHalfSpace.key: .boolean(false)]) {
                try reader.process(.init(operation: "settings"))
            }
            #expect(reply.defaultSettings == initial)
            let configured = try DesktopWorkerSettingsFixture.configure(&reader, settings: changed)
            #expect(configured.defaultSettings == nil)
            #expect(configured.defaultSettingsError == nil)
            let applied = try reader.process(.init(operation: "settings"))
            #expect(applied.settings == changed)
            #expect(applied.defaultSettings == initial)
            #expect(applied.defaultSettingsError == nil)
            #expect(Config.userDefaults.dictionaryRepresentation() as NSDictionary == preferences)
        }
    }

    @Test(arguments: [Config.LiveConversion.key, Config.DebugPredictiveTyping.key,
                      Config.DebugWindow.key, Config.AIBackendPreference.key])
    func unsupportedSavedFeaturesAreReportedHonestlyAndStillRejectedWhenApplied(_ key: String) throws {
        try Fixture.withSavedTable(nil) {
            let enabled: Config.OverrideValue = key == Config.AIBackendPreference.key
                ? .encoded(try JSONEncoder().encode(Config.AIBackendPreference.Value.openAI)) : .boolean(true)
            var reader = Config.withOverrides([key: enabled]) { DesktopReadingWorker() }
            let hello = try reader.process(.init(operation: "hello"))
            let defaults = try #require(hello.defaultSettings)
            switch key {
            case Config.LiveConversion.key: #expect(defaults.live)
            case Config.DebugPredictiveTyping.key: #expect(defaults.predictiveTyping)
            case Config.DebugWindow.key: #expect(defaults.debug)
            default: #expect(defaults.aiEnabled)
            }
            #expect(hello.defaultSettingsError == nil)
            #expect(throws: DesktopWorkerSettingsFailure.unsupportedSettings) {
                try DesktopWorkerSettingsFixture.configure(&reader, settings: defaults)
            }
            #expect(try reader.process(.init(operation: "settings")).settings == nil)
        }
    }

    @Test func storedValuesWithTheWrongTypeKeepTheExistingConfigFallback() throws {
        try Fixture.withSavedTable(nil) {
            var reader = Config.withOverrides([
                Config.ZenzaiInferenceLimit.key: .string("invalid integer"),
                Config.InputStyle.key: .encoded(Data("invalid enum".utf8)),
                Config.CandidateTextSize.key: .string("invalid size")
            ]) { DesktopReadingWorker() }
            let hello = try reader.process(.init(operation: "hello"))
            #expect(hello.defaultSettingsError == nil)
            #expect(hello.defaultSettings?.inferenceLimit == 5)
            #expect(hello.defaultSettings?.inputStyle == .default)
            #expect(hello.defaultSettings?.candidateTextSize == .standard)
        }
    }

    @Test func defaultsNeverAppearInInputControlOrFailureReplies() throws {
        try Fixture.withSavedTable(nil) {
            var reader = DesktopReadingWorker()
            try DesktopWorkerSettingsFixture.configure(&reader, settings: DesktopWorkerSettingsFixture.settings())
            let reference = try DesktopWorkerSettingsFixture.focus(&reader)
            let input = try reader.process(.init(operation: "key", reference: reference,
                                                event: .init(modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a", keyCode: 0)))
            let control = try reader.process(.init(operation: "reset", reference: reference, submit: false))
            let error = reader.rejected(DesktopWorkerSettingsFailure.settingsBusy)
            for reply in [input, control, error] {
                #expect(reply.defaultSettings == nil)
                #expect(reply.defaultSettingsError == nil)
            }
            #expect(input.snapshot?.reading == "あ")
        }
    }
}
