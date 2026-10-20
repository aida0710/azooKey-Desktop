import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct UserDictionaryFileOperations: Sendable {
    var move: @Sendable (URL, URL) throws -> Void = {
        try FileManager.default.moveItem(at: $0, to: $1)
    }
    var remove: @Sendable (URL) throws -> Void = {
        try FileManager.default.removeItem(at: $0)
    }
    var compile: @Sendable ([DicdataElement], URL, URL) throws -> Void = { entries, directory, characters in
        try DictionaryBuilder.exportDictionary(
            entries: entries, to: directory, baseName: "user",
            shardByFirstCharacter: false, charIDFileURL: characters
        )
    }
}

/// Mutable state is used only by successive, awaited file operations while the path lock is held.
final class CompiledUserDictionaryUpdate: @unchecked Sendable {
    let directoryURL: URL
    let stagingURL: URL
    let backupURL: URL
    private let operations: UserDictionaryFileOperations
    private var hasBackup = false
    private var isInstalled = false

    init(directoryURL: URL, operations: UserDictionaryFileOperations) throws {
        self.directoryURL = directoryURL
        self.operations = operations
        let parentURL = directoryURL.deletingLastPathComponent()
        let identifier = UUID().uuidString
        self.stagingURL = parentURL.appendingPathComponent(
            "\(directoryURL.lastPathComponent).building-\(identifier)", isDirectory: true
        )
        self.backupURL = parentURL.appendingPathComponent(
            "\(directoryURL.lastPathComponent).backup-\(identifier)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: self.stagingURL, withIntermediateDirectories: true)
    }

    func install() throws {
        if FileManager.default.fileExists(atPath: self.directoryURL.path) {
            try self.operations.move(self.directoryURL, self.backupURL)
            self.hasBackup = true
        }
        try self.operations.move(self.stagingURL, self.directoryURL)
        self.isInstalled = true
    }

    func rollback() throws {
        if self.isInstalled {
            // Keep both versions if restoring the backup fails; never delete the only valid copy.
            try self.operations.move(self.directoryURL, self.stagingURL)
            self.isInstalled = false
        }
        if self.hasBackup {
            do {
                try self.operations.move(self.backupURL, self.directoryURL)
                self.hasBackup = false
            } catch {
                if FileManager.default.fileExists(atPath: self.stagingURL.path) {
                    try? self.operations.move(self.stagingURL, self.directoryURL)
                }
                throw error
            }
        }
        self.discardStaging()
    }

    func discardStaging() {
        try? self.operations.remove(self.stagingURL)
    }

    /// A cleanup failure keeps a redundant backup and does not invalidate an already committed save.
    func finish() -> URL? {
        guard self.hasBackup else {
            return nil
        }
        do {
            try self.operations.remove(self.backupURL)
            self.hasBackup = false
            return nil
        } catch {
            return self.backupURL
        }
    }

    var recoveryDirectoryURL: URL? {
        self.hasBackup ? self.backupURL : nil
    }
}
