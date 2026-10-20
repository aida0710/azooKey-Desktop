import Crypto
import Foundation
import KanaKanjiConverterModule

/// Formal reading state for the opt-in worker transport. Context and request generations
/// belong to its envelope; a snapshot alone never authorizes applying a candidate.
public struct CompositionSnapshot: Codable, Sendable {
    public struct InputElement: Codable, Sendable {
        public let piece: InputPieceSnapshot
        public let inputStyle: InputStyleSnapshot

        init(_ element: ComposingText.InputElement) throws {
            self.piece = try .init(element.piece)
            self.inputStyle = try .init(element.inputStyle)
        }

        private enum CodingKeys: String, CodingKey { case piece, inputStyle }

        public init(from decoder: any Decoder) throws {
            try CompositionSnapshotValidation.keys(decoder, allowed: ["piece", "inputStyle"])
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.piece = try container.decode(InputPieceSnapshot.self, forKey: .piece)
            self.inputStyle = try container.decode(InputStyleSnapshot.self, forKey: .inputStyle)
        }
    }

    public let schemaVersion: Int
    public let input: [InputElement]
    public let convertTarget: String
    public let convertTargetCursorPosition: Int
    public let lastInputStyle: InputStyleSnapshot
    public let conversionRangeEnd: Int?
    public let customInputTableRevisions: [String: String]

    private static let currentSchemaVersion = 1

    private init(composition: CompositionState, registeredCustomTables: [String: String]) throws {
        guard composition.composingText.input.count <= CompositionSnapshotLimits.inputElementCount else {
            throw CompositionSnapshotError.limitExceeded("input")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.input = try composition.composingText.input.map(InputElement.init)
        self.convertTarget = composition.convertTarget
        self.convertTargetCursorPosition = composition.composingText.convertTargetCursorPosition
        self.lastInputStyle = try .init(composition.lastInputStyle)
        self.conversionRangeEnd = composition.conversionRangeEnd
        let names = Set(self.input.compactMap { $0.inputStyle.customTableName } + [self.lastInputStyle.customTableName].compactMap { $0 })
        var revisions: [String: String] = [:]
        for name in names {
            guard let revision = registeredCustomTables[name] else {
                throw CompositionSnapshotError.customTableRevisionMismatch(name)
            }
            revisions[name] = revision
        }
        self.customInputTableRevisions = revisions
        try self.validateStructure()
    }

    /// The caller supplies revisions only for tables it has actually registered.
    /// Capturing never consumes or clears the source, including on validation failure.
    public static func capture(
        _ composition: CompositionState,
        registeredCustomTables: [String: String] = [:]
    ) throws -> Self {
        try Self(composition: composition, registeredCustomTables: registeredCustomTables)
    }

    /// Registration and restoration must be serialized by the caller, because the
    /// upstream table registry is process-global. No table is loaded from wire input.
    public func restore(registeredCustomTables: [String: String] = [:]) throws -> CompositionState {
        for (name, revision) in self.customInputTableRevisions {
            guard registeredCustomTables[name] == revision else {
                throw CompositionSnapshotError.customTableRevisionMismatch(name)
            }
        }
        let elements = self.input.map {
            ComposingText.InputElement(piece: $0.piece.piece, inputStyle: $0.inputStyle.inputStyle)
        }
        var replay = ComposingText()
        replay.insertAtCursorPosition(elements)
        // String equality is canonically equivalent; transport must retain the actual scalars.
        guard replay.convertTarget.utf8.elementsEqual(self.convertTarget.utf8) else {
            throw CompositionSnapshotError.inconsistentReading
        }
        let composingText = ComposingText(
            convertTargetCursorPosition: self.convertTargetCursorPosition,
            input: elements, convertTarget: self.convertTarget
        )
        return CompositionState(composingText: composingText,
                                lastInputStyle: self.lastInputStyle.inputStyle,
                                conversionRangeEnd: self.conversionRangeEnd)
    }

    public static func customInputTableRevision(exportedTable: String) -> String {
        SHA256.hash(data: Data(exportedTable.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(self)
        guard encoded.count <= CompositionSnapshotLimits.jsonByteCount else {
            throw CompositionSnapshotError.limitExceeded("json")
        }
        return encoded
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= CompositionSnapshotLimits.jsonByteCount else {
            throw CompositionSnapshotError.limitExceeded("json")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, input, convertTarget, convertTargetCursorPosition
        case lastInputStyle, conversionRangeEnd, customInputTableRevisions
    }

    public init(from decoder: any Decoder) throws {
        try CompositionSnapshotValidation.keys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard self.schemaVersion == Self.currentSchemaVersion else {
            throw CompositionSnapshotError.unsupportedVersion(self.schemaVersion)
        }
        var input = try container.nestedUnkeyedContainer(forKey: .input)
        var elements: [InputElement] = []
        while !input.isAtEnd {
            guard elements.count < CompositionSnapshotLimits.inputElementCount else {
                throw CompositionSnapshotError.limitExceeded("input")
            }
            elements.append(try input.decode(InputElement.self))
        }
        self.input = elements
        self.convertTarget = try container.decode(String.self, forKey: .convertTarget)
        self.convertTargetCursorPosition = try container.decode(Int.self, forKey: .convertTargetCursorPosition)
        self.lastInputStyle = try container.decode(InputStyleSnapshot.self, forKey: .lastInputStyle)
        self.conversionRangeEnd = try container.decodeIfPresent(Int.self, forKey: .conversionRangeEnd)
        self.customInputTableRevisions = try container.decode([String: String].self, forKey: .customInputTableRevisions)
        try self.validateStructure()
    }

    private func validateStructure() throws {
        guard self.convertTarget.utf8.count <= CompositionSnapshotLimits.jsonByteCount,
              self.convertTarget.count <= CompositionSnapshotLimits.readingCharacterCount else {
            throw CompositionSnapshotError.limitExceeded("convertTarget")
        }
        guard (0...self.convertTarget.count).contains(self.convertTargetCursorPosition) else {
            throw CompositionSnapshotError.invalidValue("convertTargetCursorPosition")
        }
        if let end = self.conversionRangeEnd, end < 1 || end > self.convertTarget.count {
            throw CompositionSnapshotError.invalidValue("conversionRangeEnd")
        }
        let referenced = Set(self.input.compactMap { $0.inputStyle.customTableName } + [self.lastInputStyle.customTableName].compactMap { $0 })
        guard self.customInputTableRevisions.count <= CompositionSnapshotLimits.customTableCount else {
            throw CompositionSnapshotError.limitExceeded("customInputTableRevisions")
        }
        guard Set(self.customInputTableRevisions.keys) == referenced else {
            throw CompositionSnapshotError.invalidValue("customInputTableRevisions")
        }
        for (name, revision) in self.customInputTableRevisions {
            try CompositionSnapshotValidation.tableName(name)
            try CompositionSnapshotValidation.revision(revision)
        }
    }
}
