import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Imports the four model files that azooKey Tuner produces. The source
/// directory is never modified. Each import gets its own directory and one
/// atomically replaced `current` link, so all four files always come from the
/// same import, including while another input context reads the previous one.
public enum PersonalizationModelImport {
    public static let fileNames = ["lm_c_abc.marisa", "lm_r_xbx.marisa", "lm_u_abx.marisa", "lm_u_xbc.marisa"]
    /// Every MARISA trie file starts with this 16-byte header.
    static let marisaHeader = Data("We love Marisa.\0".utf8)
    /// Tuner's models are far smaller; a larger file is not a model to load.
    static let maximumFileSize = 256 * 1024 * 1024
    /// The import root inside the data directory. On Linux `SegmentsManager`
    /// reads the model through `personalization/current`.
    public static let directoryName = "personalization"
    static let currentLinkName = "current"

    public struct Failure: Error, Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Sendable {
            /// The file is missing, not a regular file, or has an invalid size.
            case invalidFile
            case notMarisa
            /// The destination could not be written.
            case placement
        }

        public let reason: Reason
        public let file: String?

        public init(reason: Reason, file: String? = nil) {
            self.reason = reason
            self.file = file
        }
    }

    /// Validates `source`, then copies it into a new directory under `root`
    /// and points `root/current` at it. Returns the new directory.
    @discardableResult
    public static func importModel(from source: URL, into root: URL) throws -> URL {
        for name in fileNames {
            try validate(source.appendingPathComponent(name), name: name)
        }
        let fileManager = FileManager.default
        let stage = root.appendingPathComponent("model-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Exclusive creation: an existing directory with this name fails.
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure(reason: .placement)
        }
        let link = root.appendingPathComponent(".current-\(UUID().uuidString.lowercased())")
        do {
            for name in fileNames {
                let destination = stage.appendingPathComponent(name)
                try fileManager.copyItem(at: source.appendingPathComponent(name).resolvingSymlinksInPath(), to: destination)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            // The source can change between validation and copying; check what was copied.
            for name in fileNames {
                try validate(stage.appendingPathComponent(name), name: name)
            }
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: stage.lastPathComponent)
            guard rename(link.path, root.appendingPathComponent(currentLinkName).path) == 0 else {
                throw Failure(reason: .placement)
            }
            return stage
        } catch {
            try? fileManager.removeItem(at: link)
            try? fileManager.removeItem(at: stage)
            throw error as? Failure ?? Failure(reason: .placement)
        }
    }

    private static func validate(_ url: URL, name: String) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard let attributes, attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > marisaHeader.count, size <= maximumFileSize else {
            throw Failure(reason: .invalidFile, file: name)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure(reason: .invalidFile, file: name)
        }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: marisaHeader.count)) == marisaHeader else {
            throw Failure(reason: .notMarisa, file: name)
        }
    }
}
