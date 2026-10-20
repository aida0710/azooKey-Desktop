import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public enum CompiledUserDictionaryStore {
    enum BuildError: Error {
        case missingCompiledFiles
    }

    public static func directoryURL(memoryDirectoryURL: URL) -> URL {
        memoryDirectoryURL.appendingPathComponent("UserDictionary", isDirectory: true)
    }

    public static func exportCurrentDictionaries(memoryDirectoryURL: URL) throws {
        let directoryURL = UserDictionaryFileLock.canonicalDirectoryURL(
            Self.directoryURL(memoryDirectoryURL: memoryDirectoryURL)
        )
        let lock = try UserDictionaryFileLock(directoryURL: directoryURL)
        defer { withExtendedLifetime(lock) {} }
        let items = Config.UserDictionary().value.items + Config.SystemUserDictionary().value.items
        try Self.rebuildLocked(items: items, directoryURL: directoryURL)
    }

    public static func hasExportedDictionary(memoryDirectoryURL: URL) -> Bool {
        Self.hasCompiledDictionary(at: Self.directoryURL(memoryDirectoryURL: memoryDirectoryURL))
    }

    static func entries(from items: [Config.UserDictionaryEntry]) -> [DicdataElement] {
        items.map { item in
            let ruby = item.reading.toKatakana()
            return DicdataElement(word: item.word, ruby: ruby, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
        }
    }

    static func hasCompiledDictionary(at directoryURL: URL) -> Bool {
        ["user.louds", "user.loudschars2", "user0.loudstxt3"].allSatisfy {
            FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0, isDirectory: false).path)
        }
    }

    static func rebuild(entries: [DicdataElement], directoryURL: URL, charIDFileURL: URL? = nil) throws {
        let directoryURL = UserDictionaryFileLock.canonicalDirectoryURL(directoryURL)
        let lock = try UserDictionaryFileLock(directoryURL: directoryURL)
        defer { withExtendedLifetime(lock) {} }
        let items = entries.map { Config.UserDictionaryEntry(word: $0.word, reading: $0.ruby) }
        try Self.rebuildLocked(items: items, directoryURL: directoryURL, charIDFileURL: charIDFileURL)
    }

    private static func rebuildLocked(
        items: [Config.UserDictionaryEntry], directoryURL: URL, charIDFileURL: URL? = nil
    ) throws {
        let operations = UserDictionaryFileOperations()
        let update = try Self.prepare(
            items: items, directoryURL: directoryURL,
            charIDFileURL: charIDFileURL, operations: operations
        )
        do {
            try update.install()
        } catch {
            let originalError = error
            var rollbackFailures: [UserDictionarySaveError.RollbackFailure] = []
            do {
                try update.rollback()
            } catch {
                rollbackFailures.append(.init(phase: .dictionary, underlying: error))
            }
            throw UserDictionarySaveError(
                phase: .installation, underlying: originalError,
                rollbackFailures: rollbackFailures, recoveryDirectoryURL: update.recoveryDirectoryURL
            )
        }
        _ = update.finish()
    }

    static func prepare(
        items: [Config.UserDictionaryEntry], directoryURL: URL,
        charIDFileURL: URL?, operations: UserDictionaryFileOperations
    ) throws -> CompiledUserDictionaryUpdate {
        let characterTable = items.isEmpty ? nil : try UserDictionaryValidation.characterTable(at: charIDFileURL)
        if let characterTable {
            let issues = UserDictionaryValidation.validate(items: items, supportedCharacters: characterTable.characters)
            guard issues.isEmpty else {
                throw UserDictionaryValidation.InvalidEntries(issues: issues)
            }
        }
        let update = try CompiledUserDictionaryUpdate(directoryURL: directoryURL, operations: operations)
        do {
            if let characterTable {
                try operations.compile(Self.entries(from: items), update.stagingURL, characterTable.url)
                guard Self.hasCompiledDictionary(at: update.stagingURL) else {
                    throw BuildError.missingCompiledFiles
                }
            }
            return update
        } catch {
            update.discardStaging()
            throw error
        }
    }

    static func defaultCharIDFileURL() -> URL? {
        _ = DicdataStore.withDefaultDictionary(preloadDictionary: false)
        let fileManager = FileManager.default
        #if os(Linux)
        // SwiftPM emits .resources directories on Linux, not macOS .bundles.
        // Avoid Bundle.allFrameworks, which has no equivalent for ELF modules.
        let root = Bundle.main.bundleURL
        let children = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.lazy
            .filter { $0.pathExtension == "resources" || $0.pathExtension == "bundle" }
            .map { $0.appendingPathComponent("Dictionary/louds/charID.chid") }
            .first { fileManager.fileExists(atPath: $0.path) }
        #else
        var resourceURLs = (Bundle.allBundles + Bundle.allFrameworks).compactMap(\.resourceURL)

        if let mainResourceURL = Bundle.main.resourceURL,
           let enumerator = fileManager.enumerator(
            at: mainResourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator where url.pathExtension == "bundle" {
                if let bundle = Bundle(url: url), let resourceURL = bundle.resourceURL {
                    resourceURLs.append(resourceURL)
                } else {
                    resourceURLs.append(url.appendingPathComponent("Contents/Resources", isDirectory: true))
                }
            }
        }

        return resourceURLs.lazy
            .map {
                $0.appendingPathComponent("Dictionary/louds/charID.chid", isDirectory: false)
            }
            .first {
                fileManager.fileExists(atPath: $0.path)
            }
        #endif
    }
}
