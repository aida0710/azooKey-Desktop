import Core
@testable import DesktopBridge
import Foundation
import Testing

final class DesktopDictionaryFileFixture {
    let rootURL: URL
    let settingsURL: URL
    let stagedURL: URL
    let oldEntries = [Config.UserDictionaryEntry(word: "以前の登録語", reading: "てすと")]
    let newEntries = [Config.UserDictionaryEntry(word: "新しい登録語", reading: "てすと", hint: "補足\t注釈🙂")]

    init(hasPreviousSettings: Bool = true) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-json-\(UUID().uuidString)")
        rootURL = directory
        settingsURL = directory.appendingPathComponent("settings.json")
        stagedURL = directory.appendingPathComponent(".settings-test.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if hasPreviousSettings {
            try content(entries: oldEntries).write(to: settingsURL)
            // A fixed past date makes an accidentally rewritten copy observable.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: settingsURL.path
            )
        }
        try content(entries: newEntries).write(to: stagedURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func content(entries: [Config.UserDictionaryEntry]) throws -> Data {
        var dictionary = Config.UserDictionary.default
        dictionary.items = entries
        let document: [String: Any] = [
            "userDictionary": try JSONSerialization.jsonObject(with: JSONEncoder().encode(dictionary)),
            "tree": false,
            "live": true,
            "appearance": ["fontScale": 1.25],
            "customSetting": ["preserved": "固定データ\n改行"]
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
    }

    func makeFile() throws -> DesktopDictionarySettingsFile {
        try DesktopDictionarySettingsFile(stagedURL: stagedURL, settingsURL: settingsURL, entries: newEntries)
    }

    func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".dictionary-settings-backup-") }
    }

    func identity(at url: URL? = nil) throws -> Identity {
        let attributes = try FileManager.default.attributesOfItem(atPath: (url ?? settingsURL).path)
        return Identity(
            inode: try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value,
            modificationDate: try #require(attributes[.modificationDate] as? Date)
        )
    }

    struct Identity: Equatable {
        let inode: UInt64
        let modificationDate: Date
    }
}
