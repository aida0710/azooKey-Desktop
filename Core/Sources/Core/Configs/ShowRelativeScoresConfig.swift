extension Config {
    public struct ShowRelativeScores: BoolConfigItem {
        public init() {}
        // Off unless the user turns it on: the scores come from the converter's
        // evaluations, which Zenzai's reordering does not follow, so the chosen
        // candidate can show a lower score than the ones below it.
        static let `default` = false
        public static let key = "dev.ensan.inputmethod.azooKeyMac.preference.showRelativeScores"
    }
}
