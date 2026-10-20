import KanaKanjiConverterModule

public struct InputStyleSnapshot: Codable, Sendable, Equatable {
    public let inputStyle: InputStyle

    public init(_ inputStyle: InputStyle) throws {
        if case .mapped(id: .tableName(let name)) = inputStyle {
            try CompositionSnapshotValidation.tableName(name)
        }
        self.inputStyle = inputStyle
    }

    var customTableName: String? {
        if case .mapped(id: .tableName(let name)) = self.inputStyle { name } else { nil }
    }

    private enum CodingKeys: String, CodingKey { case kind, table, name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "direct":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind"])
            try self.init(.direct)
        case "roman2kana":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind"])
            try self.init(.roman2kana)
        case "mapped":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind", "table"])
            let tableDecoder = try container.superDecoder(forKey: .table)
            try self.init(.mapped(id: Self.decodeTable(from: tableDecoder)))
        default:
            throw CompositionSnapshotError.invalidValue("inputStyleKind")
        }
    }

    private static func decodeTable(from decoder: any Decoder) throws -> InputTableID {
        let table = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try table.decode(String.self, forKey: .kind)
        let id: InputTableID
        switch kind {
        case "defaultRomanToKana": id = .defaultRomanToKana
        case "defaultAZIK": id = .defaultAZIK
        case "defaultKanaJIS": id = .defaultKanaJIS
        case "defaultKanaUS": id = .defaultKanaUS
        case "empty": id = .empty
        case "tableName": id = .tableName(try table.decode(String.self, forKey: .name))
        default: throw CompositionSnapshotError.invalidValue("tableKind")
        }
        try CompositionSnapshotValidation.keys(decoder, allowed: kind == "tableName" ? ["kind", "name"] : ["kind"])
        return id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.inputStyle {
        case .direct:
            try container.encode("direct", forKey: .kind)
        case .roman2kana:
            try container.encode("roman2kana", forKey: .kind)
        case .mapped(let id):
            try container.encode("mapped", forKey: .kind)
            var table = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .table)
            let kind: String
            switch id {
            case .defaultRomanToKana: kind = "defaultRomanToKana"
            case .defaultAZIK: kind = "defaultAZIK"
            case .defaultKanaJIS: kind = "defaultKanaJIS"
            case .defaultKanaUS: kind = "defaultKanaUS"
            case .empty: kind = "empty"
            case .tableName(let name):
                kind = "tableName"
                try table.encode(name, forKey: .name)
            }
            try table.encode(kind, forKey: .kind)
        }
    }
}
