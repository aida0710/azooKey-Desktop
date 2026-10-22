import Foundation
#if canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

/// A blocking, process-wide exclusive lock held on a lock file until release.
/// POSIX uses flock; Windows uses LockFileEx on the same file.
final class ExclusiveFileLock: @unchecked Sendable {
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
            throw WindowsSystemError.last()
        }
        var overlapped = OVERLAPPED()
        // Lock the first byte; every holder uses the same range, so it excludes the others.
        guard LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &overlapped) else {
            let error = WindowsSystemError.last()
            CloseHandle(handle)
            throw error
        }
        self.handle = handle
        #else
        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
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
        #endif
    }

    deinit {
        // Keep the lock file: removing it would let later callers acquire a different lock.
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
