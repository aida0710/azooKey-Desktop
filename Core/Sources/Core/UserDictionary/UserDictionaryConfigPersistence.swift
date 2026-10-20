import Foundation

public enum UserDictionaryConfigPersistence {
    public enum Failure: Error, Sendable {
        case synchronizationFailed
        case readbackMismatch
    }

    public static func make(
        items: [Config.UserDictionaryEntry],
        defaults: UserDefaults = Config.userDefaults
    ) -> UserDictionaryPersistence {
        Self.make(items: items, defaults: defaults, synchronize: { $0.synchronize() })
    }

    static func make(
        items: [Config.UserDictionaryEntry],
        defaults: UserDefaults,
        synchronize: @escaping @Sendable (UserDefaults) -> Bool
    ) -> UserDictionaryPersistence {
        let storage = DefaultsStorage(defaults: defaults, synchronize: synchronize)
        return UserDictionaryPersistence {
            let previous = try storage.snapshot()
            let encoded = try JSONEncoder().encode(Config.UserDictionary.Value(items: items))
            return .init(
                write: { try storage.write(encoded) },
                restore: { try storage.restore(previous) }
            )
        }
    }

    /// UserDefaults is thread-safe; the save transaction additionally holds the dictionary path lock.
    private final class DefaultsStorage: @unchecked Sendable {
        private let defaults: UserDefaults
        private let synchronize: @Sendable (UserDefaults) -> Bool
        private let key = Config.UserDictionary.key

        init(defaults: UserDefaults, synchronize: @escaping @Sendable (UserDefaults) -> Bool) {
            self.defaults = defaults
            self.synchronize = synchronize
        }

        func snapshot() throws -> Data? {
            guard self.synchronize(self.defaults) else {
                throw Failure.synchronizationFailed
            }
            guard let value = self.defaults.object(forKey: self.key) else {
                return nil
            }
            // Preserve the actual previous value, including malformed legacy values and key absence.
            return try PropertyListSerialization.data(
                fromPropertyList: ["value": value], format: .binary, options: 0
            )
        }

        func write(_ encoded: Data) throws {
            self.defaults.set(encoded, forKey: self.key)
            guard self.synchronize(self.defaults) else {
                throw Failure.synchronizationFailed
            }
            guard self.defaults.data(forKey: self.key) == encoded else {
                throw Failure.readbackMismatch
            }
        }

        func restore(_ snapshot: Data?) throws {
            let previous: Any?
            if let snapshot {
                let container = try PropertyListSerialization.propertyList(
                    from: snapshot, options: [], format: nil
                ) as? [String: Any]
                previous = container?["value"]
            } else {
                previous = nil
            }
            self.defaults.set(previous, forKey: self.key)
            guard self.synchronize(self.defaults) else {
                throw Failure.synchronizationFailed
            }
            let current = self.defaults.object(forKey: self.key)
            let currentContainer = current.map { ["value": $0] } ?? [:]
            let previousContainer = previous.map { ["value": $0] } ?? [:]
            guard NSDictionary(dictionary: currentContainer).isEqual(to: previousContainer) else {
                throw Failure.readbackMismatch
            }
        }
    }
}
