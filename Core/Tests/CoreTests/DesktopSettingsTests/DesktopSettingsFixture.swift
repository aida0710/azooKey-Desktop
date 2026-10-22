import Foundation

@testable import Core

/// Synthetic settings and a disposable settings directory for one test.
final class DesktopSettingsFixture {
    static let entryID = UUID(uuidString: "6C5FCE13-FB0F-4B59-9281-F7347AE8F91C")!

    static var known: DesktopSettings {
        var settings = DesktopSettings.defaults
        settings.tree = false
        settings.live = false
        settings.halfSpace = true
        settings.learning = .nothing
        settings.profile = "テスト"
        settings.personalization = .soft
        settings.aiEnabled = true
        settings.aiModel = "test-model"
        settings.aiEndpoint = "https://example.invalid/v1"
        settings.includeContext = false
        settings.transformShortcut = KeyboardShortcut(key: "s", modifiers: .control)
        settings.aiPromptLanguage = .japanese
        var entry = Config.UserDictionaryEntry(word: "試験", reading: "てすと")
        entry.id = entryID
        settings.userDictionary = .init(items: [entry])
        return settings
    }

    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("azookey-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("settings.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    var lastGoodURL: URL {
        directoryURL.appendingPathComponent("settings.last-good.json")
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: fileURL)
    }

    func write(_ settings: DesktopSettings) throws {
        try DesktopSettingsDocument.data(for: settings).write(to: fileURL)
    }

    func contents() throws -> Data {
        try Data(contentsOf: fileURL)
    }

    func savedSettings() throws -> DesktopSettings {
        try DesktopSettingsDocument.settings(from: contents(), over: .defaults)
    }

    func files(withPrefix prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
}

/// The problem `body` threw, or nil when it did not throw one.
func settingsProblem(_ body: () throws -> Void) -> DesktopSettingsProblem? {
    do {
        try body()
        return nil
    } catch {
        return error as? DesktopSettingsProblem
    }
}

@MainActor
func asyncSettingsProblem(_ body: () async throws -> Void) async -> DesktopSettingsProblem? {
    do {
        try await body()
        return nil
    } catch {
        return error as? DesktopSettingsProblem
    }
}

struct SyntheticFailure: Error, Equatable {}
