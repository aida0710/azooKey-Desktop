import Foundation

/// A value of a settings document. Objects keep their member order, and a
/// string that cannot become Unicode stays distinguishable so validation can
/// name the setting that holds it.
public indirect enum DesktopSettingsJSON: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let key: String
        public let value: DesktopSettingsJSON

        public init(key: String, value: DesktopSettingsJSON) {
            self.key = key
            self.value = value
        }
    }

    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    /// A string holding an unpaired UTF-16 surrogate escape such as `"\ud800"`.
    case unpairedSurrogateString
    case array([DesktopSettingsJSON])
    case object([Member])

    public subscript(key: String) -> DesktopSettingsJSON? {
        guard case .object(let members) = self else {
            return nil
        }
        return members.first { $0.key == key }?.value
    }
}

extension DesktopSettingsJSON: Codable {
    private struct MemberKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: MemberKey.self) {
            self = .object(try container.allKeys.map { key in
                Member(key: key.stringValue, value: try container.decode(DesktopSettingsJSON.self, forKey: key))
            })
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var items: [DesktopSettingsJSON] = []
            while !container.isAtEnd {
                items.append(try container.decode(DesktopSettingsJSON.self))
            }
            self = .array(items)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .integer(number)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .object(let members):
            var container = encoder.container(keyedBy: MemberKey.self)
            for member in members {
                try container.encode(member.value, forKey: MemberKey(stringValue: member.key))
            }
        case .array(let items):
            var container = encoder.unkeyedContainer()
            for item in items {
                try container.encode(item)
            }
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let flag):
            var container = encoder.singleValueContainer()
            try container.encode(flag)
        case .integer(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .string(let text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case .unpairedSurrogateString:
            var container = encoder.singleValueContainer()
            try container.encode("\u{FFFD}")
        }
    }
}
