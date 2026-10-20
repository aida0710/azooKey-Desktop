import KanaKanjiConverterModule

/// Consumption of a real worker-owned candidate; this does not construct a Candidate.
public struct ComposingCountSnapshot: Codable, Sendable, Equatable {
    public let composingCount: ComposingCount

    public init(_ composingCount: ComposingCount) throws {
        var nodes = 0
        try Self.validateStructure(composingCount, depth: 1, nodes: &nodes)
        self.composingCount = composingCount
    }

    /// Each leaf is bounded against the remaining formal input, in lhs/rhs order.
    public func validated(for composition: CompositionState) throws -> ComposingCount {
        var remaining = composition
        try Self.consume(self.composingCount, from: &remaining)
        return self.composingCount
    }

    private static func consume(_ count: ComposingCount, from remaining: inout CompositionState) throws {
        switch count {
        case .inputCount(let value):
            guard value <= remaining.composingText.input.count else {
                throw CompositionSnapshotError.invalidValue("inputCount")
            }
            remaining.prefixComplete(composingCount: count)
        case .surfaceCount(let value):
            guard value <= remaining.convertTarget.count else {
                throw CompositionSnapshotError.invalidValue("surfaceCount")
            }
            remaining.prefixComplete(composingCount: count)
        case .composite(let lhs, let rhs):
            try Self.consume(lhs, from: &remaining)
            try Self.consume(rhs, from: &remaining)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, count, lhs, rhs }

    public init(from decoder: any Decoder) throws {
        var nodes = 0
        self.composingCount = try Self.decode(from: decoder, depth: 1, nodes: &nodes)
    }

    private static func decode(from decoder: any Decoder, depth: Int, nodes: inout Int) throws -> ComposingCount {
        try Self.visit(depth: depth, nodes: &nodes)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "inputCount":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind", "count"])
            let count = try container.decode(Int.self, forKey: .count)
            try Self.validateCount(count, maximum: CompositionSnapshotLimits.inputElementCount)
            return .inputCount(count)
        case "surfaceCount":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind", "count"])
            let count = try container.decode(Int.self, forKey: .count)
            try Self.validateCount(count, maximum: CompositionSnapshotLimits.readingCharacterCount)
            return .surfaceCount(count)
        case "composite":
            try CompositionSnapshotValidation.keys(decoder, allowed: ["kind", "lhs", "rhs"])
            let lhs = try Self.decode(from: container.superDecoder(forKey: .lhs), depth: depth + 1, nodes: &nodes)
            let rhs = try Self.decode(from: container.superDecoder(forKey: .rhs), depth: depth + 1, nodes: &nodes)
            return .composite(lhs: lhs, rhs: rhs)
        default:
            throw CompositionSnapshotError.invalidValue("composingCountKind")
        }
    }

    private static func validateStructure(_ count: ComposingCount, depth: Int, nodes: inout Int) throws {
        try Self.visit(depth: depth, nodes: &nodes)
        switch count {
        case .inputCount(let value):
            try Self.validateCount(value, maximum: CompositionSnapshotLimits.inputElementCount)
        case .surfaceCount(let value):
            try Self.validateCount(value, maximum: CompositionSnapshotLimits.readingCharacterCount)
        case .composite(let lhs, let rhs):
            try Self.validateStructure(lhs, depth: depth + 1, nodes: &nodes)
            try Self.validateStructure(rhs, depth: depth + 1, nodes: &nodes)
        }
    }

    private static func visit(depth: Int, nodes: inout Int) throws {
        guard depth <= CompositionSnapshotLimits.composingCountDepth else {
            throw CompositionSnapshotError.limitExceeded("composingCountDepth")
        }
        nodes += 1
        guard nodes <= CompositionSnapshotLimits.composingCountNodes else {
            throw CompositionSnapshotError.limitExceeded("composingCountNodes")
        }
    }

    private static func validateCount(_ count: Int, maximum: Int) throws {
        guard count >= 0 else { throw CompositionSnapshotError.invalidValue("negativeCount") }
        guard count <= maximum else { throw CompositionSnapshotError.limitExceeded("composingCount") }
    }

    public func encode(to encoder: any Encoder) throws {
        try Self.encode(self.composingCount, to: encoder)
    }

    private static func encode(_ count: ComposingCount, to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch count {
        case .inputCount(let value):
            try container.encode("inputCount", forKey: .kind)
            try container.encode(value, forKey: .count)
        case .surfaceCount(let value):
            try container.encode("surfaceCount", forKey: .kind)
            try container.encode(value, forKey: .count)
        case .composite(let lhs, let rhs):
            try container.encode("composite", forKey: .kind)
            try Self.encode(lhs, to: container.superEncoder(forKey: .lhs))
            try Self.encode(rhs, to: container.superEncoder(forKey: .rhs))
        }
    }
}
