import Core
import Foundation

/// The caller holds SettingsStore's writer lock; Core also holds the dictionary path lock.
final class DesktopDictionarySettingsFile: @unchecked Sendable {
    enum Failure: Error {
        case invalidStagingFile
        case dictionaryMismatch
        case readbackMismatch
    }

    private let stagedURL: URL
    private let settingsURL: URL
    private let backupURL: URL
    private let stagedContent: Data
    private var hasBackup = false
    private var isInstalled = false

    init(stagedURL: URL, settingsURL: URL, entries: [Config.UserDictionaryEntry]) throws {
        let directory = settingsURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let stage = stagedURL.standardizedFileURL
        guard stage.deletingLastPathComponent().resolvingSymlinksInPath() == directory,
              stage.lastPathComponent.hasPrefix(".settings-"), stage != settingsURL else {
            throw Failure.invalidStagingFile
        }
        try Self.requireRegularFile(stage)
        let content = try Data(contentsOf: stage)
        guard let dictionary = try Self.dictionary(in: content), Self.sameEntries(dictionary.items, entries) else {
            throw Failure.dictionaryMismatch
        }
        self.stagedURL = stage
        self.settingsURL = settingsURL.standardizedFileURL
        self.backupURL = directory.appendingPathComponent(".dictionary-settings-backup-\(UUID().uuidString)")
        self.stagedContent = content
    }

    func persistence() -> UserDictionaryPersistence {
        UserDictionaryPersistence {
            try await UserDictionaryFileWorker.perform { try self.capture() }
            return .init(
                write: { try await UserDictionaryFileWorker.perform { try self.install() } },
                restore: { try await UserDictionaryFileWorker.perform { try self.restore() } }
            )
        }
    }

    func discardBackup() throws {
        if hasBackup {
            try FileManager.default.removeItem(at: backupURL)
            hasBackup = false
        }
    }

    func discardUnusedBackup() throws {
        if !isInstalled {
            try discardBackup()
        }
    }

    func capture() throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: settingsURL.path)) != nil {
            throw Failure.invalidStagingFile
        }
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            try Self.requireRegularFile(settingsURL)
            // A hard link keeps the original inode and timestamps for conflict-aware retries.
            try FileManager.default.linkItem(at: settingsURL, to: backupURL)
            hasBackup = true
        }
    }

    func install() throws {
        try Self.requireRegularFile(stagedURL)
        guard try Data(contentsOf: stagedURL) == stagedContent else {
            throw Failure.invalidStagingFile
        }
        try Self.replaceFile(stagedURL, to: settingsURL)
        isInstalled = true
        guard try Data(contentsOf: settingsURL) == stagedContent else {
            throw Failure.readbackMismatch
        }
    }

    func restore() throws {
        if hasBackup {
            if isInstalled {
                try Self.replaceFile(backupURL, to: settingsURL)
            } else {
                try FileManager.default.removeItem(at: backupURL)
            }
            hasBackup = false
        } else if isInstalled {
            try FileManager.default.removeItem(at: settingsURL)
        }
        isInstalled = false
    }

    private static func replaceFile(_ source: URL, to destination: URL) throws {
        try PlatformFileOperations.replaceFile(source, to: destination)
    }

    private static func requireRegularFile(_ url: URL) throws {
        // Re-read the path without following links; compilation may outlive a file replacement.
        guard try PlatformFileOperations.isRegularFileWithoutFollowingLinks(url) else {
            throw Failure.invalidStagingFile
        }
    }

    static func dictionary(in content: Data) throws -> Config.UserDictionary.Value? {
        let document = try JSONSerialization.jsonObject(with: content) as? [String: Any]
        guard let dictionary = document?["userDictionary"] else {
            return nil
        }
        return try JSONDecoder().decode(
            Config.UserDictionary.Value.self, from: JSONSerialization.data(withJSONObject: dictionary)
        )
    }

    static func sameEntries(_ first: [Config.UserDictionaryEntry], _ second: [Config.UserDictionaryEntry]) -> Bool {
        first.count == second.count && zip(first, second).allSatisfy { lhs, rhs in
            lhs.id == rhs.id && lhs.word == rhs.word && lhs.reading == rhs.reading && lhs.nonNullHint == rhs.nonNullHint
        }
    }
}
