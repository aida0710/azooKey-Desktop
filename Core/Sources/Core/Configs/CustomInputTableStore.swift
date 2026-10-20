import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import KanaKanjiConverterModule

public enum CustomInputTableStore {
    /// The identifier used when registering the custom input table.
    public static let tableName: String = "azooKeyMac.customRomajiTable"
    private static let appSupportSubdir = "azooKeyMac"
    private static let directoryName = "CustomInputTable"
    private static let fileName = "custom_input_table.tsv"

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appSupportSubdir, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static var fileURL: URL {
        #if canImport(UniformTypeIdentifiers) && !os(Linux)
        return directoryURL.appendingPathComponent(fileName, conformingTo: .text)
        #else
        return directoryURL.appendingPathComponent(fileName)
        #endif
    }

    @discardableResult
    public static func save(exported: String) throws -> URL {
        try ensureDirectoryExists()
        let data = Data(exported.utf8)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    public static func load() -> String? {
        guard exists() else {
            return nil
        }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Read for a bounded worker reply; an unreadable saved table must not become an empty default.
    public static func load(maximumBytes: Int) throws -> String? {
        try load(from: fileURL, maximumBytes: maximumBytes)
    }

    static func load(from url: URL, maximumBytes: Int) throws -> String? {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw ReadFailure.tooLarge }
        var currentURL = url
        // A repaired or replaced table can reuse a URL whose Darwin metadata was cached.
        currentURL.removeAllCachedResourceValues()
        let file: FileHandle
        do {
            let attributes = try currentURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true else { throw ReadFailure.notRegularFile }
            guard let size = attributes.fileSize, size <= maximumBytes else { throw ReadFailure.tooLarge }
            file = try FileHandle(forReadingFrom: currentURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        defer { try? file.close() }
        var contents = Data()
        // Keep the read bounded even if the file grows after the size check.
        while let bytes = try file.read(upToCount: maximumBytes - contents.count + 1), !bytes.isEmpty {
            contents.append(bytes)
            guard contents.count <= maximumBytes else { throw ReadFailure.tooLarge }
        }
        guard let table = String(data: contents, encoding: .utf8) else { throw ReadFailure.invalidUTF8 }
        return table
    }

    enum ReadFailure: Error, Equatable {
        case tooLarge, notRegularFile, invalidUTF8
    }

    public static func loadTable() -> InputTable? {
        guard exists() else {
            return nil
        }
        return try? InputStyleManager.loadTable(from: fileURL)
    }

    /// Load and register the custom input table if it exists.
    /// Safe to call multiple times; later calls override previous registration.
    @discardableResult
    public static func registerIfExists() -> Bool {
        guard exists(), let table = try? InputStyleManager.loadTable(from: fileURL) else {
            return false
        }
        InputStyleManager.registerInputStyle(table: table, for: tableName)
        return true
    }

    public static func exists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public static func clear() throws {
        if exists() { try FileManager.default.removeItem(at: fileURL) }
    }

    private static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
