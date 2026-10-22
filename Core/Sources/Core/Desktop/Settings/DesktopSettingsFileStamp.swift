import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Identifies one version of the settings file without reading it. Screens
/// pass the stamp they opened back to a save, which refuses a file another
/// writer has replaced since. The token is opaque outside Core.
public struct DesktopSettingsFileStamp: Hashable, Sendable, Codable {
    public let token: String

    public static let absent = DesktopSettingsFileStamp(token: "absent")

    public init(token: String) {
        self.token = token
    }

    public init(from decoder: any Decoder) throws {
        token = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }

    /// Follows a symbolic link to the file it names, as reading the file does.
    public static func read(_ url: URL) -> DesktopSettingsFileStamp {
        #if os(Windows)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return .init(token: "file:\(size):\(modified)")
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .init(token: "unreadable")
        }
        #else
        var status = stat()
        if stat(url.path, &status) == 0 {
            return .init(token: "file:\(status.st_dev):\(status.st_ino):\(modification(of: status)):\(status.st_size):\(status.st_mode)")
        }
        let failure = errno
        guard failure == ENOENT else {
            return .init(token: "unreadable:\(failure)")
        }
        // A link to a missing file is a damaged settings file, not an absent one.
        if lstat(url.path, &status) == 0 {
            return .init(token: "link:\(modification(of: status))")
        }
        return .absent
        #endif
    }

    #if !os(Windows)
    private static func modification(of status: stat) -> String {
        #if canImport(Darwin)
        "\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)"
        #else
        "\(status.st_mtim.tv_sec).\(status.st_mtim.tv_nsec)"
        #endif
    }
    #endif
}
