import Foundation

extension Config {
    /// Values use the same representations as the existing preference getters.
    public enum OverrideValue: Sendable {
        case boolean(Bool)
        case integer(Int)
        case string(String)
        case encoded(Data)

        var object: Any {
            switch self {
            case .boolean(let value): value
            case .integer(let value): value
            case .string(let value): value
            case .encoded(let value): value
            }
        }
    }
}
