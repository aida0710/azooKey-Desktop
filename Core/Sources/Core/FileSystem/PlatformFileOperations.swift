import Foundation
#if canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

#if os(Windows)
/// A Win32 error code (GetLastError) from a call Foundation does not wrap.
/// POSIX platforms report the same failures as POSIXError.
public struct WindowsSystemError: Error, Equatable {
    public let code: UInt32

    static func last() -> WindowsSystemError {
        WindowsSystemError(code: GetLastError())
    }
}
#endif

/// File operations whose atomicity or link handling Foundation does not guarantee
/// the same way on every platform.
public enum PlatformFileOperations {
    /// File attributes that keep other users out: a POSIX mode such as 0o600.
    /// Windows has no POSIX modes; the user's profile folders' ACLs do this there.
    public static func ownerOnlyAttributes(_ mode: Int) -> [FileAttributeKey: Any]? {
        #if os(Windows)
        return nil
        #else
        return [.posixPermissions: mode]
        #endif
    }

    /// Atomically replaces `destination` with `source` on the same volume.
    public static func replaceFile(_ source: URL, to destination: URL) throws {
        #if os(Windows)
        let moved = source.path.withCString(encodedAs: UTF16.self) { from in
            destination.path.withCString(encodedAs: UTF16.self) { to in
                MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH))
            }
        }
        guard moved else {
            throw WindowsSystemError.last()
        }
        #else
        guard rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        #endif
    }

    /// Whether `url` itself (not a link target) is a regular file. Links and
    /// reparse points are not regular files.
    public static func isRegularFileWithoutFollowingLinks(_ url: URL) throws -> Bool {
        #if os(Windows)
        var attributes = WIN32_FILE_ATTRIBUTE_DATA()
        let found = url.path.withCString(encodedAs: UTF16.self) { path in
            GetFileAttributesExW(path, GetFileExInfoStandard, &attributes)
        }
        guard found else {
            throw WindowsSystemError.last()
        }
        let excluded = DWORD(FILE_ATTRIBUTE_DIRECTORY) | DWORD(FILE_ATTRIBUTE_REPARSE_POINT) | DWORD(FILE_ATTRIBUTE_DEVICE)
        return attributes.dwFileAttributes & excluded == 0
        #else
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        #endif
    }
}
