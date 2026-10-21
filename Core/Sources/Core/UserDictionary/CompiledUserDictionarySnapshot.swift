import Foundation

/// A candidate worker owns this private dictionary until all of its candidates have retired.
public final class CompiledUserDictionarySnapshot: Sendable {
    public let source: UserDictionarySource
    public let directoryURL: URL
    private let temporaryDirectoryURL: URL

    private init(source: UserDictionarySource, directoryURL: URL, temporaryDirectoryURL: URL) {
        self.source = source
        self.directoryURL = directoryURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    public static func prepare(_ source: UserDictionarySource) async throws -> CompiledUserDictionarySnapshot {
        try await UserDictionaryFileWorker.perform {
            // Compile after releasing the shared save lock. Neither the editor nor the reader waits for this work.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("azookey-dictionary-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            do {
                let dictionary = temporary.appendingPathComponent("UserDictionary", isDirectory: true)
                let update = try CompiledUserDictionaryStore.prepare(
                    items: source.items, directoryURL: dictionary, charIDFileURL: nil,
                    operations: UserDictionaryFileOperations())
                try update.install()
                _ = update.finish()
                return Self(source: source, directoryURL: dictionary, temporaryDirectoryURL: temporary)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }
}
