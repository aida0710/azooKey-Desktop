extension Config {
    public struct ShowRelativeScores: BoolConfigItem {
        public init() {}
        // Keep the current visible scores until the user opts out.
        static let `default` = true
        public static let key = "dev.ensan.inputmethod.azooKeyMac.preference.showRelativeScores"
    }
}
