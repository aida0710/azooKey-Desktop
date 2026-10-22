import Foundation

/// Why a settings document or a settings file operation was refused.
/// Screens look up `messageKey` in their message catalog and fill in `arguments`.
public struct DesktopSettingsProblem: Error, Equatable, Sendable, Encodable {
    public enum Code: String, Codable, Sendable {
        case invalidValue
        case unknownKey
        case invalidJSON
        case invalidStructure
        case readFailed
        case engineRejected
        case changed
        case recoveryRequired
        case busy
        case writeFailed
        case backendRecoveryFailed

        public var messageKey: String {
            switch self {
            case .invalidValue: "settings.invalid_value"
            case .unknownKey: "settings.unknown_key"
            case .invalidJSON: "settings.invalid_json"
            case .invalidStructure: "settings.invalid_structure"
            case .readFailed: "settings.read_failed"
            case .engineRejected: "settings.engine_rejected"
            case .changed: "settings.changed"
            case .recoveryRequired: "settings.recovery_required"
            case .busy: "settings.busy"
            case .writeFailed: "settings.write_failed"
            case .backendRecoveryFailed: "settings.backend_recovery_failed"
            }
        }
    }

    /// Field paths in messages stay short even when a damaged file has huge keys.
    static let maximumFieldLength = 100

    public let code: Code
    public let arguments: [String: String]

    public init(_ code: Code, arguments: [String: String] = [:]) {
        self.code = code
        self.arguments = arguments
    }

    public var messageKey: String {
        code.messageKey
    }

    static func invalidValue(_ field: String) -> DesktopSettingsProblem {
        .init(.invalidValue, arguments: ["field": String(field.prefix(maximumFieldLength))])
    }

    static func unknownKey(_ field: String) -> DesktopSettingsProblem {
        .init(.unknownKey, arguments: ["field": String(field.prefix(maximumFieldLength))])
    }

    init(_ failure: DesktopSettingsJSONText.Failure) {
        switch failure {
        case .notUTF8:
            self.init(.readFailed)
        case .syntax(let line, let column):
            self.init(.invalidJSON, arguments: ["line": String(line), "column": String(column)])
        case .duplicateKey(let key):
            self = .invalidValue(key)
        case .tooDeep:
            self.init(.invalidStructure)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case arguments
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(messageKey, forKey: .message)
        try container.encode(arguments, forKey: .arguments)
    }
}
