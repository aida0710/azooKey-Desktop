@testable import Core
import Foundation
import Testing

@MainActor
@Suite struct UserDictionarySourceTests {
    @Test(arguments: ["word", "reading", "hint", "id", "system"])
    func dictionaryIdentityKeepsExactBytesAndEntryOwnership(_ changed: String) throws {
        let original = Config.UserDictionaryEntry(word: "\u{e9}", reading: "\u{304c}", hint: "\u{e9}")
        let source = try UserDictionarySource(user: .init(items: [original]), system: .init(items: []))
        var modified = original
        switch changed {
        case "word": modified.word = "e\u{301}"
        case "reading": modified.reading = "か\u{3099}"
        case "hint": modified.nonNullHint = "e\u{301}"
        case "id": modified.id = UUID()
        default: break
        }
        let updated = try UserDictionarySource(user: .init(items: changed == "system" ? [] : [modified]),
                                               system: .init(items: changed == "system" ? [modified] : []))
        #expect(updated.revision != source.revision)
        #expect(try UserDictionarySource(user: .init(items: [original]), system: .init(items: [])).revision == source.revision)
    }

    @Test(arguments: ["wrong-type", "invalid-json", "too-large"])
    func invalidStoredSourceIsRejectedWithoutReplacingItWithDefaults(_ invalid: String) async throws {
        let suite = "azookey-source-invalid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        switch invalid {
        case "wrong-type": defaults.set("not dictionary data", forKey: Config.UserDictionary.key)
        case "invalid-json": defaults.set(Data("{".utf8), forKey: Config.UserDictionary.key)
        default: defaults.set(Data(repeating: 0, count: UserDictionarySource.maximumBytes + 1), forKey: Config.UserDictionary.key)
        }
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let store = UserDictionarySourceStore(defaults: defaults, fallbackDefaults: nil)
        let expected: UserDictionarySource.Failure = invalid == "too-large" ? .tooLarge : .invalid
        await #expect(throws: expected) { try await store.capture(memoryDirectoryURL: directory) }
        #expect(defaults.dictionaryRepresentation() as NSDictionary == before)
    }

    @Test func privateCompiledCopiesUseCapturedEntriesAndAreRemovedWhenTheirOwnerRetires() async throws {
        let item = Config.UserDictionaryEntry(word: "固定辞書", reading: "こていじしょ")
        let source = try UserDictionarySource(user: .init(items: [item]), system: .init(items: []))
        var snapshot: CompiledUserDictionarySnapshot? = try await .prepare(source)
        let directory = try #require(snapshot).directoryURL
        #expect(CompiledUserDictionaryStore.hasCompiledDictionary(at: directory))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        let preferences = Config.userDefaults.dictionaryRepresentation() as NSDictionary
        let nested = try UserDictionarySource(user: .init(items: []), system: .init(items: []))
        source.perform {
            #expect(Config.UserDictionary().value.items.map(\.id) == [item.id])
            nested.perform { #expect(Config.UserDictionary().value.items.isEmpty) }
            #expect(Config.UserDictionary().value.items.map(\.id) == [item.id])
        }
        #expect(Config.userDefaults.dictionaryRepresentation() as NSDictionary == preferences)
        snapshot = nil
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
    }
}
