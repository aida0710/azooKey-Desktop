import Crypto
import Foundation

/// One committed source for both conversion and reverse lookup; its text never enters protocol metadata.
public struct UserDictionarySource: Sendable {
    // Match the bounded desktop settings payload, without imposing an arbitrary entry-count limit.
    public static let maximumBytes = 2 * 1024 * 1024

    public enum Failure: String, Error, Sendable {
        case unavailable = "dictionary_source_unavailable"
        case invalid = "invalid_dictionary_source"
        case tooLarge = "dictionary_source_too_large"
    }

    public let revision: String
    public let items: [Config.UserDictionaryEntry]
    private let overrides: [String: Config.OverrideValue]

    init(user: Config.UserDictionary.Value, system: Config.SystemUserDictionary.Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let userContent = try encoder.encode(user)
        // Import timestamps do not change the dictionary's entries or annotations.
        let systemContent = try encoder.encode(Config.UserDictionary.Value(items: system.items))
        let identity = try encoder.encode(["user": user, "system": .init(items: system.items)])
        guard identity.count <= Self.maximumBytes else { throw Failure.tooLarge }
        revision = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        items = user.items + system.items
        overrides = [Config.UserDictionary.key: .encoded(userContent),
                     Config.SystemUserDictionary.key: .encoded(systemContent)]
    }

    /// Candidate annotations must use the same captured entries as its compiled dictionary.
    @MainActor
    public func perform<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try Config.withOverrides(overrides, perform: operation)
    }
}

/// UserDefaults is thread-safe; the existing path lock excludes an in-progress save or rollback.
public final class UserDictionarySourceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let fallbackDefaults: UserDefaults?

    public init(defaults: UserDefaults = Config.userDefaults, fallbackDefaults: UserDefaults? = .standard) {
        self.defaults = defaults
        self.fallbackDefaults = fallbackDefaults
    }

    public func capture(memoryDirectoryURL: URL) async throws -> UserDictionarySource {
        try await UserDictionaryFileWorker.perform {
            let lock = try UserDictionaryFileLock(directoryURL:
                CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryDirectoryURL))
            defer { withExtendedLifetime(lock) {} }
            guard self.defaults.synchronize(), self.fallbackDefaults?.synchronize() != false else {
                throw UserDictionarySource.Failure.unavailable
            }
            return try UserDictionarySource(
                user: self.read(Config.UserDictionary.key, default: Config.UserDictionary.default),
                system: self.read(Config.SystemUserDictionary.key, default: Config.SystemUserDictionary.default))
        }
    }

    private func read<Value: Decodable>(_ key: String, default defaultValue: Value) throws -> Value {
        guard let stored = defaults.object(forKey: key) ?? fallbackDefaults?.object(forKey: key) else {
            return defaultValue
        }
        guard let content = stored as? Data else { throw UserDictionarySource.Failure.invalid }
        guard content.count <= UserDictionarySource.maximumBytes else { throw UserDictionarySource.Failure.tooLarge }
        do {
            return try JSONDecoder().decode(Value.self, from: content)
        } catch {
            throw UserDictionarySource.Failure.invalid
        }
    }
}
