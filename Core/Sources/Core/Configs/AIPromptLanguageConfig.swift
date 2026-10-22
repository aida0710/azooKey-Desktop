import Foundation

extension Config {
    /// The language of the default instructions the selected-text AI offers
    /// before the user has used them.
    public struct AIPromptLanguage: ConfigItem {
        /// The instructions are messages of Shared/Messages, so its languages are the choices.
        public typealias Value = Localization.Language

        public static let `default`: Value = .english
        // A string keeps the preference readable by desktop adapters.
        public static let key = "dev.ensan.inputmethod.azooKeyMac.preference.aiPromptLanguage"
        public init() {}

        public var value: Value {
            get { Value(rawValue: Config.string(forKey: Self.key) ?? "") ?? Self.default }
            nonmutating set { Config.set(newValue.rawValue, forKey: Self.key) }
        }
    }
}
