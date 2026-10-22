import Foundation

/// Lookup of the tables generated from Shared/Messages (see docs/messages.md).
public enum Localization {
    /// The languages of Shared/Messages; the raw value is the `.lproj` name.
    public enum Language: String, Codable, Sendable, CaseIterable {
        case japanese = "ja"
        case english = "en"
    }

    /// The text in the language Foundation selects for this process.
    public static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    /// The text in an explicit language. Bridge clients show their own UI
    /// language, which need not match the bridge process locale.
    /// A missing key returns the key itself, like `NSLocalizedString`.
    public static func text(_ key: String, language: Language, table: String? = nil) -> String {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: nil, table: table)
    }
}
