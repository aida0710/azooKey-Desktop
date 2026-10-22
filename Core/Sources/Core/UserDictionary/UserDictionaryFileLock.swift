import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The descriptor owns a process-wide flock until the whole save, including callbacks, ends.
final class UserDictionaryFileLock: @unchecked Sendable {
    private let descriptor: Int32

    init(directoryURL: URL) throws {
        let canonicalURL = Self.canonicalDirectoryURL(directoryURL)
        let parentURL = canonicalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let path = parentURL.appendingPathComponent(".\(canonicalURL.lastPathComponent).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR {
                continue
            }
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    static func canonicalDirectoryURL(_ directoryURL: URL) -> URL {
        directoryURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    deinit {
        // Keep the lock file: removing its inode would let later callers acquire a different lock.
        _ = flock(self.descriptor, LOCK_UN)
        close(self.descriptor)
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
