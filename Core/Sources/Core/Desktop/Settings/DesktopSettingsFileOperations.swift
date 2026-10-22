import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

// TODO: Fold these into Core/FileSystem (PlatformFileOperations, ExclusiveFileLock)
// when feature/windows-tsf lands; the Windows branches here are not yet built on Windows.

/// The file system calls a settings save makes, replaceable in tests to fail on purpose.
struct DesktopSettingsFileOperations: Sendable {
    /// Writes `content` to a new private file named `.settings-*` in `directory`
    /// and flushes it to disk before returning its URL.
    var writeStagedFile: @Sendable (_ content: Data, _ directory: URL) throws -> URL
    /// Atomically replaces `destination` with `source` on the same volume.
    var replaceFile: @Sendable (_ source: URL, _ destination: URL) throws -> Void

    static let system = DesktopSettingsFileOperations(
        writeStagedFile: SystemSettingsFiles.writeStagedFile(_:in:),
        replaceFile: SystemSettingsFiles.replaceFile(_:to:)
    )
}

enum SystemSettingsFiles {
    static let stagedFilePrefix = ".settings-"

    static func writeStagedFile(_ content: Data, in directory: URL) throws -> URL {
        let staged = directory.appendingPathComponent(stagedFilePrefix + UUID().uuidString)
        #if os(Windows)
        guard FileManager.default.createFile(atPath: staged.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: staged)
            defer {
                try? handle.close()
            }
            try handle.write(contentsOf: content)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        #else
        // Exclusive creation with owner-only permissions keeps the private
        // document unreadable to others for its whole life.
        let descriptor = open(staged.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            defer {
                close(descriptor)
            }
            try content.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(staged.path)
            throw error
        }
        #endif
        return staged
    }

    static func replaceFile(_ source: URL, to destination: URL) throws {
        #if os(Windows)
        let moved = source.path.withCString(encodedAs: UTF16.self) { from in
            destination.path.withCString(encodedAs: UTF16.self) { to in
                MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH))
            }
        }
        guard moved else {
            throw CocoaError(.fileWriteUnknown)
        }
        #else
        guard rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        #endif
    }
}

/// Lets one writer at a time change the settings file. A second writer is
/// refused at once instead of waiting, so a screen can say another one is saving.
final class DesktopSettingsWriterLock {
    #if os(Windows)
    private let handle: HANDLE
    #else
    private let descriptor: Int32
    #endif

    init(lockFileURL: URL) throws {
        #if os(Windows)
        let handle = lockFileURL.path.withCString(encodedAs: UTF16.self) { path in
            CreateFileW(path, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw CocoaError(.fileWriteUnknown)
        }
        var overlapped = OVERLAPPED()
        guard LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &overlapped) else {
            let failure = GetLastError()
            CloseHandle(handle)
            if failure == DWORD(ERROR_LOCK_VIOLATION) {
                throw DesktopSettingsProblem(.busy)
            }
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = handle
        #else
        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if failure == EINTR {
                continue
            }
            close(descriptor)
            if failure == EWOULDBLOCK {
                throw DesktopSettingsProblem(.busy)
            }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        self.descriptor = descriptor
        #endif
    }

    deinit {
        // Keep the lock file: removing it would let a later writer lock a different file.
        #if os(Windows)
        var overlapped = OVERLAPPED()
        _ = UnlockFileEx(handle, 0, 1, 0, &overlapped)
        CloseHandle(handle)
        #else
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        #endif
    }
}
