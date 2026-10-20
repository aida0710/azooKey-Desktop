import Foundation

public enum UserDictionaryMessages {
    public static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "UserDictionary", bundle: .module, comment: "")
    }
}
