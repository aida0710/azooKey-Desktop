import Foundation

extension Config {
    public struct CandidateTextSize: ConfigItem {
        public enum Value: String, Codable, CaseIterable, Hashable, Sendable {
            case standard
            case large
        }

        // A string keeps the preference readable by desktop adapters.
        public static let key = "dev.ensan.inputmethod.azooKeyMac.preference.candidateTextSize"
        public init() {}

        public var value: Value {
            get { Value(rawValue: Config.string(forKey: Self.key) ?? "") ?? .standard }
            nonmutating set { Config.set(newValue.rawValue, forKey: Self.key) }
        }
    }
}
