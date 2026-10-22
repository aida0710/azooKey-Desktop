import Foundation

public enum Localization {
    public static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
}
