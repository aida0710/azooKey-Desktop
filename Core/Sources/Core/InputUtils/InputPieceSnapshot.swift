import KanaKanjiConverterModule

/// An explicit wire representation; no Codable conformance is added to upstream types.
public struct InputPieceSnapshot: Codable, Sendable, Equatable {
    public let piece: InputPiece

    public init(_ piece: InputPiece) throws {
        switch piece {
        case .character(let character):
            _ = try CompositionSnapshotValidation.character(String(character), field: "character")
        case .compositionSeparator:
            break
        case .key(let intention, let input, _):
            _ = try CompositionSnapshotValidation.character(String(input), field: "input")
            if let intention {
                _ = try CompositionSnapshotValidation.character(String(intention), field: "intention")
            }
        }
        self.piece = piece
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value, intention, input, modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "character":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind", "value"])
            let value = try container.decode(String.self, forKey: .value)
            try self.init(.character(CompositionSnapshotValidation.character(value, field: "character")))
        case "compositionSeparator":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind"])
            try self.init(.compositionSeparator)
        case "key":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind", "intention", "input", "modifiers"])
            let input = try CompositionSnapshotValidation.character(container.decode(String.self, forKey: .input), field: "input")
            let intention = try container.decodeIfPresent(String.self, forKey: .intention)
                .map { try CompositionSnapshotValidation.character($0, field: "intention") }
            let modifiers = try container.decode([String].self, forKey: .modifiers)
            guard modifiers.isEmpty || modifiers == ["shift"] else {
                throw CompositionSnapshotError.invalidValue("modifiers")
            }
            try self.init(.key(intention: intention, input: input, modifiers: modifiers.isEmpty ? [] : [.shift]))
        default:
            throw CompositionSnapshotError.invalidValue("pieceKind")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.piece {
        case .character(let value):
            try container.encode("character", forKey: .kind)
            try container.encode(String(value), forKey: .value)
        case .compositionSeparator:
            try container.encode("compositionSeparator", forKey: .kind)
        case .key(let intention, let input, let modifiers):
            try container.encode("key", forKey: .kind)
            try container.encode(intention.map(String.init), forKey: .intention)
            try container.encode(String(input), forKey: .input)
            try container.encode(modifiers.contains(.shift) ? ["shift"] : [], forKey: .modifiers)
        }
    }
}
