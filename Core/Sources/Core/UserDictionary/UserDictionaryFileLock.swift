import Foundation

/// Holds a process-wide lock for a dictionary directory until the whole save,
/// including callbacks, ends.
final class UserDictionaryFileLock: @unchecked Sendable {
    private let lock: ExclusiveFileLock

    init(directoryURL: URL) throws {
        let canonicalURL = Self.canonicalDirectoryURL(directoryURL)
        let parentURL = canonicalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        self.lock = try ExclusiveFileLock(
            lockFileURL: parentURL.appendingPathComponent(".\(canonicalURL.lastPathComponent).lock")
        )
    }

    static func canonicalDirectoryURL(_ directoryURL: URL) -> URL {
        directoryURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public enum UserDictionaryFileWorker {
    /// Blocking flock and compilation must not occupy the MainActor or Swift's cooperative pool.
    public static func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
}
