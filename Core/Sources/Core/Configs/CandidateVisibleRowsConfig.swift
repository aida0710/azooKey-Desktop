import Foundation

extension Config {
    public struct CandidateVisibleRows: ConfigItem {
        public enum Value: Int, Codable, CaseIterable, Hashable, Sendable {
            case five = 5
            case seven = 7
            case nine = 9
        }

        // Only the viewport changes; the converter's nine-candidate page remains intact.
        public static let key = "dev.ensan.inputmethod.azooKeyMac.preference.candidateVisibleRows"
        public init() {}

        public var value: Value {
            get { Value(rawValue: Config.object(forKey: Self.key) as? Int ?? Value.seven.rawValue) ?? .seven }
            nonmutating set { Config.set(newValue.rawValue, forKey: Self.key) }
        }
    }
}
