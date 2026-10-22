@testable import Core
import Foundation

enum DictionaryTestFailure: Error, Equatable {
    case compilation
    case installation
    case persistence
    case activation
    case dictionaryRollback
    case settingsRollback
    case missingCharacterTable
}

final class DictionaryTransactionFixture: Sendable {
    let rootURL: URL
    let directoryURL: URL
    let characterURL: URL
    let settingsURL: URL
    let oldItems = [Config.UserDictionaryEntry(word: "保存前の辞書語", reading: "てすと")]
    let newItems = [Config.UserDictionaryEntry(word: "保存後の辞書語", reading: "てすと")]

    init(useDefaultCharacterTable: Bool = false) throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictionaryTransaction-\(UUID().uuidString)", isDirectory: true)
        self.directoryURL = CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.rootURL)
        if useDefaultCharacterTable {
            guard let characterURL = CompiledUserDictionaryStore.defaultCharIDFileURL() else {
                throw DictionaryTestFailure.missingCharacterTable
            }
            self.characterURL = characterURL
        } else {
            self.characterURL = self.rootURL.appendingPathComponent("charID.chid")
        }
        self.settingsURL = self.rootURL.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        if !useDefaultCharacterTable {
            try "\0テスト".write(to: self.characterURL, atomically: true, encoding: .utf8)
        }
        try JSONEncoder().encode(Config.UserDictionary.Value(items: self.oldItems))
            .write(to: self.settingsURL, options: .atomic)
        try CompiledUserDictionaryStore.rebuild(
            entries: CompiledUserDictionaryStore.entries(from: self.oldItems),
            directoryURL: self.directoryURL, charIDFileURL: self.characterURL
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func files(at directoryURL: URL? = nil) throws -> [String: Data] {
        let directoryURL = directoryURL ?? self.directoryURL
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        )
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    func savedItems() throws -> [Config.UserDictionaryEntry] {
        try JSONDecoder().decode(
            Config.UserDictionary.Value.self, from: Data(contentsOf: self.settingsURL)
        ).items
    }

    func persistence(
        items: [Config.UserDictionaryEntry]? = nil,
        failWrite: Bool = false,
        failRestore: Bool = false
    ) -> UserDictionaryPersistence {
        let items = items ?? self.newItems
        return UserDictionaryPersistence {
            let previous = try Data(contentsOf: self.settingsURL)
            let encoded = try JSONEncoder().encode(Config.UserDictionary.Value(items: items))
            return .init(
                write: {
                    try encoded.write(to: self.settingsURL, options: .atomic)
                    if failWrite {
                        throw DictionaryTestFailure.persistence
                    }
                },
                restore: {
                    if failRestore {
                        throw DictionaryTestFailure.settingsRollback
                    }
                    try previous.write(to: self.settingsURL, options: .atomic)
                }
            )
        }
    }

    @discardableResult
    func save(
        operations: UserDictionaryFileOperations = UserDictionaryFileOperations(),
        persistence: UserDictionaryPersistence? = nil,
        activate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> UserDictionarySaveTransaction.Receipt {
        try await UserDictionarySaveTransaction.save(
            request: .init(
                items: self.newItems, systemItems: [], directoryURL: self.directoryURL,
                charIDFileURL: self.characterURL
            ),
            persistence: persistence ?? self.persistence(), activate: activate,
            operations: operations
        )
    }
}
