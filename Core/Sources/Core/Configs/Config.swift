import Foundation

/// namespace for `Config`
public enum Config {
    @TaskLocal private static var overrides: [String: OverrideValue] = [:]
    nonisolated(unsafe) public static let userDefaults: UserDefaults = {
        #if os(macOS)
        AppGroup.preferences()
        #else
        .standard
        #endif
    }()

    public static func object(forKey key: String) -> Any? {
        if let value = Self.overrides[key] {
            return value.object
        }
        if let value = Self.userDefaults.object(forKey: key) {
            return value
        }
        return UserDefaults.standard.object(forKey: key)
    }

    public static func data(forKey key: String) -> Data? {
        if let value = Self.overrides[key] {
            return value.object as? Data
        }
        if let value = Self.userDefaults.data(forKey: key) {
            return value
        }
        return UserDefaults.standard.data(forKey: key)
    }

    public static func string(forKey key: String) -> String? {
        if let value = Self.overrides[key] {
            return value.object as? String
        }
        if let value = Self.userDefaults.string(forKey: key) {
            return value
        }
        return UserDefaults.standard.string(forKey: key)
    }

    public static func set(_ value: Any?, forKey key: String) {
        Self.userDefaults.set(value, forKey: key)
    }

    /// A synchronous worker operation reads its acknowledged settings without writing shared preferences.
    @MainActor
    public static func withOverrides<Value>(_ values: [String: OverrideValue], perform: () throws -> Value) rethrows -> Value {
        let scoped = overrides.merging(values) { _, current in current }
        return try $overrides.withValue(scoped, operation: perform)
    }
}

public protocol ConfigItem<Value> {
    static var key: String { get }
    associatedtype Value: Codable
    var value: Value { get nonmutating set }
}
