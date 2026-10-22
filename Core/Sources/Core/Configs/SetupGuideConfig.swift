extension Config {
    public struct SetupGuideSeen: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key = "dev.ensan.inputmethod.azooKeyMac.preference.setupGuideSeen"
    }
}
