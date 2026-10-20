import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
@Suite struct DesktopWorkerInputSettingsTests {
    typealias Fixture = DesktopWorkerSettingsFixture

    @Test(arguments: [Config.InputStyle.Value.default, .defaultAZIK, .defaultKanaJIS, .defaultKanaUS])
    func theAcknowledgedInputStyleChangesActualReading(_ style: Config.InputStyle.Value) throws {
        var settings = Fixture.settings()
        settings.inputStyle = style
        let text: String
        let expected: String
        switch style {
        case .default: (text, expected) = ("ka", "か")
        case .defaultAZIK: (text, expected) = ("kz", "かん")
        default: (text, expected) = ("tw", "かて")
        }
        var reader = DesktopReadingWorker()
        try Fixture.configure(&reader, settings: settings)
        let reference = try Fixture.focus(&reader)
        #expect(try Fixture.key(&reader, reference: reference, text: text).reading == expected)
        #expect(try Fixture.key(&reader, reference: reference, code: 36).commits == [expected])
    }

    @Test func punctuationBackslashAndOptionDirectUseEachReadersSettings() throws {
        var configured = Fixture.settings()
        configured.punctuation = .periodAndComma
        configured.backslash = true
        configured.optionDirect = true
        var changed = DesktopReadingWorker()
        var unchanged = DesktopReadingWorker()
        try Fixture.configure(&changed, settings: configured)
        try Fixture.configure(&unchanged, settings: Fixture.settings())
        let first = try Fixture.focus(&changed)
        let second = try Fixture.focus(&unchanged)
        #expect(try Fixture.key(&changed, reference: first, text: ",.").reading == "，．")
        #expect(try Fixture.key(&unchanged, reference: second, text: ",.").reading == "、。")
        _ = try Fixture.key(&changed, reference: first, code: 36)
        _ = try Fixture.key(&unchanged, reference: second, code: 36)
        #expect(try Fixture.key(&changed, reference: first, text: "¥").reading == "＼")
        #expect(try Fixture.key(&unchanged, reference: second, text: "¥").reading == "￥")
        _ = try Fixture.key(&changed, reference: first, code: 36)
        #expect(try Fixture.key(&changed, reference: first, text: "a", modifiers: .option).commits == ["ａ"])
        #expect(try Fixture.key(&unchanged, reference: second, code: 36).commits == ["￥"])
    }

    @Test func everyAcknowledgedPreferenceUsesTheOrdinaryConfigRepresentationWithinTheScope() throws {
        var settings = Fixture.settings()
        settings.tree = false
        settings.candidateTextSize = .large
        settings.showRelativeScores = false
        settings.halfSpace = true
        settings.backslash = true
        settings.optionDirect = true
        settings.inputStyle = .defaultAZIK
        settings.learning = .onlyOutput
        settings.punctuation = .periodAndComma
        settings.profile = "明示設定"
        settings.personalization = .hard
        settings.inferenceLimit = 17
        settings.typoCorrection = true
        settings.transformShortcut = .init(key: "t", modifiers: [.control, .shift])
        let runtime = try DesktopWorkerSettingsRuntime(settings)
        let actual = runtime.perform { DesktopWorkerSettings(DesktopSettings()) }
        var expected = settings
        // The custom table is delivered on the wire, not through Config or the persistent table file.
        expected.customTable = CustomInputTableStore.load() ?? ""
        #expect(actual == expected)
    }

    @Test func distinctCustomTablesDoNotOverwriteAnExistingReadersMapping() throws {
        var firstSettings = Fixture.settings()
        firstSettings.inputStyle = .custom
        firstSettings.customTable = "q\tにほんご\n"
        var secondSettings = firstSettings
        secondSettings.customTable = "q\tかな\n"
        var first = DesktopReadingWorker()
        var second = DesktopReadingWorker()
        let firstACK = try Fixture.configure(&first, settings: firstSettings)
        let secondACK = try Fixture.configure(&second, settings: secondSettings)
        #expect(firstACK.customInputTableRevisions != secondACK.customInputTableRevisions)
        let firstReference = try Fixture.focus(&first)
        let secondReference = try Fixture.focus(&second)
        #expect(try Fixture.key(&first, reference: firstReference, text: "q").reading == "にほんご")
        #expect(try Fixture.key(&second, reference: secondReference, text: "q").reading == "かな")
        #expect(try Fixture.key(&first, reference: firstReference, text: "q").reading == "にほんごにほんご")
        let prepared = try first.process(.init(operation: "prepare-candidates", reference: firstReference, candidateWorkerGeneration: "converter"))
        #expect(prepared.candidateRequest?.composition.customInputTableRevisions == firstACK.customInputTableRevisions)
    }
}
